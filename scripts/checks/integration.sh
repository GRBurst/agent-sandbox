# shellcheck shell=bash
#
# Integration layer. Real confined sessions, in this checkout, on a real
# kernel. This is the only layer where enforcement is observed at all: every
# layer above it reads a resolved policy and takes nono's word for it.
#
# `set -euo pipefail`, `fail` and `REPO_ROOT` come from scripts/validate.sh.

# A live `nono run` from inside this repository needs four conditions, each one
# recorded in research.md against the failure that revealed it. They are
# established here, once, before the first session.
#
#   1. TMPDIR inside the project, or the `system_write_linux` grant on $TMPDIR
#      overlaps the state root and nono refuses to start.
#   2. XDG_STATE_HOME outside the project, writable, and granted by no group.
#   3. The audit ledger exists before the run. This one is load-bearing for
#      the whole layer: the migration that fails runs *after* the child exits
#      and replaces the child's exit status with 1. A child exiting 0 would
#      report 1, and a pre-flight refusing with 77 would report 1, so every
#      exit status asserted below would be the supervisor's cleanup instead.
#   4. The programs the child execs granted read, or it cannot exec at all and
#      exits 127. The generated profile carries them as the enumerated
#      execution substrate, so nothing needs granting here.
# Sets SESSION_ENV to the assignments `env` needs. An array, because the values
# hold paths and splitting a string on whitespace would corrupt them.
session_env() {
	local state=$1
	mkdir -p "$state/nono/audit" "$REPO_ROOT/.tmp/session"
	touch "$state/nono/audit/ledger.ndjson"
	SESSION_ENV=(
		"TMPDIR=$REPO_ROOT/.tmp/session"
		"XDG_STATE_HOME=$state"
		NONO_NO_UPDATE_CHECK=1
	)
}

# The substrate member that provides a binary, or nothing.
#
# A check that needs to run a program inside a session resolves it this way
# rather than from PATH or from a store path written down: the answer is a path
# the session is granted, so the program a check observes cannot be one the
# session could not have executed.
substrate_member() {
	local substrate=$1 binary=$2 path
	while read -r path; do
		if [ -x "$path/bin/$binary" ]; then
			printf '%s\n' "$path"
			return 0
		fi
	done <"$substrate/store-paths"
	return 1
}

# Everything a check needs before it can run a probe inside a session: the
# agent's resolved description, its execution substrate, and a bash out of that
# substrate. Sets FIXTURE_PROFILE, FIXTURE_SUBSTRATE and FIXTURE_BASH.
#
# Each of the three fails loudly and separately. A caller that let a build
# failure through would run its session against an empty path and report the
# refusal it was looking for.
session_fixture() {
	local agent=$1
	FIXTURE_PROFILE=$(nix build --no-link --print-out-paths "$REPO_ROOT#confinement-$agent") || {
		fail "the confinement for $agent does not build"
		return 1
	}
	FIXTURE_SUBSTRATE=$(nix build --no-link --print-out-paths "$REPO_ROOT#substrate-$agent") || {
		fail "the execution substrate for $agent does not build"
		return 1
	}
	FIXTURE_BASH=$(substrate_member "$FIXTURE_SUBSTRATE" bash) || {
		fail "the substrate for $agent provides no bash to run a probe with"
		return 1
	}
}

# The paths an strace log shows refused, one per line, sorted and unique.
#
# Only openat, and only EACCES or EPERM: those are the two errors Landlock
# returns, and a check that swept up ENOENT would call a path the program
# merely guessed at a denial.
trace_denials() {
	local trace=$1
	awk '/openat\(/ && /EACCES|EPERM/ {
		if (match($0, /"[^"]*"/)) print substr($0, RSTART + 1, RLENGTH - 2)
	}' "$trace" | sort -u
}

