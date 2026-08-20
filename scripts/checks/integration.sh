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
	local outside home key inside probe scratch profile substrate bash_pkg
	local key_canary inside_canary arm description rc out found=0
	local -a SESSION_ENV

	profile=$(nix build --no-link --print-out-paths "$REPO_ROOT#confinement-$agent") || {
		fail "the confinement for $agent does not build"
		return 1
	}
	substrate=$(nix build --no-link --print-out-paths "$REPO_ROOT#substrate-$agent") || {
		fail "the execution substrate for $agent does not build"
		return 1
	}
	bash_pkg=$(substrate_member "$substrate" bash) || {
		fail "the substrate provides no bash to run the probe"
		return 1
	}

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

	jq --arg d "$home/.ssh" '.filesystem.read += [$d]' "$profile" >"$scratch/granted.json"

	for arm in shipped granted; do
		description=$profile
		[ "$arm" = shipped ] || description="$scratch/granted.json"

		out=$(env "${SESSION_ENV[@]}" "HOME=$home" \
			"$(pinned_bin nono)/nono" run \
			--profile "$description" --workdir "$REPO_ROOT" --allow-cwd -- \
			"$bash_pkg/bin/bash" "$probe" "$key" "$inside" 2>&1) && rc=0 || rc=$?

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