# R6 — a host that cannot enforce confinement refuses, naming the primitive.
#
# Two arms, because an exit status of 77 on its own does not say what earned
# it. The control arm runs the real pre-flight on this machine and must exit 0,
# so a pre-flight that refused every host could not pass. The plant arm puts a
# passthrough `nono` earlier on PATH — present, accepting the same arguments,
# enforcing nothing — which is what an unenforceable host looks like from the
# pre-flight's side, and must produce 77 and the primitive.
check_r6() {
	local preflight tmp state profile pinned rc out found=0
	local -a SESSION_ENV
	preflight="$REPO_ROOT/lib/preflight.sh"

	if [ ! -f "$preflight" ]; then
		fail "lib/preflight.sh: no such file"
		return 1
	fi

	tmp=$(mktemp -d "$REPO_ROOT/.tmp/integration.XXXXXX")
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	state="${XDG_RUNTIME_DIR:-$tmp}/agent-sandbox-check-state"
	session_env "$state"
	profile=$(nix build --no-link --print-out-paths "$REPO_ROOT#confinement-claude-code")
	# The pre-flight resolves `nono` from PATH, which is the whole mechanism the
	# plant arm below exploits. Every unplanted arm therefore puts the pinned
	# nono in front of whatever the developing host carries, so the arms differ
	# by their plant and by nothing else.
	pinned=$(pinned_bin nono)

	# The control (D9). Unplanted, on this machine, the pre-flight must pass.
	out=$(cd "$REPO_ROOT" && env "${SESSION_ENV[@]}" PATH="$pinned:$PATH" PREFLIGHT_PROFILE="$profile" \
		bash -c "source '$preflight'; preflight_or_die" 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		found=1
		fail "$(printf 'the pre-flight refused a host that does enforce confinement: exit %s\n%s' "$rc" "$out")"
	fi

	# The plant. A passthrough nono runs the child with nothing applied, so the
	# canary write succeeds and the pre-flight must refuse.
	cat >"$tmp/nono" <<-'STUB'
		#!/usr/bin/env bash
		# Accept `run --profile P --workdir W [--allow-cwd] -- cmd...` and exec cmd.
		while [ $# -gt 0 ]; do
		  case $1 in
		    --) shift; break ;;
		    --profile|--workdir) shift 2 ;;
		    *) shift ;;
		  esac
		done
		exec "$@"
	STUB
	chmod +x "$tmp/nono"

	out=$(cd "$REPO_ROOT" && env "${SESSION_ENV[@]}" PATH="$tmp:$pinned:$PATH" PREFLIGHT_PROFILE="$profile" \
		bash -c "source '$preflight'; preflight_or_die" 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 77 ]; then
		found=1
		fail "$(printf 'an unenforceable host was not refused with 77: exit %s\n%s' "$rc" "$out")"
	fi
	if ! printf '%s' "$out" | grep -q 'Landlock'; then
		found=1
		fail "$(printf 'the refusal does not name the missing primitive:\n%s' "$out")"
	fi

	# The third arm covers the positive control itself. Arms one and two both
	# leave assertion 2 untested, because the canary location happens to be
	# writable on this machine — so deleting that assertion would go unnoticed.
	# A host offering nowhere to write the canary cannot demonstrate
	# enforcement, and must refuse rather than report success (D5).
	mkdir -p "$tmp/unwritable"
	chmod 500 "$tmp/unwritable"
	out=$(cd "$REPO_ROOT" && env "${SESSION_ENV[@]}" PATH="$pinned:$PATH" \
		XDG_RUNTIME_DIR="$tmp/unwritable" HOME="$tmp/unwritable" PREFLIGHT_PROFILE="$profile" \
		bash -c "source '$preflight'; preflight_or_die" 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 77 ]; then
		found=1
		fail "$(printf 'a host with nowhere to write the canary was not refused with 77: exit %s\n%s' "$rc" "$out")"
	fi
	if ! printf '%s' "$out" | grep -q 'cannot verify confinement'; then
		found=1
		fail "$(printf 'the refusal does not say the canary was unwritable:\n%s' "$out")"
	fi

	[ "$found" -eq 0 ]
}

# Journey 1.1 — a stranger enters the environment and starts an agent.
#
# The observable is the session's own audit record, not nono's banner and not a
# resolved manifest. Every run writes
# $XDG_STATE_HOME/nono/audit/<id>/session.json, whose `tracked_paths` holds the
# reach granted above the confinement floor. M4b widened the grant from each
# source in turn — the description's `read`, its `allow`, a `--read` flag, the
# working directory consent — and the set moved every time, so it is the set
# plan.md's property is written about rather than a summary of it. The banner
# collapses the floor to a count and the manifest is only the resolution: M4b
# found a manifest reporting the project readwrite for a session that had no
# reach into the project at all.
#
# The agent is started by name, from inside the environment, because that is
# what Journey 1 promises. `claude` on PATH is the wrapper (D3) and the raw
# binary is reachable only by store path. M9a re-homes this check to the e2e
# layer by replacing this checkout with the published reference.
#
# No positive control (D9): the observable is a set rather than a verdict, and
# an unconfined agent writes no session record at all, so the comparison cannot
# even be attempted.
check_j1_1() {
	local agent=claude-code binary=claude
	local outside home state project session registry substrate rc out found=0
	local -a sessions=()

	# Outside the project, because nono refuses to start when a granted path
	# overlaps its own state root, and clean, because nono derives that root
	# from the environment a stranger would arrive with rather than this one.
	outside=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" agent-sandbox-j1_1.XXXXXX)
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	home="$outside/home"
	state="$outside/state"
	mkdir -p "$home" "$state/nono/audit"
	touch "$state/nono/audit/ledger.ndjson"

	out=$(cd "$REPO_ROOT" && env "HOME=$home" "XDG_STATE_HOME=$state" NONO_NO_UPDATE_CHECK=1 \
		nix develop "$REPO_ROOT" -c "$binary" --version 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the agent did not start: exit %s\n%s' "$rc" "$out")"
		return 1
	fi

	# The wrapper's pre-flight runs confined sessions of its own, so the agent's
	# is selected by what it executed rather than by being the only one. That
	# also asserts the wrapper ran the agent from the store instead of whatever
	# the name resolved to.
	while IFS= read -r session; do
		if jq -e --arg b "/bin/$binary" '.command[0] | endswith($b)' "$session" >/dev/null 2>&1; then
			sessions+=("$session")
		fi
	done < <(find "$state/nono/audit" -mindepth 2 -maxdepth 2 -name session.json)

	if [ "${#sessions[@]}" -ne 1 ]; then
		fail "$(printf 'expected exactly one confined %s session, found %s under %s' \
			"$binary" "${#sessions[@]}" "$state/nono/audit")"
		return 1
	fi

	project=$(cd "$REPO_ROOT" && pwd -P)
	registry=$(nix eval --json "$REPO_ROOT#leakRegistry" \
		--apply "es: builtins.filter (e: builtins.elem \"$agent\" e.agents) es")
	substrate=$(nix build --no-link --print-out-paths "$REPO_ROOT#substrate-$agent") || {
		fail "the execution substrate for $agent does not build"
		return 1
	}

	# The property, from plan.md: granted ∖ floor = {the project} ∪ the substrate
	# ∪ the registry. Every term is derived from the artefact this repository
	# builds rather than restated here, so adding a tool to the session or an
	# entry to the registry moves both sides at once, and only reach nobody
	# declared can fail this.
	#
	# The substrate term is what M4c turned from a prefix into a set. Until then
	# the store was granted whole and this comparison could not tell a session
	# that runs 128 paths from one that can read all 67,000: a single granted
	# ancestor satisfied a diff either way. Enumerated, the same diff now fails
	# on one path too many.
	if ! diff -u \
		<({
			printf '%s\n' "$project"
			cat "$substrate/store-paths"
			jq -r '.[].path' <<<"$registry"
		} | sort -u) \
		<(jq -r '.tracked_paths[]' "${sessions[0]}" | sort -u) \
		>"$outside/reach.diff" 2>&1; then
		found=1
		fail "$(printf 'the session reaches more or less than the project, its substrate and the leak registry:\n%s' \
			"$(sed '1,2d' "$outside/reach.diff")")"
	fi

	[ "$found" -eq 0 ]
}

# M4c criterion 4 — narrowing the substrate to what the session runs denies
# the session nothing.
#
# The observable is a syscall trace, because nono is not an observer here: on a
# session that died for a denied locale archive, `nono run --diagnostics-json`
# reported `"denials": []` and offered only an info-level guess, and no
# discovery mode exists to ask it what a run wanted.
#
# The assertion is an equality between two denial sets, never a count and never
# a list of paths, because a floor denies things in every arm: eleven /sys and
# cgroup paths are refused even with the whole store granted, and a check that
# demanded an empty set would fail on a working session. The two arms differ by
# exactly one grant, so any path that appears in the narrow arm alone is reach
# the narrowing took away.
#
# Both binaries come out of the substrate itself rather than from PATH or a
# restated store path, so what the check runs is by construction what the
# session may run: a substrate missing either one cannot be observed at all.
check_substrate_denials() {
	local agent=claude-code
	local tmp state profile substrate store claude strace arm rc
	local -a SESSION_ENV

	if [ "$(uname -s)" != Linux ]; then
		printf 'a syscall trace of a confined session is Linux-only; the substrate\n'
		printf 'equality is asserted by check_sc1 on every platform\n'
		return "$SKIP_STATUS"
	fi

	profile=$(nix build --no-link --print-out-paths "$REPO_ROOT#confinement-$agent") || {
		fail "the confinement for $agent does not build"
		return 1
	}
	substrate=$(nix build --no-link --print-out-paths "$REPO_ROOT#substrate-$agent") || {
		fail "the execution substrate for $agent does not build"
		return 1
	}
	store=$(nix eval --raw --impure --expr 'builtins.storeDir')

	claude=$(substrate_member "$substrate" claude) || {
		fail "the substrate provides no claude to run"
		return 1
	}
	strace=$(substrate_member "$substrate" strace) || {
		fail "the substrate provides no strace, so the session cannot be observed"
		return 1
	}

	# Inside the project, because the project is the only writable place: the
	# trace is written by the confined child, not by this check.
	tmp=$REPO_ROOT/.tmp/substrate-denials
	rm -rf "$tmp"
	mkdir -p "$tmp"
	state="${XDG_RUNTIME_DIR:-$tmp}/agent-sandbox-substrate-denials"
	rm -rf "$state"
	session_env "$state"

	cp "$profile" "$tmp/narrow.json"
	jq --arg s "$store" '.filesystem.read += [$s]' "$profile" >"$tmp/whole.json"

	for arm in narrow whole; do
		rc=0
		env "${SESSION_ENV[@]}" \
			"$(pinned_bin nono)/nono" run \
			--profile "$tmp/$arm.json" --workdir "$REPO_ROOT" --allow-cwd -- \
			"$strace/bin/strace" -f -e trace=openat -o "$tmp/$arm.trace" \
			"$claude/bin/claude" --version >"$tmp/$arm.out" 2>&1 || rc=$?
		[ "$rc" -eq 0 ] || {
			fail "$(printf 'the %s arm did not start (exit %d):\n%s' "$arm" "$rc" "$(cat "$tmp/$arm.out")")"
			return 1
		}
		trace_denials "$tmp/$arm.trace" >"$tmp/$arm.denials"
	done

	# The control is the whole-store arm, and it is a positive one (D9): it
	# proves the probe reaches a session at all, so an equality of two empty
	# sets cannot pass for a session that never ran.
	[ -s "$tmp/whole.denials" ] || {
		fail "the whole-store arm was refused nothing, so the trace observed nothing"
		return 1
	}

	diff -u --label "whole store" "$tmp/whole.denials" \
		--label "substrate only" "$tmp/narrow.denials" >"$tmp/denials.diff" 2>&1 || {
		fail "$(printf 'narrowing the substrate denied the session something the whole store did not:\n%s' \
			"$(sed '1,2d' "$tmp/denials.diff")")"
		return 1
	}
}

# R1 — a private key outside the project is unreadable from inside a session.
#
# The key lives in a fake $HOME under $XDG_RUNTIME_DIR rather than in the
# project's own scratch directory, and that is forced rather than tidiness: the
# resolved description carries 48 $HOME-relative deny rules, so a $HOME under
# the granted project makes every one of them overlap an allowed parent and
# nono refuses to start (D15). The check would then observe a refusal to start
# and call it a refusal to read.
#
# Both halves of the scenario are asserted, and the probe prints the key
# material it managed to read on purpose: an assertion that no key material
# appears in the output is worth nothing against a probe that never shows it.
# A non-zero exit is not enough on its own either, so the refusal must say
# `Permission denied` — a key that had simply never been there would exit
# non-zero and show no material just as convincingly.
#
# Two controls, because the observable is a failure (D9):
#
#   1. In the same session, a file inside the project is read successfully. A
#      session that died at startup, or a probe that could read nothing at all,
#      cannot pass.
#   2. The same key is read once from outside the boundary before the session
#      runs, so the denial is attributable to confinement rather than to a
#      plant that never landed.
#
# The third arm is a standing positive control on the probe itself: with the
# key's directory added to `filesystem.read`, the same probe must read the key
# out. It names the exact directory and never an ancestor, because a grant
# above a denied path is refused at startup rather than widened. This arm is
# also the finding that makes the check necessary at all — `deny_credentials`
# is `required` and denies this very path, and the grant still wins, so nothing
# stands behind the registry's own strictness.
check_r1() {
	local agent=claude-code
	local outside home key inside probe scratch
	local key_canary inside_canary arm description rc out found=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV

	session_fixture "$agent" || return 1

	outside=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" agent-sandbox-r1.XXXXXX)
	scratch="$REPO_ROOT/.tmp/r1"
	rm -rf "$scratch"
	mkdir -p "$scratch"
	# shellcheck disable=SC2064
	trap "rm -rf '$outside' '$scratch'" RETURN

	home="$outside/home"
	key="$home/.ssh/id_ed25519"
	mkdir -p "$home/.ssh"
	# Per run, so a stale match in a log cannot satisfy the assertion.
	key_canary="PLANTED-KEY-MATERIAL-$RANDOM$RANDOM"
	inside_canary="PROJECT-FILE-CONTENT-$RANDOM$RANDOM"
	printf '%s\n' "$key_canary" >"$key"
	chmod 600 "$key"
	inside="$scratch/inside.txt"
	printf '%s\n' "$inside_canary" >"$inside"

	# Control 2. Unconfined, the key reads.
	if [ "$(cat "$key")" != "$key_canary" ]; then
		fail "the planted key is not readable outside the boundary, so a denial inside it would prove nothing"
		return 1
	fi

	# The probe takes its targets as arguments and lives inside the project, so
	# nothing here depends on quoting surviving a `-c` string, and it reads with
	# the shell's own redirection rather than by calling `cat`. PATH is
	# inherited whole, host entries included, so a name resolved inside the
	# session can land on a binary the session may not read — which is how the
	# pre-flight's bare `true` fails on a host carrying one outside the store.
	# A probe that ran an ungranted binary would report a denial of its own.
	probe="$scratch/probe.sh"
	cat >"$probe" <<-'PROBE'
		key_rc=0
		key=$(<"$1") || key_rc=$?
		printf 'KEY :: %s\n' "$key"
		printf 'INSIDE :: %s\n' "$(<"$2")"
		exit "$key_rc"
	PROBE

	session_env "$outside/state"

	jq --arg d "$home/.ssh" '.filesystem.read += [$d]' "$FIXTURE_PROFILE" >"$scratch/granted.json"

	for arm in shipped granted; do
		description=$FIXTURE_PROFILE
		[ "$arm" = shipped ] || description="$scratch/granted.json"

		out=$(env "${SESSION_ENV[@]}" "HOME=$home" \
			"$(pinned_bin nono)/nono" run \
			--profile "$description" --workdir "$REPO_ROOT" --allow-cwd -- \
			"$FIXTURE_BASH/bin/bash" "$probe" "$key" "$inside" 2>&1) && rc=0 || rc=$?

		# The in-project read is asserted in both arms: it is what says the
		# session started and the probe ran, and the granted arm needs that
		# said as much as the shipped one.
		if ! printf '%s' "$out" | grep -qF "INSIDE :: $inside_canary"; then
			found=1
			fail "$(printf 'the %s arm never read the file inside the project, so it observed no session (exit %s):\n%s' \
				"$arm" "$rc" "$out")"
			continue
		fi

		if [ "$arm" = granted ]; then
			# Control 3. The probe must be able to read the key when the
			# boundary allows it, or the shipped arm's refusal is the probe's
			# and not the sandbox's.
			if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -qF "KEY :: $key_canary"; then
				found=1
				fail "$(printf 'the probe cannot read the key even when the boundary grants it (exit %s):\n%s' \
					"$rc" "$out")"
			fi
			continue
		fi

		if [ "$rc" -eq 0 ]; then
			found=1
			fail "$(printf 'reading a key outside the project exited 0:\n%s' "$out")"
		fi
		if printf '%s' "$out" | grep -qF "$key_canary"; then
			found=1
			fail "$(printf 'key material appears in the output of the confined session:\n%s' "$out")"
		fi
		if ! printf '%s' "$out" | grep -q 'Permission denied'; then
			found=1
			fail "$(printf 'the read did not fail on permission, so the key may simply not have been there:\n%s' "$out")"
		fi
	done

	[ "$found" -eq 0 ]
}

# R2 — a write outside the project is refused, and leaves nothing behind.
#
# The target is a subdirectory of the fake $HOME rather than the fake $HOME
# itself, and that is forced by the arm below it: the granted arm has to name
# the path it grants exactly, because granting the home directory overlaps both
# nono's own state root candidate at `$HOME/.nono` and the 48 $HOME-relative
# deny rules, and nono refuses to start rather than narrowing. Both arms then
# aim at the same path, so the only difference between them is the grant.
#
# Both halves of the scenario are asserted, and the second half is asserted
# from outside the session, after it has exited: a refusal reported inside the
# sandbox is the sandbox's own account of itself, while the file's absence on
# the host is the fact the scenario is about. A non-zero exit is not enough on
# its own either, so the refusal must say `Permission denied` — a write to a
# path that had never existed would fail just as convincingly.
#
# Two controls, because the observable is a failure (D9):
#
#   1. In the same session, a file inside the workdir is written and is there
#      afterwards. A session that died at startup cannot pass, and neither can
#      one confined read-only, which would refuse both writes alike.
#   2. The same target is written once from outside the boundary before the
#      session runs, so the refusal is attributable to confinement rather than
#      to a directory that was never writable.
#
# The third arm is a standing positive control on the probe itself: with the
# target's directory added to `filesystem.allow`, the same probe must write the
# file and it must be there afterwards. Without it, a probe that could write
# nothing at all would pass the shipped arm.
check_r2() {
	local agent=claude-code
	local outside home target inside probe scratch canary arm description rc out found=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV

	session_fixture "$agent" || return 1

	outside=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" agent-sandbox-r2.XXXXXX)
	scratch="$REPO_ROOT/.tmp/r2"
	rm -rf "$scratch"
	mkdir -p "$scratch"
	# shellcheck disable=SC2064
	trap "rm -rf '$outside' '$scratch'" RETURN

	home="$outside/home"
	mkdir -p "$home/outside"
	target="$home/outside/created.txt"
	# Per run, so a stale file from an earlier run cannot satisfy the assertion.
	canary="OUTSIDE-WRITE-$RANDOM$RANDOM"

	# Control 2. Unconfined, the target is writable.
	if ! printf '%s\n' "$canary" >"$target" 2>/dev/null || [ ! -f "$target" ]; then
		fail "the target is not writable outside the boundary, so a refusal inside it would prove nothing"
		return 1
	fi
	rm -f "$target"

	# The probe attempts the write outside first and reports its own status, so
	# the in-workdir write is attempted whatever the first one did. It writes
	# with the shell's own redirection rather than by calling a program: PATH is
	# inherited whole, host entries included, so a name resolved inside the
	# session can land on a binary the session may not read, and the probe would
	# report a denial of its own making.
	probe="$scratch/probe.sh"
	cat >"$probe" <<-'PROBE'
		out_rc=0
		printf '%s\n' "$3" >"$1" || out_rc=$?
		printf 'OUTSIDE :: %s\n' "$out_rc"
		in_rc=0
		printf '%s\n' "$3" >"$2" || in_rc=$?
		printf 'INSIDE :: %s\n' "$in_rc"
		exit "$out_rc"
	PROBE

	session_env "$outside/state"

	jq --arg d "$home/outside" '.filesystem.allow += [$d]' "$FIXTURE_PROFILE" >"$scratch/granted.json"

	for arm in shipped granted; do
		description=$FIXTURE_PROFILE
		[ "$arm" = shipped ] || description="$scratch/granted.json"
		inside="$scratch/inside-$arm.txt"
		rm -f "$target" "$inside"

		out=$(env "${SESSION_ENV[@]}" "HOME=$home" \
			"$(pinned_bin nono)/nono" run \
			--profile "$description" --workdir "$REPO_ROOT" --allow-cwd -- \
			"$FIXTURE_BASH/bin/bash" "$probe" "$target" "$inside" "$canary" 2>&1) && rc=0 || rc=$?

		# The in-workdir write is asserted in both arms: it is what says the
		# session started and the probe ran, and the granted arm needs that
		# said as much as the shipped one.
		if ! printf '%s' "$out" | grep -qF 'INSIDE :: 0' ||
			[ "$(cat "$inside" 2>/dev/null)" != "$canary" ]; then
			found=1
			fail "$(printf 'the %s arm never wrote inside the project, so it observed no session (exit %s):\n%s' \
				"$arm" "$rc" "$out")"
			continue
		fi

		if [ "$arm" = granted ]; then
			# Control 3. The probe must be able to write outside the project
			# when the boundary allows it, or the shipped arm's refusal is the
			# probe's and not the sandbox's.
			if ! printf '%s' "$out" | grep -qF 'OUTSIDE :: 0' ||
				[ "$(cat "$target" 2>/dev/null)" != "$canary" ]; then
				found=1
				fail "$(printf 'the probe cannot write outside the project even when the boundary grants it (exit %s):\n%s' \
					"$rc" "$out")"
			fi
			continue
		fi

		if printf '%s' "$out" | grep -qF 'OUTSIDE :: 0'; then
			found=1
			fail "$(printf 'a write outside the project succeeded:\n%s' "$out")"
		fi
		if ! printf '%s' "$out" | grep -q 'Permission denied'; then
			found=1
			fail "$(printf 'the write did not fail on permission, so the target may simply not have been there:\n%s' "$out")"
		fi
		# The half of the scenario the session cannot be asked about.
		if [ -e "$target" ]; then
			found=1
			fail "$(printf 'the file exists after the refused write, holding %s' "$(cat "$target")")"
		fi
	done

	[ "$found" -eq 0 ]
}

# R3. A provider API key in the host environment does not reach a session.
#
# The session command is `env -0`, which is the scenario's "prints its own
# environment" with nothing in between: no probe script, no shell, nothing that
# could filter what it saw. `-0` because one of the variables the host carries
# is the devShell's entire `shellHook` body, newlines and all, and a newline
# separator would split it into entries that parse as variables of their own.
# The output goes to a file rather than a command substitution because bash
# drops NUL bytes from `$(...)`, which would run the whole environment together
# into a single unsplittable line.
#
# Two assertions, and the second is the one that generalises:
#
#   1. The canary value does not appear anywhere in the output. It is the
#      scenario as written, and it is asserted against the *value*: the name
#      `ANTHROPIC_API_KEY` may well be set inside a session later, by the
#      credential routing, and this check must not be what breaks when it is.
#   2. Every name that crossed is sanctioned by the description itself — matched
#      by an `environment.allow_vars` pattern, or a key of `environment.set_vars`,
#      or one of the three variables nono injects. Both lists are read out of the
#      built description, so adding a variable there moves the expected set with
#      it, and no list is written down twice.
#
# The three nono injects are named here because they are the only names in the
# session that no part of this repository asked for. A fourth appearing is a
# change in nono's behaviour and worth failing over rather than tolerating.
#
# Controls, because "the secret is absent" is a claim about an absence (D9):
#
#   1. `TERM` is passed in with a canary value of its own and must arrive with
#      that value. An empty environment, or a session that never started, cannot
#      pass. That it arrives *with the host's value* is the point: it says the
#      allow-list passes things through rather than merely declaring them.
#   2. A standing second arm adds `ANTHROPIC_API_KEY` to `allow_vars`, where the
#      same canary must arrive intact. Without it, an `env` that printed nothing
#      of the host's would satisfy the shipped arm.
check_r3() {
	local agent=claude-code
	local outside home scratch secret term arm description rc out err
	local entry name pattern matched control found=0 env_pkg
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV crossed allowed declared unsanctioned leaked
	# What nono sets in every session, whatever the description says: the
	# rewritten PATH, the browser shim it interposes, and the path to the
	# capability file it hands the child.
	local -a injected=(PATH BROWSER NONO_CAP_FILE)

	session_fixture "$agent" || return 1

	env_pkg=$(substrate_member "$FIXTURE_SUBSTRATE" env) || {
		fail "the substrate for $agent provides no env, so the session cannot print its environment"
		return 1
	}

	outside=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" agent-sandbox-r3.XXXXXX)
	scratch="$REPO_ROOT/.tmp/r3"
	rm -rf "$scratch"
	mkdir -p "$scratch"
	# shellcheck disable=SC2064
	trap "rm -rf '$outside' '$scratch'" RETURN

	# Outside the project, for the reason recorded on check_r1: 48 of the deny
	# rules are $HOME-relative, and a $HOME under the workdir makes them overlap
	# a granted parent, which nono refuses to start with.
	home="$outside/home"
	mkdir -p "$home"

	# Per run, so the check asserts that no host secret crosses rather than that
	# one particular string does not, and so a value left in a stale file by an
	# earlier run cannot satisfy either assertion.
	secret="HOST-SECRET-$RANDOM$RANDOM"
	term="term-canary-$RANDOM$RANDOM"

	session_env "$outside/state"

	jq '.environment.allow_vars += ["ANTHROPIC_API_KEY"]' \
		"$FIXTURE_PROFILE" >"$scratch/granted.json"

	for arm in shipped granted; do
		description=$FIXTURE_PROFILE
		[ "$arm" = shipped ] || description="$scratch/granted.json"
		out="$scratch/env-$arm.bin"
		err="$scratch/err-$arm.txt"

		env "${SESSION_ENV[@]}" "HOME=$home" "TERM=$term" "ANTHROPIC_API_KEY=$secret" \
			"$(pinned_bin nono)/nono" run \
			--profile "$description" --workdir "$REPO_ROOT" --allow-cwd -- \
			"$env_pkg/bin/env" -0 >"$out" 2>"$err" && rc=0 || rc=$?

		mapfile -d '' -t crossed <"$out"

		# Control 1, in both arms: an allowed variable arrived with the value the
		# host gave it.
		control=0
		for entry in "${crossed[@]}"; do
			[ "$entry" = "TERM=$term" ] && control=1
		done
		if [ "$control" -eq 0 ]; then
			found=1
			fail "$(printf 'the %s arm never saw TERM=%s, so it observed no session (exit %s):\n%s' \
				"$arm" "$term" "$rc" "$(cat "$err")")"
			continue
		fi

		mapfile -t allowed < <(jq -r '.environment.allow_vars[]' "$description")
		mapfile -t declared < <(jq -r '.environment.set_vars | keys[]' "$description")

		unsanctioned=()
		for entry in "${crossed[@]}"; do
			name=${entry%%=*}
			matched=0
			for pattern in "${allowed[@]}" "${declared[@]}" "${injected[@]}"; do
				# Unquoted on purpose: allow_vars carries globs, LC_* among them.
				# shellcheck disable=SC2053
				if [[ $name == $pattern ]]; then
					matched=1
					break
				fi
			done
			[ "$matched" -eq 1 ] || unsanctioned+=("$name")
		done
		# Reported once, with a count: an unfiltered session carries upwards of
		# two hundred variables, and one failure per name buries every other
		# assertion in the suite under it.
		if [ "${#unsanctioned[@]}" -gt 0 ]; then
			found=1
			fail "$(printf '%s variable(s) crossed into the %s session that no rule in the description sanctions: %s' \
				"${#unsanctioned[@]}" "$arm" "${unsanctioned[*]}")"
		fi

		if [ "$arm" = granted ]; then
			# Control 2. The probe can see such a value when the boundary lets
			# it through, so the shipped arm's absence is the boundary's doing.
			if ! grep -qaFx "ANTHROPIC_API_KEY=$secret" <(printf '%s\n' "${crossed[@]}"); then
				found=1
				fail "$(printf 'the session cannot see ANTHROPIC_API_KEY even when the boundary allows it (exit %s):\n%s' \
					"$rc" "$(cat "$err")")"
			fi
			continue
		fi

		# The scenario. Anywhere in the output the session produced: any entry
		# whose name or value carries the canary, or anything on stderr. The
		# entries are named rather than printed, because printing them would put
		# the secret and the whole environment in the suite's own output.
		leaked=()
		for entry in "${crossed[@]}"; do
			[[ $entry == *"$secret"* ]] && leaked+=("${entry%%=*}")
		done
		if [ "${#leaked[@]}" -gt 0 ]; then
			found=1
			fail "$(printf 'the host secret crossed into the session, carried by: %s' "${leaked[*]}")"
		fi
		if grep -qF "$secret" "$err"; then
			found=1
			fail 'the host secret appears in what the session wrote to stderr'
		fi
	done

	[ "$found" -eq 0 ]
}

# R4. A session cannot widen the boundary it is running inside.
#
# The scenario in one run. A session edits `lib/leak-registry.nix`, the source
# its own description is generated from, to grant itself a directory outside
# the project, and the same directory is then read four times: before the edit
# and after it from inside that session, from a second session started once it
# has exited, and from a third session started with a description rebuilt out
# of the edited source.
#
# The grant names an exact directory inside the fake $HOME rather than $HOME
# itself, which is what the scenario's wording suggests. nono refuses to start
# when a grant covers a parent of its deny rules, measured on check_r2, so
# granting $HOME would stop every session below from starting and the refusals
# would be the refusal to start rather than the boundary holding.
#
# Controls, because three of the four readings are refusals (D9):
#
#   1. The edit is confirmed to have landed: the file on disk differs from the
#      backup and carries the planted path. A write that failed silently would
#      otherwise read as a boundary holding.
#   2. The target is unreadable *before* the edit as well. Were it reachable
#      already, "the reach is unchanged" would also be satisfied by a boundary
#      that had changed.
#   3. Rebuilding from the edited source produces a *different* description,
#      and a session started with that one does read the target. That is the
#      scenario's "until a human re-enters the environment" and the standing
#      positive control in one: the edit was well-formed, it does widen, and
#      what held the first three readings back was the description they ran
#      with.
#
# The entry point is also read directly, and that pair of greps is what the
# planted violation of this task breaks. Every session below is driven by
# handing `nono` a description path, so an entry point that resolved its
# description from `$PWD` would leave all four readings exactly as they are.
#
# stdout and stderr are kept apart rather than merged as check_r1 and check_r2
# merge them, because nono prints its whole capability banner to stderr and the
# readings would be needles in it.
check_r4() {
	local agent=claude-code
	# The flake attribute of an entry point is the binary's name, not the
	# agent's. M8 pairs the two per agent; until then both are written out.
	local entry=claude
	local entry_dir ref value registry backup outside home scratch canary
	local source needle replacement why rebuilt restored rc found=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV profile_refs

	session_fixture "$agent" || return 1

	entry_dir=$(pinned_bin "$entry") || {
		fail "the entry point $entry does not build"
		return 1
	}

	# The description every session below runs with is the one the entry point
	# would start them with, so what they observe is what a user would.
	if ! grep -qF "$FIXTURE_PROFILE" "$entry_dir/$entry"; then
		found=1
		fail 'the entry point does not name the description this check probes with, so the session it starts is not the session measured here'
	fi
	# Every description the entry point names is either the store path this
	# check probes with or the variable holding it. A line-level search for
	# `$PWD` near `--profile` will not do: the same line legitimately carries
	# `--workdir "$PWD"`, and matching it reports the workdir as if it were the
	# description.
	mapfile -t profile_refs < <(grep -oE -- '(--profile|PREFLIGHT_PROFILE=)[[:space:]]*[^[:space:]]+' "$entry_dir/$entry")
	if [ "${#profile_refs[@]}" -eq 0 ]; then
		found=1
		fail 'the entry point names no description at all, so it is not the mechanism this check measures'
	fi
	for ref in "${profile_refs[@]}"; do
		value=${ref#*=}
		value=${value#--profile }
		value=${value#\"}
		value=${value%\"}
		# The first arm is the literal text in the built script, not this
		# shell's value of it.
		# shellcheck disable=SC2016
		case $value in
		'$PREFLIGHT_PROFILE' | "$FIXTURE_PROFILE") ;;
		*)
			found=1
			fail "$(printf 'the entry point takes its description from %s rather than from the store, so a session could write what its successor starts from' \
				"$value")"
			;;
		esac
	done

	outside=$(mktemp -d -p "${XDG_RUNTIME_DIR:-/tmp}" agent-sandbox-r4.XXXXXX)
	scratch="$REPO_ROOT/.tmp/r4"
	rm -rf "$scratch"
	mkdir -p "$scratch"

	registry="$REPO_ROOT/lib/leak-registry.nix"
	backup="$scratch/leak-registry.nix.orig"
	cp -p "$registry" "$backup"
	# Restored before the directory holding the backup is removed. A run killed
	# outside bash's control leaves the registry edited, and
	# `git checkout -- lib/leak-registry.nix` is the repair.
	# shellcheck disable=SC2064
	trap "cp -pf '$backup' '$registry'; rm -rf '$outside' '$scratch'" RETURN

	# Outside the project, for the reason recorded on check_r1.
	home="$outside/home"
	mkdir -p "$home/reach"
	canary="REACH-CANARY-$RANDOM$RANDOM"
	printf '%s\n' "$canary" >"$home/reach/target.txt"

	session_env "$outside/state"

	# The widening the session will write. $HOME stays unexpanded: nix does not
	# interpolate it, and nono expands it at the boundary. Failing on a missing
	# needle rather than writing the file unchanged, because a registry that had
	# been refactored would otherwise leave this check passing on an edit that
	# widened nothing.
	needle='entries = map checkEntry [ ];'
	why='PLANTED by check_r4 from inside a session, restored before it returns.'
	# shellcheck disable=SC2016
	replacement=$(printf 'entries = map checkEntry [\n    {\n      path = "%s";\n      mode = "read";\n      agents = [ "%s" ];\n      why = "%s";\n      whyNotNarrower = "%s";\n    }\n  ];' \
		'$HOME/reach' "$agent" "$why" "$why")
	source=$(<"$registry")
	if [[ $source != *"$needle"* ]]; then
		fail "lib/leak-registry.nix no longer contains '$needle', so this check cannot widen it"
		return 1
	fi
	printf '%s\n' "${source/"$needle"/$replacement}" >"$scratch/widened.nix"

	# Builtins only, for the reason recorded on check_r1: PATH is inherited
	# whole, host entries and all, so a name could resolve to a binary the
	# session may not execute.
	cat >"$scratch/probe-edit.sh" <<-'PROBE'
		before_rc=0
		before=$(<"$1") || before_rc=$?
		printf 'BEFORE :: %s :: %s\n' "$before_rc" "$before"
		edit_rc=0
		printf '%s\n' "$(<"$2")" >"$3" || edit_rc=$?
		printf 'EDIT :: %s\n' "$edit_rc"
		after_rc=0
		after=$(<"$1") || after_rc=$?
		printf 'AFTER :: %s :: %s\n' "$after_rc" "$after"
	PROBE
	cat >"$scratch/probe-read.sh" <<-'PROBE'
		rc=0
		value=$(<"$1") || rc=$?
		printf 'READ :: %s :: %s\n' "$rc" "$value"
	PROBE

	# Reading 1 and 2, in the session that does the editing.
	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "$REPO_ROOT" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$scratch/probe-edit.sh" \
		"$home/reach/target.txt" "$scratch/widened.nix" "$registry" \
		>"$scratch/edit.out" 2>"$scratch/edit.err" && rc=0 || rc=$?

	if ! grep -qFx 'EDIT :: 0' "$scratch/edit.out"; then
		fail "$(printf 'the session did not rewrite the source of its own confinement (exit %s), so nothing below was tested:\n%s' \
			"$rc" "$(tail -n 5 "$scratch/edit.err")")"
		return 1
	fi
	# Control 1. The claim under test is about a boundary, not about a write
	# that quietly did nothing.
	if cmp -s "$backup" "$registry"; then
		fail 'the registry on disk is unchanged after the session reported writing it, so the write never landed'
		return 1
	fi
	# shellcheck disable=SC2016
	if ! grep -qF '$HOME/reach' "$registry"; then
		fail 'the registry on disk does not carry the planted grant, so the session wrote something else'
		return 1
	fi
	# Control 2.
	if grep -q '^BEFORE :: 0 ' "$scratch/edit.out"; then
		found=1
		fail 'the target outside the project was readable before the edit, so a reach that did not change proves nothing'
	fi
	# The scenario's first half.
	if grep -q '^AFTER :: 0 ' "$scratch/edit.out"; then
		found=1
		fail 'the running session read a path its own edit granted, so an edit widens the boundary it is made inside'
	fi
	if grep -qF "$canary" "$scratch/edit.out"; then
		found=1
		fail 'the canary from outside the project appears in the output of the session that planted the grant for it'
	fi

	# Reading 3, in a session started after the editing one exited, with the
	# environment not re-entered: the same description, deliberately.
	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "$REPO_ROOT" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$scratch/probe-read.sh" \
		"$home/reach/target.txt" \
		>"$scratch/before.out" 2>"$scratch/before.err" && rc=0 || rc=$?

	if ! grep -q '^READ :: ' "$scratch/before.out"; then
		found=1
		fail "$(printf 'the session started after the edit produced no reading at all (exit %s), so it observed nothing:\n%s' \
			"$rc" "$(tail -n 5 "$scratch/before.err")")"
	elif grep -q '^READ :: 0 ' "$scratch/before.out" || grep -qF "$canary" "$scratch/before.out"; then
		found=1
		fail 'a session started after the edit, without the environment being re-entered, read a path the edit granted'
	fi

	# Control 3, in two parts. The build log is captured because a dirty tree
	# makes nix warn, and a warning on the suite's stderr reads as the suite
	# having left the tree changed.
	rebuilt=$(nix build --no-link --print-out-paths "$REPO_ROOT#confinement-$agent" 2>"$scratch/build.log") || {
		fail "$(printf 'the edited registry does not evaluate, so the widening this check plants is not a valid one:\n%s' \
			"$(tail -n 5 "$scratch/build.log")")"
		return 1
	}
	if [ "$rebuilt" = "$FIXTURE_PROFILE" ]; then
		fail 'rebuilding after the edit produced the same description, so the edit reached nothing and the readings above are not evidence'
		return 1
	fi

	# Reading 4, with the rebuilt description: the re-entry the scenario says
	# the widening waits for.
	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$rebuilt" --workdir "$REPO_ROOT" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$scratch/probe-read.sh" \
		"$home/reach/target.txt" \
		>"$scratch/after.out" 2>"$scratch/after.err" && rc=0 || rc=$?

	if ! grep -qFx "READ :: 0 :: $canary" "$scratch/after.out"; then
		found=1
		fail "$(printf 'a session started from the rebuilt description cannot read the target either (exit %s), so what held the readings above back was something other than the description they ran with:\n%s' \
			"$rc" "$(tail -n 5 "$scratch/after.err")")"
	fi

	# Left as found, and said so rather than assumed: the description this check
	# started from is the one the restored source produces.
	cp -pf "$backup" "$registry"
	restored=$(nix build --no-link --print-out-paths "$REPO_ROOT#confinement-$agent" 2>>"$scratch/build.log") || {
		fail 'the registry does not evaluate after being restored, so this check has left the tree broken'
		return 1
	}
	if [ "$restored" != "$FIXTURE_PROFILE" ]; then
		found=1
		fail 'restoring the registry did not reproduce the description this check started from, so it has left the source changed'
	fi

	[ "$found" -eq 0 ]
}
