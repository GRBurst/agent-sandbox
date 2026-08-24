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
#   2. XDG_STATE_HOME, and every fabricated host home, in a location the
#      session is granted nothing on — `outside_root` in scripts/validate.sh
#      derives one and says why no path can simply be written down. nono
#      protects its own state root by refusing to start when a granted path
#      overlaps it, so a directory the floor merely reads is as unusable as the
#      project itself, and on macOS that rules out every conventional
#      temporary directory (M9d).
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

# TEMPORARY (M9d iteration 3). What appears in a fabricated home while sessions
# run against it. The macOS run reported the home directory's own line differing
# in modification time alone, with its size and every child identical, so
# something was created and removed inside the window rather than left behind.
# A poller beside the session names it; a directory listing afterwards cannot.
#
# The poller is started before the first session and stopped before the
# comparison, and its findings are printed by `dbg_watch_stop`, which the driver
# shows only when the check fails.
dbg_watch_start() {
	local dir=$1 seen=$2
	: >"$seen"
	# Both streams are closed in the child, and the reason is measured: the
	# caller reads this function through a command substitution, and a
	# background process holding that pipe open keeps the substitution waiting
	# for an EOF that never comes. The first draft hung the whole check.
	(
		while :; do
			ls -A "$dir" >>"$seen" 2>/dev/null
			# Fractional sleep where the platform has one, a tight loop where
			# it does not: an unsupported argument must not print per pass.
			sleep 0.02 2>/dev/null || :
		done
	) >/dev/null 2>&1 &
	printf '%s\n' "$!"
}

dbg_watch_stop() {
	local label=$1 pid=$2 seen=$3 dir=$4
	{ kill "$pid" && wait "$pid"; } 2>/dev/null || true
	dbg "$label: entries ever seen: $(sort -u "$seen" | tr '\n' ' ')"
	dbg "$label: entries now: $(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f ')"
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

# Whether nono reported on the denials of a session at all.
#
# The supervisor closes every session with either a count of what it blocked or
# a line saying it blocked nothing, so this is the trailer's answer to the
# question a syscall trace answers by existing: was anything watching. Without
# it, an empty denial set is silence rather than evidence.
session_reported() {
	local err=$1
	grep -qaE '[0-9]+ paths? blocked|No path denials were observed' "$err"
}

# The paths a session was refused, one `<path> (<mode>)` per line, sorted.
#
# Landlock tells nono nothing about what it blocked, so on Linux this is always
# empty and a syscall trace is the instrument. Seatbelt reports every refusal to
# it, so on macOS this is the only instrument there is — no tracer runs there
# without SIP disabled or root.
#
# The header's own count is asserted against the number of lines parsed, and a
# disagreement is reported in the set itself. A trailer that summarised instead
# of enumerating would otherwise read as a short list of denials rather than as
# an unknown one, which is the silent pass P9 forbids.
session_denials() {
	local err=$1
	awk '
		/[0-9]+ paths? blocked/ {
			for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) { want += $i; counted = 1; break }
			inside = 1
			next
		}
		inside && /^[[:space:]]+.+ \((read|write|execute)\)/ {
			line = $0
			sub(/^[[:space:]]+/, "", line)
			sub(/[[:space:]]*\[[^]]*\][[:space:]]*$/, "", line)
			print line
			seen++
			next
		}
		inside && /^[[:space:]]*$/ { next }
		inside { inside = 0 }
		END {
			# Summed rather than taken from the last header, so a stderr
			# carrying more than one trailer is checked as a whole.
			if (counted && want + 0 != seen + 0) {
				printf "the trailer counts %s blocked path(s) and enumerates %s\n", want + 0, seen + 0
			}
		}
	' "$err" | sort
}

# The capability set a session was started with, one grant per line, sorted.
#
# nono prints it to stderr before the program runs, so a session's whole
# granted reach is observable from outside without a shell inside it. That is
# what lets a check compare the reach of two real agent starts, rather than
# inferring reach from one read that failed.
#
# A grant line's first field is its mode: `r`, `w`, `x`, `r+w`, `net`, or `+`
# for the paths nono summarises rather than lists. Everything else nono writes
# to stderr is prose and is not a grant. Whitespace is squeezed so the set is
# compared by content and not by column alignment.
#
# An empty result is a real answer — a session that refused to start grants
# nothing — so the grep's non-zero exit is swallowed and the caller is left to
# assert that the set is not empty.
granted_reach() {
	local err=$1
	{ grep -aE '^[[:space:]]+(r|w|x|r\+w|net|\+)[[:space:]]' "$err" || true; } |
		sed 's/^[[:space:]]*//; s/[[:space:]]\{1,\}/ /g' | sort
}

# Whether a granted-reach set grants a path, in any mode matching a pattern.
#
# By field rather than by literal line, so an assertion is about the mode and
# the path and not about how nono decorates them. `.` for any mode at all.
reach_grants() {
	local set=$1 path=$2 mode=$3
	awk -v p="$path" -v m="$mode" '$1 ~ m && $2 == p { found = 1 } END { exit !found }' "$set"
}

# R6 — a host that cannot enforce confinement refuses, naming the primitive.
#
# Five arms, because an exit status of 77 on its own does not say what earned
# it. The control arm runs the real pre-flight on this machine and must exit 0,
# so a pre-flight that refused every host could not pass. The plant arm puts a
# passthrough `nono` earlier on PATH — present, accepting the same arguments,
# enforcing nothing — which is what an unenforceable host looks like from the
# pre-flight's side, and must produce 77 and the primitive. The third arm takes
# away the positive control, which the first two leave untested. The fourth
# grants the location the pre-flight probes, which is the one way a working
# boundary can look broken, and the arm exists because the pre-flight used to
# call that case a violation. The fifth asserts the working-directory consent on
# every confined child the pre-flight starts, because without it the pre-flight
# hangs for a human and passes for this suite.
check_r6() {
	local preflight tmp outside state profile pinned rc out unreadable granted logged consenting found=0
	local -a SESSION_ENV
	preflight="$REPO_ROOT/lib/preflight.sh"

	if [ ! -f "$preflight" ]; then
		fail "lib/preflight.sh: no such file"
		return 1
	fi

	tmp=$(mktemp -d "$REPO_ROOT/.tmp/integration.XXXXXX")
	outside=$(outside_root r6) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp' '$outside'" RETURN

	state="$outside/state"
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
	# probe reads and writes freely and the pre-flight must refuse.
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
	# The refusal carries a verdict per location tried, so it says which way the
	# host failed rather than only that it did. Without this, a pre-flight that
	# lost the probe entirely and refused every host would still satisfy the
	# assertions above.
	if ! printf '%s' "$out" | grep -q 'was not refused'; then
		found=1
		fail "$(printf 'the refusal does not say the probe went through:\n%s' "$out")"
	fi

	# The third arm covers the positive control itself. Arms one and two both
	# leave it untested, because every location the pre-flight probes happens to
	# be readable on this machine — so deleting that assertion would go
	# unnoticed. A host where no location outside the project can be read
	# unconfined cannot demonstrate enforcement, because a denial there would be
	# indistinguishable from the same refusal without a boundary, and it must
	# refuse rather than report success (D5).
	#
	# Both locations the pre-flight tries are pointed at the unreadable one, so
	# neither can carry the proof and the refusal has to list both. They are
	# outside the project, which the arm originally was not. nono derives its
	# dotfile deny rules from $HOME, so a $HOME inside a granted project makes
	# every one of them overlap an allowed parent and nono refuses to start at
	# all — assertion 1, not the positive control this arm exists for. That went
	# unnoticed while the pre-flight granted no project. A host's home directory
	# is not inside the checkout anyway, so this is the more faithful
	# arrangement as well as the working one.
	unreadable="$outside/unreadable"
	mkdir -p "$unreadable"
	chmod 000 "$unreadable"
	# Supersedes the RETURN trap set above, and repeats its removals because
	# bash keeps one trap per signal rather than a list. The chmod comes first:
	# `rm -rf` cannot descend into a directory it may not read.
	# shellcheck disable=SC2064
	trap "chmod 700 '$unreadable'; rm -rf '$tmp' '$outside'" RETURN
	out=$(cd "$REPO_ROOT" && env "${SESSION_ENV[@]}" PATH="$pinned:$PATH" \
		XDG_RUNTIME_DIR="$unreadable" HOME="$unreadable" PREFLIGHT_PROFILE="$profile" \
		bash -c "source '$preflight'; preflight_or_die" 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 77 ]; then
		found=1
		fail "$(printf 'a host with no positive control was not refused with 77: exit %s\n%s' "$rc" "$out")"
	fi
	if ! printf '%s' "$out" | grep -q 'cannot verify confinement'; then
		found=1
		fail "$(printf 'the refusal does not say confinement could not be verified:\n%s' "$out")"
	fi
	if ! printf '%s' "$out" | grep -q 'not readable from here'; then
		found=1
		fail "$(printf 'the refusal does not say why the location could not serve:\n%s' "$out")"
	fi

	# The fourth arm is the case the pre-flight used to get backwards. Where
	# something grants the location being probed, the probe reads it and the
	# boundary is working exactly as asked — the observation is void, not
	# violated. The canary this replaced called that "a confined process wrote
	# outside the project", accusing a correctly confined session, and no arm
	# noticed because on this machine nothing grants that location.
	#
	# The grant goes on the profile rather than the command line, so the
	# pre-flight's own invocation is what carries it, and it goes on the
	# XDG_RUNTIME_DIR candidate rather than $HOME because nono refuses to grant
	# a directory holding its own state root, which $HOME does.
	#
	# $HOME keeps arm three's unreadable directory, so the pre-flight runs out
	# of locations instead of falling through to a home that would demonstrate
	# enforcement honestly and hide what this arm is about. That the granted
	# location is reported at all is the assertion; the host's real home would
	# make it a passing run with an unread verdict.
	granted="$outside/granted"
	mkdir -p "$granted"
	jq --arg d "$granted" '.filesystem.read += [$d]' "$profile" >"$tmp/granted.json"
	out=$(cd "$REPO_ROOT" && env "${SESSION_ENV[@]}" PATH="$pinned:$PATH" \
		XDG_RUNTIME_DIR="$granted" HOME="$unreadable" PREFLIGHT_PROFILE="$tmp/granted.json" \
		bash -c "source '$preflight'; preflight_or_die" 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 77 ]; then
		found=1
		fail "$(printf 'a granted probe location did not refuse with 77: exit %s\n%s' "$rc" "$out")"
	fi
	if ! printf '%s' "$out" | grep -q 'cannot verify confinement'; then
		found=1
		fail "$(printf 'a granted probe location was reported as a boundary failure rather than an unusable observation:\n%s' "$out")"
	fi
	if ! printf '%s' "$out" | grep -q 'the confined read was not refused'; then
		found=1
		fail "$(printf 'the refusal does not name the granted location as the one that answered:\n%s' "$out")"
	fi
	if printf '%s' "$out" | grep -q 'confinement is not enforced'; then
		found=1
		fail "$(printf 'the pre-flight accused a session that was confined as asked:\n%s' "$out")"
	fi

	# The fifth arm covers what no other arm here can reach: the pre-flight on
	# a terminal. `--allow-cwd` is the working-directory consent, and a
	# `nono run` without it *asks* — on stdin, in a message the pre-flight sends
	# to /dev/null with everything else. An interactive user got a cursor and no
	# explanation. Every arm above, and every check in this suite, runs under
	# validate.sh's `</dev/null`, so all of them take nono's non-interactive
	# path and none of them can ever see the question.
	#
	# Allocating a pty would be the direct observation, and it is not available:
	# a nested sandbox denies /dev/ptmx, so the check would skip on exactly the
	# machine most likely to run it. So the arm observes the argv the pre-flight
	# builds instead — the real invocation, through a stub that logs and
	# delegates, rather than the source text of this file — and asserts the
	# property over every `run` it makes, so an invocation added later is
	# covered without this arm being touched.
	mkdir -p "$tmp/logging"
	cat >"$tmp/logging/nono" <<-STUB
		#!/usr/bin/env bash
		printf '%s\t' "\$@" >>'$tmp/argv.log'
		printf '\n' >>'$tmp/argv.log'
		exec '$pinned/nono' "\$@"
	STUB
	chmod +x "$tmp/logging/nono"

	out=$(cd "$REPO_ROOT" && env "${SESSION_ENV[@]}" PATH="$tmp/logging:$pinned:$PATH" \
		PREFLIGHT_PROFILE="$profile" \
		bash -c "source '$preflight'; preflight_or_die" 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		found=1
		fail "$(printf 'the pre-flight refused a host that does enforce confinement: exit %s\n%s' "$rc" "$out")"
	fi

	logged=$(grep -c $'^run\t' "$tmp/argv.log" 2>/dev/null || true)
	consenting=$(grep $'^run\t' "$tmp/argv.log" 2>/dev/null | grep -c $'\t--allow-cwd\t' || true)
	if [ "${logged:-0}" -eq 0 ]; then
		found=1
		fail 'the pre-flight ran no confined child; there is nothing to assert consent about'
	elif [ "$consenting" -ne "$logged" ]; then
		found=1
		fail "$(printf '%s of the pre-flight'"'"'s %s confined runs pass --allow-cwd; without it nono asks for the working directory on a stdin the pre-flight has sent to /dev/null, and an interactive terminal hangs on a prompt it cannot see:\n%s' \
			"$consenting" "$logged" "$(cat "$tmp/argv.log")")"
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
	local tmp outside state profile substrate store claude strace arm rc
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
	outside=$(outside_root substrate-denials) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	state="$outside/state"
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
# The key lives in a fake $HOME under a derived scratch root rather than in the
# project's own scratch directory, and that is forced rather than tidiness: the
# resolved description carries 48 $HOME-relative deny rules, so a $HOME under
# the granted project makes every one of them overlap an allowed parent and
# nono refuses to start (D15). The check would then observe a refusal to start
# and call it a refusal to read.
#
# Both halves of the scenario are asserted, and the probe prints the key
# material it managed to read on purpose: an assertion that no key material
# appears in the output is worth nothing against a probe that never shows it.
# Each read reports its own status, so the refusal is read off the read that
# was refused rather than off the exit status of the whole probe.
#
# The session also reads a plain file beside the key, and that is not padding.
# nono protects `$HOME/.ssh` of its own accord, whatever the description says,
# so a key refused inside a session says nothing on its own about the project
# boundary: it would be refused by a session with no boundary at all. The plain
# file is denied by reach and by nothing else, so it is the one that carries
# the scenario. The key stays because R1 is written about a key.
#
# Two controls, because the observable is a failure (D9):
#
#   1. In the same session, a file inside the project is read successfully. A
#      session that died at startup, or a probe that could read nothing at all,
#      cannot pass.
#   2. Both targets are read once from outside the boundary before the session
#      runs, so the denials are attributable to confinement rather than to a
#      plant that never landed. This is also what stands in for asserting the
#      wording of the refusal: a file that had simply never been there would
#      fail the read just as convincingly, and control 2 is what rules that
#      out. The wording itself cannot be asserted, because the platform
#      decides which errno its enforcement returns.
#
# The third arm is a standing positive control on the probe itself: with the
# plain file's directory added to `filesystem.read`, the same probe must read
# it out. It names the exact directory and never an ancestor, because a grant
# above a denied path is refused at startup rather than widened.
#
# That arm grants the plain directory and not the key's, and the difference is
# a platform divergence worth recording. On Linux a grant naming `$HOME/.ssh`
# wins: `deny_credentials` is `required` and denies that path, and the key
# reads out anyway, so nothing stands behind the registry's own strictness. On
# macOS the same grant does not win — the session's own report marks the key
# `[permanently restricted]` and points at `filesystem.bypass_protection` — so
# the two enforcements differ in what a description can ask for. Neither
# platform's answer can be asserted as the other's, and the shipped reach is
# the same on both because neither grants the directory at all. The key is
# asserted refused in this arm too, which is what says the grant stayed as
# narrow as it was written.
check_r1() {
	local agent=claude-code
	local outside home key inside probe scratch plain plain_dir
	local key_canary plain_canary inside_canary arm description rc out found=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV

	session_fixture "$agent" || return 1

	outside=$(outside_root r1) || return 1
	scratch="$REPO_ROOT/.tmp/r1"
	rm -rf "$scratch"
	mkdir -p "$scratch"
	# shellcheck disable=SC2064
	trap "rm -rf '$outside' '$scratch'" RETURN

	home="$outside/home"
	key="$home/.ssh/id_ed25519"
	plain_dir="$home/plain"
	plain="$plain_dir/notes.txt"
	mkdir -p "$home/.ssh" "$plain_dir"
	# Per run, so a stale match in a log cannot satisfy the assertion.
	key_canary="PLANTED-KEY-MATERIAL-$RANDOM$RANDOM"
	plain_canary="PLANTED-PLAIN-CONTENT-$RANDOM$RANDOM"
	inside_canary="PROJECT-FILE-CONTENT-$RANDOM$RANDOM"
	printf '%s\n' "$key_canary" >"$key"
	chmod 600 "$key"
	printf '%s\n' "$plain_canary" >"$plain"
	inside="$scratch/inside.txt"
	printf '%s\n' "$inside_canary" >"$inside"

	# Control 2. Unconfined, both targets read.
	if [ "$(cat "$key")" != "$key_canary" ]; then
		fail "the planted key is not readable outside the boundary, so a denial inside it would prove nothing"
		return 1
	fi
	if [ "$(cat "$plain")" != "$plain_canary" ]; then
		fail "the planted file is not readable outside the boundary, so a denial inside it would prove nothing"
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
		plain_rc=0
		plain=$(<"$2") || plain_rc=$?
		printf 'KEY :: %s\n' "$key"
		printf 'PLAIN :: %s\n' "$plain"
		printf 'KEY_RC :: %s\n' "$key_rc"
		printf 'PLAIN_RC :: %s\n' "$plain_rc"
		printf 'INSIDE :: %s\n' "$(<"$3")"
	PROBE

	session_env "$outside/state"

	jq --arg d "$plain_dir" '.filesystem.read += [$d]' "$FIXTURE_PROFILE" >"$scratch/granted.json"

	for arm in shipped granted; do
		description=$FIXTURE_PROFILE
		[ "$arm" = shipped ] || description="$scratch/granted.json"

		out=$(env "${SESSION_ENV[@]}" "HOME=$home" \
			"$(pinned_bin nono)/nono" run \
			--profile "$description" --workdir "$REPO_ROOT" --allow-cwd -- \
			"$FIXTURE_BASH/bin/bash" "$probe" "$key" "$plain" "$inside" 2>&1) && rc=0 || rc=$?

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
			# Control 3. The probe must be able to read a file under the fake
			# home when the boundary allows that directory, or the shipped
			# arm's refusals are the probe's and not the sandbox's.
			if ! printf '%s' "$out" | grep -qF "PLAIN :: $plain_canary"; then
				found=1
				fail "$(printf 'the probe cannot read a file outside the project even when the boundary grants it (exit %s):\n%s' \
					"$rc" "$out")"
			fi
			# The grant named one directory, so the credential beside it stays
			# out of reach. Without this, a grant that quietly widened to the
			# whole fake home would pass.
			if printf '%s' "$out" | grep -qF "$key_canary"; then
				found=1
				fail "$(printf 'granting one directory outside the project also handed over the key beside it:\n%s' "$out")"
			fi
			continue
		fi

		if printf '%s' "$out" | grep -qF 'KEY_RC :: 0'; then
			found=1
			fail "$(printf 'reading a key outside the project succeeded:\n%s' "$out")"
		fi
		if printf '%s' "$out" | grep -qF 'PLAIN_RC :: 0'; then
			found=1
			fail "$(printf 'reading a plain file outside the project succeeded:\n%s' "$out")"
		fi
		if printf '%s' "$out" | grep -qF "$key_canary"; then
			found=1
			fail "$(printf 'key material appears in the output of the confined session:\n%s' "$out")"
		fi
		if printf '%s' "$out" | grep -qF "$plain_canary"; then
			found=1
			fail "$(printf 'file content from outside the project appears in the output of the confined session:\n%s' "$out")"
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
# the host is the fact the scenario is about.
#
# The refusal's wording is deliberately not asserted. It reads `Permission
# denied` where Landlock enforces and `Operation not permitted` where Seatbelt
# does, because each returns the errno its own mechanism reports, and pinning
# either one describes a platform rather than the property. What that assertion
# was guarding against — a write that failed because the path had never been
# writable — is what controls 2 and 3 below rule out, each by writing that exact
# path successfully.
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

	outside=$(outside_root r2) || return 1
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
	local -a SESSION_ENV crossed allowed declared sanctioned unsanctioned leaked
	# What nono sets in every session, whatever the description says: the
	# rewritten PATH, the browser shim it interposes, and the path to the
	# capability file it hands the child.
	local -a injected=(PATH BROWSER NONO_CAP_FILE)

	# What a credential route adds, measured in M7a: the credential and the
	# mediated base URL the service policy names, the five trust bundles the
	# interception it switches on needs, and the nine names that point a client
	# at the proxy. These are written down rather than derived because they come
	# out of the mechanism's own policy for a built-in service, not out of this
	# repository's description -- the same reason `injected` above is a literal.
	# The list is only consulted when the description asks for a route, so a
	# session with no route still refuses every one of these names.
	local -a routed=(
		ANTHROPIC_API_KEY ANTHROPIC_BASE_URL
		SSL_CERT_FILE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS
		CURL_CA_BUNDLE GIT_SSL_CAINFO
		http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
		no_proxy NO_PROXY NONO_NO_PROXY NONO_PROXY_TOKEN
		NODE_USE_ENV_PROXY
	)

	session_fixture "$agent" || return 1

	env_pkg=$(substrate_member "$FIXTURE_SUBSTRATE" env) || {
		fail "the substrate for $agent provides no env, so the session cannot print its environment"
		return 1
	}

	outside=$(outside_root r3) || return 1
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

	# Two names granted, because M7a measured a credential route overriding an
	# explicit grant on the name its service policy claims. Granting only that
	# name would leave the arm asserting nothing it could ever see.
	jq '.environment.allow_vars += ["ANTHROPIC_API_KEY", "MOCK_UNROUTED_KEY"]' \
		"$FIXTURE_PROFILE" >"$scratch/granted.json"

	for arm in shipped granted; do
		description=$FIXTURE_PROFILE
		[ "$arm" = shipped ] || description="$scratch/granted.json"
		out="$scratch/env-$arm.bin"
		err="$scratch/err-$arm.txt"

		env "${SESSION_ENV[@]}" "HOME=$home" "TERM=$term" \
			"ANTHROPIC_API_KEY=$secret" "MOCK_UNROUTED_KEY=$secret" \
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

		# A route's names are sanctioned only where the description asks for a
		# route, so a session with none still refuses every one of them.
		sanctioned=("${allowed[@]}" "${declared[@]}" "${injected[@]}")
		if [ "$(jq -r '.network.credentials // [] | length' "$description")" -gt 0 ]; then
			sanctioned+=("${routed[@]}")
		fi

		unsanctioned=()
		for entry in "${crossed[@]}"; do
			name=${entry%%=*}
			matched=0
			for pattern in "${sanctioned[@]}"; do
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
			# Control 2. The probe can see a host value when the boundary lets it
			# through, so the shipped arm's absence is the boundary's doing. The
			# name is one no service policy claims, because the one that is
			# claimed cannot demonstrate this -- see the assertion below.
			if ! grep -qaFx "MOCK_UNROUTED_KEY=$secret" <(printf '%s\n' "${crossed[@]}"); then
				found=1
				fail "$(printf 'the session cannot see a host value even when the boundary allows it (exit %s):\n%s' \
					"$rc" "$(cat "$err")")"
			fi

			# And the property that control cost us, asserted rather than lost:
			# on a name a credential route claims, the route wins over an
			# explicit grant, so FR-6 does not rest on the grant being withheld.
			if grep -qaFx "ANTHROPIC_API_KEY=$secret" <(printf '%s\n' "${crossed[@]}"); then
				found=1
				fail 'an explicit grant on a routed name let the host credential through, so the route is a filter a widening can get behind'
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

	outside=$(outside_root r4) || return 1
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

# R5 — an untrusted repository cannot grant itself paths.
#
# The subject is the *real entry point*, not a `nono run` this check composes.
# Every other check in this file supplies `--profile` itself, so an entry point
# that let the checkout name its description would leave all of them passing;
# that violation is only visible to a check that starts the agent the way a
# user does. `claude --version` is the whole session: nono prints the granted
# reach before the program runs, so the reach of a real start is observable
# without a shell inside it, and the version exits in about a second.
#
# The observable is therefore a **set**, compared between starts, and R5's
# "unchanged" is asserted as set equality rather than as a read that failed. A
# widening that granted some *other* path than the one requested would satisfy
# "the requested path is absent" and is caught here.
#
# The checkout's request is modelled in both channels a checkout has: a nono
# user profile, and `config.toml`. Neither is contrived — the devShell points
# XDG_CONFIG_HOME at $PWD/.config, so `$XDG_CONFIG_HOME/nono/`, where nono
# looks for both, is already a directory inside every project. This check
# exports a scratch root of its own rather than writing a hostile profile into
# the developer's live .config. The profile is named after the agent because
# that is the name a wrapper resolving by name would ask for, which is the
# violation recorded against this check in the plan.
check_r5() {
	local agent=claude-code
	# The flake attribute of an entry point is the binary's name, not the
	# agent's, as recorded on check_r4.
	local entry=claude
	local entry_dir outside home scratch cfg canary hostile rc found=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV

	session_fixture "$agent" || return 1

	entry_dir=$(pinned_bin "$entry") || {
		fail "the entry point $entry does not build"
		return 1
	}

	outside=$(outside_root r5) || return 1
	scratch="$REPO_ROOT/.tmp/r5"
	rm -rf "$scratch"
	mkdir -p "$scratch"
	# shellcheck disable=SC2064
	trap "rm -rf '$outside' '$scratch'" RETURN

	# Outside the project, for the reason recorded on check_r1.
	home="$outside/home"
	mkdir -p "$home"
	hostile="$outside/reach"
	mkdir -p "$hostile"
	canary="REACH-CANARY-$RANDOM$RANDOM"
	printf '%s\n' "$canary" >"$hostile/target.txt"

	session_env "$outside/state"

	# The config root the checkout controls, and the two files it puts there.
	# The profile is the shipped description with one directory added, so a
	# session that resolved it differs from a shipped one by exactly that
	# grant and by nothing else.
	cfg="$scratch/cfg"
	mkdir -p "$cfg/nono/profiles"
	jq --arg d "$hostile" '.filesystem.read += [$d]' "$FIXTURE_PROFILE" \
		>"$cfg/nono/profiles/$agent.json" || {
		fail 'the shipped description is not JSON this check can widen, so the request it plants is not a valid one'
		return 1
	}
	# The second channel. nono reads config.toml from the same root, and it is
	# read: a malformed one stops every session on the machine from starting,
	# which is D19. What it cannot do is widen, and this asserts that rather
	# than assuming it, because a file that is ignored and a file that grants
	# nothing look identical from outside.
	{
		printf '[extensions]\n'
		printf 'extra_flags = ["--allow", "%s"]\n' "$hostile"
		printf 'extra_env_vars = { NONO_ALLOW = "%s" }\n' "$hostile"
		printf '[overrides]\n'
		printf 'paths = ["%s"]\n' "$hostile"
	} >"$cfg/nono/config.toml"

	# Arm 1, the scenario: a real start, in a checkout carrying both files.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		"$entry_dir/$entry" --version \
		>"$scratch/hostile.out" 2>"$scratch/hostile.err" && rc=0 || rc=$?
	granted_reach "$scratch/hostile.err" >"$scratch/hostile.set"

	# Control, and first, per D9: a session that refused to start grants
	# nothing, and every comparison below would pass on empty sets.
	if ! reach_grants "$scratch/hostile.set" "$REPO_ROOT" w; then
		found=1
		fail "$(printf 'the entry point started no session granting the project with the checkout'\''s own configuration present (exit %s), so R5 was not measured:\n%s' \
			"$rc" "$(tail -n 5 "$scratch/hostile.err")")"
	# The scenario's Then, in its narrow form: the path the checkout asked for.
	elif reach_grants "$scratch/hostile.set" "$hostile" .; then
		found=1
		fail 'a session started in a checkout that requested a path outside the project was granted that path, so a repository grants itself reach'
	fi

	# Arm 2, the control that the request was refused rather than unread: the
	# same file, in the same place, resolved by name. The criterion asks for
	# the file read for a benign setting; this is stronger, because it is the
	# very grant under test arriving the moment anything resolves the file.
	cat >"$scratch/probe-read.sh" <<-'PROBE'
		rc=0
		value=$(<"$1") || rc=$?
		printf 'READ :: %s :: %s\n' "$rc" "$value"
	PROBE
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		"$(pinned_bin nono)/nono" run \
		--profile "$agent" --workdir "$REPO_ROOT" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$scratch/probe-read.sh" "$hostile/target.txt" \
		>"$scratch/byname.out" 2>"$scratch/byname.err" && rc=0 || rc=$?
	granted_reach "$scratch/byname.err" >"$scratch/byname.set"

	if ! reach_grants "$scratch/byname.set" "$hostile" .; then
		found=1
		fail "$(printf 'the checkout'\''s own profile grants nothing even when it is the profile resolved (exit %s), so arm 1 refused a request nothing would have honoured:\n%s' \
			"$rc" "$(tail -n 5 "$scratch/byname.err")")"
	fi
	# The grant honoured, rather than nono's account of having honoured it.
	if ! grep -qFx "READ :: 0 :: $canary" "$scratch/byname.out"; then
		found=1
		fail "$(printf 'the file the checkout planted did not make the path outside the project readable when it was resolved (exit %s), so it is inert and arm 1 proves nothing:\n%s' \
			"$rc" "$(tail -n 3 "$scratch/byname.out")")"
	fi

	# Arm 3, the baseline: the same start with the checkout's files removed, so
	# "unchanged" is a difference measured rather than a shape recognised.
	rm -rf "$cfg/nono"
	mkdir -p "$cfg/nono"
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		"$entry_dir/$entry" --version \
		>"$scratch/clean.out" 2>"$scratch/clean.err" && rc=0 || rc=$?
	granted_reach "$scratch/clean.err" >"$scratch/clean.set"

	if ! reach_grants "$scratch/clean.set" "$REPO_ROOT" w; then
		found=1
		fail "$(printf 'the entry point started no session granting the project with an empty config root either (exit %s), so there is no baseline to compare against:\n%s' \
			"$rc" "$(tail -n 5 "$scratch/clean.err")")"
	elif ! diff -q "$scratch/clean.set" "$scratch/hostile.set" >/dev/null; then
		found=1
		fail "$(printf 'the granted reach differs between a clean checkout and one carrying its own agent configuration, so a file inside a project changes what a session may reach:\n%s' \
			"$(diff -- "$scratch/clean.set" "$scratch/hostile.set" || true)")"
	fi

	# Arm 4, FR-15: widening works from the invocation, and the widening is
	# exactly what was asked for. Same start, same clean config root, one
	# variable added, so the difference is attributable to the invocation.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		"NONO_ALLOW=$hostile" \
		"$entry_dir/$entry" --version \
		>"$scratch/allow.out" 2>"$scratch/allow.err" && rc=0 || rc=$?
	granted_reach "$scratch/allow.err" >"$scratch/allow.set"

	if ! reach_grants "$scratch/allow.set" "$hostile" w; then
		found=1
		fail "$(printf 'a widening supplied at the invocation did not reach the session (exit %s), so FR-15 has no route and the refusals above are the only behaviour there is:\n%s' \
			"$rc" "$(tail -n 5 "$scratch/allow.err")")"
	fi
	# And nothing else moved. A widening that also withdrew a grant, or added
	# a second one, would satisfy the assertion above.
	if [ -n "$(comm -23 "$scratch/clean.set" "$scratch/allow.set")" ]; then
		found=1
		fail "$(printf 'a widening at the invocation withdrew grants the session had without it:\n%s' \
			"$(comm -23 "$scratch/clean.set" "$scratch/allow.set")")"
	fi
	if [ "$(comm -13 "$scratch/clean.set" "$scratch/allow.set" | wc -l)" -ne 1 ]; then
		found=1
		fail "$(printf 'a widening naming one directory changed more than one grant, so what the invocation adds is not what it asks for:\n%s' \
			"$(comm -13 "$scratch/clean.set" "$scratch/allow.set")")"
	fi

	[ "$found" -eq 0 ]
}

# A claude-code skills-directory extension, which is what `claude plugin list`
# enumerates. The manifest is the part that makes one observable: a bare
# SKILL.md is invisible to that command, measured unconfined against a plant
# that had one and nothing else, so a check that planted only prose would watch
# an agent report nothing and call it confinement.
plant_extension() {
	local root=$1 name=$2
	mkdir -p "$root/$name/.claude-plugin"
	printf '{ "name": "%s", "version": "0.1.0", "description": "%s", "skills": ["./"] }\n' \
		"$name" "$name" >"$root/$name/.claude-plugin/plugin.json"
	printf -- '---\nname: %s\ndescription: planted by check_j8_2\n---\n\nNothing.\n' \
		"$name" >"$root/$name/SKILL.md"
}

# Is this extension reported as loaded? The name heads a stanza and the status
# is a later line of it, so the stanza is delimited first: a file-wide search
# for both strings would let one extension's status stand in for another's,
# which is exactly the confusion this check exists to avoid when several are
# planted at once.
extension_loaded() {
	local listing=$1 name=$2
	awk -v n="$name@skills-dir" '
		index($0, n) == 1 || index($0, " " n) { inside = 1; next }
		inside && /@skills-dir/ { inside = 0 }
		inside && /Status:/ { if (index($0, "loaded")) ok = 1; inside = 0 }
		END { exit !ok }
	' "$listing"
}

# Journey 8.2 — a home directory that already configures these agents for every
# project, and a consumer who declared nothing. That is the state every consumer
# starts in and the only state a stranger is ever in.
#
# Two observables, and the pair is the point. The reach comparison is the same
# set equality check_j1_1 makes, asserted under the one condition that makes it
# interesting: a home full of agent configuration, a host confinement
# description among it, so FR-21's "its confinement descriptions take no part in
# deciding a session's reach" is observed rather than assumed. The extension
# assertion is the other half, and D17 is why it cannot be dropped — an
# extension root read relative to $HOME needs no grant to be found, so "no grant
# was added" does not imply "no extension arrived", and the two have to be
# asserted separately.
#
# The subject is the built entry point rather than `nix develop -c`, because the
# question is what this repository's wrapper and description grant and not what
# a developer's shell happens to export. XDG_CONFIG_HOME is a scratch root for
# the same reason M5e used one: a real one carries nono packages of its own.
#
# FR-21's credentials, history and session state are planted and are covered by
# the reach comparison rather than by assertions of their own: no path under the
# fake home is granted, so no file under it is reachable, whatever it holds.
check_j8_2() {
	local agent=claude-code binary=claude
	local outside home state cfg hostroot projroot project registry substrate
	local entry hostext projext hostile session rc found=0
	local -a sessions=()

	entry=$(pinned_bin "$binary") || return 1
	session_fixture "$agent" || return 1

	# Outside the project, because 48 of the description's deny rules are
	# $HOME-relative and nono refuses to start when a granted path overlaps
	# one, and clean, because a stranger's home configures nothing yet — this
	# check puts back only what it wants to be found.
	outside=$(outside_root j8_2) || return 1
	home="$outside/home"
	state="$outside/state"
	cfg="$outside/config"
	hostroot="$home/.claude/skills"
	hostile="$home/reach"
	hostext="hostsurface-$RANDOM$RANDOM"
	projext="projectsurface-$RANDOM$RANDOM"
	# The project's own extension root is where the description points
	# CLAUDE_CONFIG_DIR, so the control is inside the project directory and
	# needs no grant beyond the one every session has. The project-scope
	# .claude/skills root cannot serve: every arm of the measurement reported
	# it scanned and not loaded, pending an interactive trust dialog.
	projroot="$REPO_ROOT/.agents/claude/skills"
	# shellcheck disable=SC2064
	trap "rm -rf '$outside' '$projroot/$projext'" RETURN
	mkdir -p "$hostroot" "$hostile" "$cfg" "$projroot"

	# The host-global configuration a consumer accumulates, all of it declared
	# to nobody: an authoring surface, a stored credential, conversation
	# history, session state, and a confinement description of nono's own that
	# grants a directory outside the project.
	plant_extension "$hostroot" "$hostext"
	plant_extension "$projroot" "$projext"
	printf 'HOST-CREDENTIAL-%s\n' "$RANDOM$RANDOM" >"$home/.claude/.credentials.json"
	printf '{"prompt":"a previous conversation"}\n' >"$home/.claude/history.jsonl"
	printf '{"projects":{}}\n' >"$home/.claude.json"
	printf 'reachable only by a session that took its description from here\n' \
		>"$hostile/target.txt"
	mkdir -p "$home/.config/nono/profiles"
	jq --arg d "$hostile" '.filesystem.read += [$d]' \
		"$FIXTURE_PROFILE" >"$home/.config/nono/profiles/$agent.json"

	session_env "$state"
	# `plugin list` rather than `--version`: it starts the agent, so FR-21's
	# "does not prevent one from working" is asserted by the same run that
	# enumerates what reached it, and it is the only instrument claude-code
	# has for the question — there is no `debug skill`, and `--print /skills`
	# answers that /skills is unavailable in this environment.
	(
		cd "$REPO_ROOT" && env "${SESSION_ENV[@]}" \
			"HOME=$home" "XDG_CONFIG_HOME=$cfg" \
			"$entry/$binary" plugin list
	) >"$outside/list.out" 2>"$outside/list.err" && rc=0 || rc=$?

	# FR-21's second half, and first, so nothing below is read from a session
	# that never ran.
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'a home directory full of host-global agent configuration stopped the agent working: exit %s\n%s' \
			"$rc" "$(tail -n 20 "$outside/list.err")")"
		return 1
	fi

	# The control (D9). An extension inside the project is reported by this
	# same session, so "none of the host ones arrived" cannot be satisfied by
	# an agent that reports nothing at all, or by one whose enumeration is
	# broken.
	#
	# It does not return early, unlike the exit status above it. A violation
	# that both grants the host root and stops redirecting the agent's config
	# root breaks the control and satisfies the assertion below at once, and
	# returning here would report the broken control and hide the extension
	# that arrived — which is the louder of the two findings.
	if ! extension_loaded "$outside/list.out" "$projext"; then
		found=1
		fail "$(printf 'the extension inside the project was not reported as loaded, so this session cannot say anything about the ones outside it:\n%s' \
			"$(cat "$outside/list.out")")"
	fi

	if extension_loaded "$outside/list.out" "$hostext"; then
		found=1
		fail "$(printf 'a host-global extension nobody declared reached the session:\n%s' \
			"$(cat "$outside/list.out")")"
	fi
	# There is deliberately no assertion here that the listing mentions no path
	# under the fake home. Under the plant, the extension that arrived was
	# reported as `Path: ~/.claude/skills/<name>`: the agent abbreviates the
	# home prefix, so such an assertion would have passed while an extension
	# was loading, and would have read as evidence. The name is the observable.

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

	# The set equality, unchanged from check_j1_1's and derived from the same
	# artefacts, because "the granted reach is unchanged" is a claim about this
	# set and not about this fixture. Every term comes out of what the
	# repository builds, so a declaration moves both sides and only reach
	# nobody declared can fail it.
	if ! diff -u \
		<({
			printf '%s\n' "$project"
			cat "$FIXTURE_SUBSTRATE/store-paths"
			jq -r '.[].path' <<<"$registry"
		} | sort -u) \
		<(jq -r '.tracked_paths[]' "${sessions[0]}" | sort -u) \
		>"$outside/reach.diff" 2>&1; then
		found=1
		fail "$(printf 'a home directory full of host-global agent configuration changed the granted reach:\n%s' \
			"$(sed '1,2d' "$outside/reach.diff")")"
	fi

	# Named separately from the comparison above, because this is the one the
	# scenario is about: a confinement description outside the boundary taking
	# part in deciding the boundary. The comparison would catch it, and would
	# report it as a diff hunk among 130 store paths.
	if jq -r '.tracked_paths[]' "${sessions[0]}" | grep -qF "$home"; then
		found=1
		fail "$(printf 'the session was granted a path under the host home directory, so configuration outside the boundary decided the boundary:\n%s' \
			"$(jq -r '.tracked_paths[]' "${sessions[0]}" | grep -F "$home")")"
	fi

	[ "$found" -eq 0 ]
}

# R10 / FR-23 / D11 — a host tool configuration does not direct the session.
#
# The counterpart to check_j8_2 and the harder case, because this one was
# observed rather than reasoned about: a live session read
# `credential.helper = cache` out of the host `~/.gitconfig` and tried to start
# a daemon. It failed only because that session's working directory happened to
# be read-only at the time.
#
# So the danger is not the file being readable, it is the directives in it. A
# read-only grant is no protection against `core.hooksPath`, and neither is
# denying the path: withhold the grant alone and the outcome depends on what the
# host happens to contain, and the session has no commit identity either. The
# toolchain is *directed* at configuration this environment wrote (D11), and
# this check is what says the direction holds.
#
# The subject is the real entry point, run twice, plus one session driving the
# toolchain itself:
#
#   1. `claude --version` in a scratch project, which is what must write the
#      identity file. It has to be the entry point rather than the shell hook,
#      because a stranger reaching an agent by `nix run <ref>#claude` never runs
#      the hook, and the file has to exist before the session starts.
#   2. A session running `git` out of the substrate, which reports the effective
#      configuration and then commits.
#   3. `claude --version` again, over an identity file the check has replaced
#      with one of its own, which is FR-23's override and M9b's idempotency
#      asserted as one statement: an existing file is never rewritten.
#
# The planted host configuration carries five directives, and `core.hooksPath`
# names a hook **inside the scratch project** on purpose. A hook script in the
# fake home would be unreadable from inside the session, so a directive that had
# crossed would fail to run for a reason that has nothing to do with the
# directive — and the check would pass while the boundary leaked. Everything the
# directive needs in order to run is reachable; the only thing outside the
# project is the file the directive came from.
check_r10() {
	local agent=claude-code binary=claude
	local entry outside home proj ctrl cfg gitdir git probe hook
	local canary want_name want_email got rc arm
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV
	local found=0

	entry=$(pinned_bin "$binary")
	session_fixture "$agent" || return 1
	gitdir=$(substrate_member "$FIXTURE_SUBSTRATE" git) || {
		fail "the substrate for $agent provides no git, so there is no toolchain to observe"
		return 1
	}
	git="$gitdir/bin/git"

	outside=$(outside_root r10) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	# The scratch project is a sibling of the fake home rather than a directory
	# inside it: the description carries 48 $HOME-relative deny rules, and a
	# workdir underneath the home they are relative to makes nono refuse to
	# start on the overlap.
	home="$outside/home"
	proj="$outside/proj"
	ctrl="$outside/ctrl"
	cfg="$outside/cfg"
	mkdir -p "$home" "$proj/hooks" "$ctrl/hooks" "$cfg"

	canary="HOOK-RAN-$RANDOM$RANDOM"
	# The interpreter is the substrate's own bash, and the marker is written
	# relative to the hook's working directory, which git sets to the top of the
	# worktree. Neither detail is cosmetic: a `#!/bin/sh` hook would fail to
	# exec inside a session that is granted the store and not `/bin`, and a
	# `git rev-parse` would resolve a program off the inherited PATH. Either
	# would make a directive that had crossed fail for its own reasons, and this
	# check would pass while the boundary leaked.
	for hook in "$proj" "$ctrl"; do
		printf '#!%s/bin/bash\nprintf "%%s\\n" %s >./hook-ran\n' \
			"$FIXTURE_BASH" "$canary" >"$hook/hooks/pre-commit"
		chmod +x "$hook/hooks/pre-commit"
	done

	# The host configuration a consumer's machine actually carries, with the
	# directive that was observed crossing among it. `commit.gpgsign` is here
	# because it is next to the two keys FR-23 does copy, and a copy that took
	# the whole file would bring it along and make every commit demand a key the
	# session cannot reach (FR-24).
	want_name="Host Person $RANDOM"
	want_email="host-$RANDOM@example.invalid"
	{
		printf '[user]\n\tname = %s\n\temail = %s\n' "$want_name" "$want_email"
		printf '[credential]\n\thelper = cache --timeout=99999\n'
		printf '[core]\n\thooksPath = %s\n' "$proj/hooks"
		printf '[commit]\n\tgpgsign = true\n'
		printf '[alias]\n\tcanary = !echo %s\n' "$canary"
	} >"$home/.gitconfig"
	# The second location git searches for a global file, so a check that only
	# suppressed the first would still pass with this one live.
	mkdir -p "$home/.config/git"
	printf '[core]\n\thooksPath = %s\n' "$proj/hooks" >"$home/.config/git/config"

	session_env "$outside/state"

	# Control 1, and it comes first because every assertion below is about an
	# absence. Unconfined, with the same home and the same repository, the
	# planted directive runs: the hook fires and leaves its canary. A hook that
	# could never have run would make the confined arm's silence meaningless.
	(
		cd "$ctrl" || exit 1
		env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM "HOME=$home" \
			"$git" init -q . &&
			env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM "HOME=$home" \
				"$git" commit -q --allow-empty -m control --no-gpg-sign
	) >"$outside/control.log" 2>&1
	if [ "$(cat "$ctrl/hook-ran" 2>/dev/null)" != "$canary" ]; then
		fail "$(printf 'the planted host directive does not run even outside the boundary, so its absence inside proves nothing:\n%s' \
			"$(cat "$outside/control.log")")"
		return 1
	fi

	# Session 1. The entry point, which is what must write the identity file.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "$proj" "$entry/$binary" --version \
		>"$outside/entry1.out" 2>"$outside/entry1.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the entry point does not start in a scratch project (exit %s):\n%s' \
			"$rc" "$(tail -20 "$outside/entry1.err")")"
		return 1
	fi

	# FR-23, first half: the file exists, and it holds the host's author
	# identity and nothing else out of that file.
	if [ ! -f "$proj/.agents/git/config" ]; then
		fail "the toolchain is directed at a configuration file this environment never wrote, so the session has no commit identity and the outcome depends on what the host contains"
		return 1
	fi
	got=$("$git" config --file "$proj/.agents/git/config" --list | sort)
	if [ "$got" != "$(printf 'user.email=%s\nuser.name=%s' "$want_email" "$want_name")" ]; then
		found=1
		fail "$(printf 'the configuration this environment wrote is not the host author identity and only that:\n%s' "$got")"
	fi

	# Session 2. The toolchain, inside the boundary, reporting on itself and
	# then committing. Written to the project because the project is what the
	# host can read afterwards.
	probe="$proj/probe.sh"
	cat >"$probe" <<-'PROBE'
		git=$1
		work=$2
		printf 'GLOBAL_VAR :: %s\n' "${GIT_CONFIG_GLOBAL-<unset>}"
		printf 'SYSTEM_VAR :: %s\n' "${GIT_CONFIG_SYSTEM-<unset>}"
		"$git" config --list --show-origin --show-scope >"$work/effective.txt" 2>&1
		printf 'LIST_RC :: %s\n' "$?"
		"$git" config --list --system >"$work/system.txt" 2>&1
		printf 'SYSTEM_RC :: %s\n' "$?"
		cd "$work" || exit 1
		"$git" init -q . >>"$work/git.log" 2>&1
		printf 'INIT_RC :: %s\n' "$?"
		"$git" commit -q --allow-empty -m r10 >>"$work/git.log" 2>&1
		printf 'COMMIT_RC :: %s\n' "$?"
	PROBE

	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$probe" "$git" "$proj" \
		>"$outside/probe.out" 2>"$outside/probe.err" && rc=0 || rc=$?

	if ! grep -qF 'LIST_RC :: 0' "$outside/probe.out"; then
		fail "$(printf 'the toolchain cannot report its own configuration inside the session (exit %s):\n%s\n%s' \
			"$rc" "$(cat "$outside/probe.out")" "$(tail -20 "$outside/probe.err")")"
		return 1
	fi

	# Control 2. A setting this environment wrote is read back from the
	# effective configuration, so a toolchain that had read no configuration at
	# all could not pass. It accumulates rather than returning, so a violation
	# that both breaks this and lets a host directive through reports both.
	# `--show-scope --show-origin` prefixes each line with two tab-separated
	# fields, so the setting itself is what is left once both are stripped.
	if ! grep -qxF "user.name=$want_name" \
		<(sed 's/^[^\t]*\t[^\t]*\t//' "$proj/effective.txt"); then
		found=1
		fail "$(printf 'the effective configuration does not carry the setting this environment wrote:\n%s' \
			"$(cat "$proj/effective.txt")")"
	fi

	# The scenario's first Then, as a property over origins rather than a list
	# of the files this environment happens to know about. Every file the
	# toolchain read is under the project directory, so a scope this check never
	# heard of fails it too.
	while IFS= read -r origin; do
		case $origin in
		"$proj"/*) ;;
		*)
			found=1
			fail "$(printf 'the toolchain read a configuration file outside the project directory: %s' "$origin")"
			;;
		esac
	done < <(sed -n 's/^[a-z]*\tfile:\([^\t]*\)\t.*/\1/p' "$proj/effective.txt" | sort -u)

	# The scenario's second Then. Each directive named, because each is a
	# different way in: one starts a daemon, one runs a program at commit time,
	# one runs a program on a subcommand, one demands a key the session cannot
	# reach.
	#
	# Matched case-insensitively, and that is not fastidiousness: git lowercases
	# section and key names in its own listing, so the planted `core.hooksPath`
	# reads back as `core.hookspath`. The first draft searched for the name as
	# written and reported nothing while the plant's hook was demonstrably
	# running — the one assertion of the six that could not have failed.
	for arm in credential.helper core.hooksPath commit.gpgsign alias.canary; do
		if grep -qiF "$arm=" "$proj/effective.txt"; then
			found=1
			fail "$(printf 'the host directive %s is in the effective configuration inside the session:\n%s' \
				"$arm" "$(grep -iF "$arm=" "$proj/effective.txt")")"
		fi
	done
	if grep -qF "$canary" "$proj/effective.txt"; then
		found=1
		fail "the host configuration's canary appears in the effective configuration"
	fi

	# D11's second variable, and the reason it is not redundant on a host with
	# no system file: git's compiled-in system path is /etc/gitconfig whether or
	# not it exists, so a session with the variable dropped goes looking. The
	# assertion is that the scope resolves and contributes nothing — which fails
	# by an error on a host without the file, and by content on one with it.
	if ! grep -qF 'SYSTEM_RC :: 0' "$outside/probe.out" ||
		[ -s "$proj/system.txt" ]; then
		found=1
		fail "$(printf 'the system scope does not resolve to nothing inside the session:\n%s\n%s' \
			"$(grep -F 'SYSTEM_RC' "$outside/probe.out")" "$(cat "$proj/system.txt")")"
	fi
	if ! grep -qF "GLOBAL_VAR :: $proj/.agents/git/config" "$outside/probe.out" ||
		! grep -qF 'SYSTEM_VAR :: /dev/null' "$outside/probe.out"; then
		found=1
		fail "$(printf 'the toolchain is not directed where D11 says it is:\n%s' \
			"$(grep -F '_VAR ::' "$outside/probe.out")")"
	fi

	# The second arm: no process started, and nothing written outside the
	# project. The hook is asserted from the host rather than from the session,
	# and the commit is asserted to have succeeded, because a commit that failed
	# would leave no marker either.
	if ! grep -qF 'COMMIT_RC :: 0' "$outside/probe.out"; then
		found=1
		fail "$(printf 'the session cannot commit, so a hook that never ran cannot be told from a commit that never happened:\n%s\n%s' \
			"$(cat "$outside/probe.out")" "$(cat "$proj/git.log" 2>/dev/null)")"
	fi
	if [ -e "$proj/hook-ran" ]; then
		found=1
		fail "$(printf 'a program named by the host configuration ran inside the session, leaving %s' \
			"$(cat "$proj/hook-ran")")"
	fi

	# Session 3. FR-23's override and M9b's idempotency are the same statement:
	# an existing file is never rewritten, so a consumer who edits it keeps
	# their own values however many times an agent starts.
	"$git" config --file "$proj/.agents/git/config" user.name "Consumer $canary"
	"$git" config --file "$proj/.agents/git/config" user.email "consumer@example.invalid"
	cp "$proj/.agents/git/config" "$outside/override.expected"
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "$proj" "$entry/$binary" --version \
		>"$outside/entry2.out" 2>"$outside/entry2.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		found=1
		fail "$(printf 'the entry point does not start a second time in the same project (exit %s):\n%s' \
			"$rc" "$(tail -20 "$outside/entry2.err")")"
	elif ! diff -q "$outside/override.expected" "$proj/.agents/git/config" >/dev/null; then
		found=1
		fail "$(printf 'the consumer own author identity was overwritten by a second start:\n%s' \
			"$(diff -u "$outside/override.expected" "$proj/.agents/git/config" | sed '1,2d')")"
	fi

	[ "$found" -eq 0 ]
}

# Journey 2.1 — agent state lands in the project, and the home directory is
# left as it was found.
#
# Two sessions, because the scenario has two halves that no single observable
# covers.
#
# The first is the agent itself, so the state under test is state the agent
# chose to write rather than state a probe was told to write. `plugin list`
# writes its configuration file and a backup of it and needs no credentials,
# which M6a measured; driving a conversation to get a write would add a
# credential dependency to a check about the filesystem. It is joined by a
# subagent listing and a background spawn, because spec Risk 12 names the
# subagent and lock paths as the ones that resolve the configuration root a
# second time, and a one-turn session never reaches them.
#
# The second is a probe, because the first cannot answer criteria 3 and 4. An
# agent that writes nowhere near a relocated root leaves that root unobserved,
# and M6a measured every one of them arriving `<unset>` in a session: the
# devShell's redirection does not cross the boundary at all, because allow_vars
# carries no XDG_* pattern. So each root the description names is read back from
# inside the session and written to, one line per root, and the names come out
# of the built description rather than being listed here — adding a root moves
# the expected set with it.
#
# Control (D9), and first: the agent's own writes are found under the project.
# "nothing landed in $HOME" is satisfied just as well by a session that wrote
# nothing anywhere, or by one that never started, and both are what a broken
# check looks like.
check_j2_1() {
	local agent=claude-code binary=claude
	local entry outside home proj cfg state probe project registry rc
	local root want got write entry_path covered found=0
	# TEMPORARY (M9d iteration 3).
	local watcher before_t after_t
	local -a landed=() roots=() changed=() spawned=()

	session_fixture "$agent" || return 1
	entry=$(pinned_bin "$binary") || return 1

	# The fake home is outside the project and the project is its sibling, never
	# beneath it: the description carries 48 $HOME-relative deny rules, and a
	# granted directory under the home is unenforceable.
	outside=$(outside_root j2_1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	home="$outside/home"
	proj="$outside/proj"
	cfg="$outside/cfg"
	state="$outside/state"
	mkdir -p "$home" "$proj" "$cfg"
	session_env "$state"
	project=$(cd "$proj" && pwd -P)

	# The home directory already carries this agent's state, because that is the
	# machine the scenario is about — a consumer who has run the agent before —
	# and because an empty home cannot falsify anything. With nothing there, the
	# agent's own fallback location does not exist, so a session that lost its
	# relocation writes nowhere and the diff below stays empty for the wrong
	# reason. Measured: the first draft used an empty home and its diff arm
	# could not be made to fail by any plant.
	mkdir -p "$home/.claude"
	printf '{"installMethod":"prior"}\n' >"$home/.claude.json"

	# Size and modification time alongside the path, so a file the session
	# rewrites in place counts as a change rather than passing as unchanged.
	# Every path, not only files, so a directory the session creates and leaves
	# empty counts too.
	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/before"

	# TEMPORARY (M9d iteration 3). Started before the first session, stopped
	# before the comparison below. The trap is replaced rather than added to,
	# so a check that returns early on one of the arms above still takes the
	# poller with it.
	watcher=$(dbg_watch_start "$home" "$outside/seen")
	# shellcheck disable=SC2064
	trap "{ kill $watcher; } 2>/dev/null; rm -rf '$outside'" RETURN

	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "$proj" "$entry/$binary" plugin list \
		>"$outside/agent.out" 2>"$outside/agent.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the agent did not start in the scratch project (exit %s):\n%s' \
			"$rc" "$(tail -20 "$outside/agent.err")")"
		return 1
	fi

	# The subagent path, which spec Risk 12 names and a one-turn session never
	# reaches. `plugin list` above resolves the configuration root once; a
	# background agent resolves it again from a spawned process, and M8b found
	# the spawn carrying `CLAUDE_CONFIG_DIR` forward through
	# `CLAUDE_CODE_SESSION_KIND=bg` while a second expression in the same binary
	# falls back to `$HOME/.claude` whenever that variable is absent.
	#
	# Listing first, because it is the half that must succeed: it is
	# credential-free and needs no terminal, both measured, so a non-zero exit
	# here is the environment breaking the agent rather than the agent declining
	# to run.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "$proj" "$entry/$binary" agents --json --all \
		>"$outside/agents.out" 2>"$outside/agents.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		found=1
		fail "$(printf 'the agent could not list its subagent sessions inside the session (exit %s):\n%s' \
			"$rc" "$(tail -20 "$outside/agents.err")")"
	# The answer is taken from the first line that opens an array rather than
	# from the whole capture, because the supervisor's own credential warning
	# shares the stream — measured, and it is the supervisor talking, not the
	# agent, so treating it as part of the answer would fail a working session.
	elif ! sed -n '/^\[/,$p' "$outside/agents.out" |
		jq -e 'type == "array"' >/dev/null 2>&1; then
		found=1
		fail "$(printf 'the subagent listing did not answer with a session array, so the path was not exercised:\n%s' \
			"$(head -5 "$outside/agents.out")")"
	fi

	# Then the spawn itself. Its exit status is deliberately not asserted: the
	# background service binds an AF_UNIX socket under a hardcoded /tmp path
	# that no description here grants, so today it is refused, and pinning
	# either outcome would make this check fail the day that changes. What is
	# asserted is the part the scenario owns — that reaching for a background
	# agent writes where this environment put the root and nowhere else, which
	# the $HOME diff below covers, and that the spawn path was reached at all,
	# which the daemon's own files under the project prove.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "$proj" "$entry/$binary" --bg 'list the files here' \
		>"$outside/bg.out" 2>"$outside/bg.err" </dev/null || true

	mapfile -t spawned < <(find "$project/.agents/claude" -maxdepth 1 -name 'daemon*' 2>/dev/null | sort)
	if [ "${#spawned[@]}" -eq 0 ]; then
		found=1
		fail "$(printf 'asking for a background agent left no trace under the relocated root, so the subagent path was never entered:\n%s' \
			"$(tail -10 "$outside/bg.err")")"
	fi

	# The control. It accumulates rather than returning, because the violation
	# this scenario is written against breaks the control and the subject at
	# once: a state root dropped and its host fallback granted leaves nothing in
	# the project *and* changes the home directory. A hard return here reported
	# the control alone and left the louder half — the non-empty $HOME diff the
	# criterion names — unobserved. Measured, not reasoned: the first draft
	# returned, and the plant fired one message instead of two.
	mapfile -t landed < <(find "$project/.agents" -type f 2>/dev/null | sort)
	if [ "${#landed[@]}" -eq 0 ]; then
		found=1
		fail "the session wrote no state inside the project, so an empty home directory would prove nothing"
	fi

	# The scenario. The registry is subtracted rather than assumed empty, so an
	# entry added later relaxes this comparison by exactly what it declares and
	# by nothing else. $HOME is expanded because an entry names the variable
	# while the diff carries the resolved path.
	# TEMPORARY (M9d iteration 3).
	dbg_watch_stop "j2_1 home" "$watcher" "$outside/seen" "$home"

	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/after"
	registry=$(nix eval --json "$REPO_ROOT#leakRegistry" \
		--apply "es: builtins.filter (e: builtins.elem \"$agent\" e.agents) es" |
		jq -r '.[].path' | sed "s|\$HOME|$home|g")
	while IFS=$'\t' read -r root _; do
		[ -n "$root" ] || continue
		covered=0
		while IFS= read -r entry_path; do
			[ -n "$entry_path" ] || continue
			case "$root" in
			"$entry_path" | "$entry_path"/*) covered=1 ;;
			esac
		done <<<"$registry"
		if [ "$covered" -eq 0 ]; then
			changed+=("$root")
		fi
	done < <(comm -13 "$outside/before" "$outside/after")

	if [ "${#changed[@]}" -ne 0 ]; then
		found=1
		# TEMPORARY (M9d iteration 2). The comparison carries path, size and
		# modification time, and reports the path alone, so a directory whose
		# own line moved because a registry-covered child was created under it
		# is indistinguishable from a write the registry does not cover. The
		# differing lines verbatim say which of the three fields moved.
		while IFS= read -r line; do
			dbg "j2_1 home diff: $line"
		done < <(diff "$outside/before" "$outside/after")
		while IFS= read -r line; do
			dbg "j2_1 registry entry: $line"
		done <<<"$registry"
		while IFS= read -r line; do
			dbg "j2_1 home now: $line"
		done < <(find "$home" -maxdepth 1 -printf '%y\t%p\t%s\t%T@\n' | sort)

		# TEMPORARY (M9d iteration 3). The hypothesis, put to the run rather
		# than reasoned about: lib/preflight.sh writes its positive-control
		# canary to `${XDG_RUNTIME_DIR:-$HOME}`, and every agent entry point
		# runs that pre-flight. Where XDG_RUNTIME_DIR is unset — the macOS
		# runner, not the Linux one — the canary is created and removed inside
		# this fabricated home, which moves the directory's own modification
		# time and returns its size to where it started. So the same session is
		# run once more with that variable pointing somewhere else: a home
		# whose time stops moving confirms the canary, and one that moves
		# anyway refutes it.
		dbg "j2_1 XDG_RUNTIME_DIR as the check saw it: ${XDG_RUNTIME_DIR:-<unset>}"
		mkdir -p "$outside/run"
		before_t=$(find "$home" -maxdepth 0 -printf '%s\t%T@\n')
		env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
			"XDG_RUNTIME_DIR=$outside/run" \
			env -C "$proj" "$entry/$binary" plugin list \
			>"$outside/rerun.out" 2>"$outside/rerun.err" || true
		after_t=$(find "$home" -maxdepth 0 -printf '%s\t%T@\n')
		dbg "j2_1 with XDG_RUNTIME_DIR set: $before_t -> $after_t"
		dbg "j2_1 with XDG_RUNTIME_DIR set: it now holds: $(find "$outside/run" -mindepth 1 -printf '%f ')"

		fail "$(printf 'the session changed the home directory outside the leak registry:\n%s' \
			"$(printf '%s\n' "${changed[@]}")")"
	fi

	# Criterion 3. The roots come out of the description, so this cannot go stale
	# against it, and the anti-vacuity guard is the point: a description that
	# named no root at all would otherwise pass this arm in silence.
	mapfile -t roots < <(jq -r '.environment.set_vars | keys[] | select(test("^XDG_|^TMPDIR$"))' \
		"$FIXTURE_PROFILE" | sort)
	if [ "${#roots[@]}" -eq 0 ]; then
		fail "the description names no environment-resolved root, so there is nothing for a session to relocate"
		return 1
	fi

	# Written inside the project on purpose: M5h measured that exec'ing a file
	# outside the granted workdir gives exit 126 with no output, which is
	# indistinguishable from the boundary working.
	probe="$proj/probe-roots.sh"
	cat >"$probe" <<-'PROBE'
		for name in "$@"; do
			value=${!name:-<unset>}
			if [ "$value" = "<unset>" ]; then
				printf 'ROOT :: %s :: <unset> :: unset\n' "$name"
				continue
			fi
			if mkdir -p "$value/probe" 2>/dev/null; then
				printf 'ROOT :: %s :: %s :: ok\n' "$name" "$value"
			else
				printf 'ROOT :: %s :: %s :: denied\n' "$name" "$value"
			fi
		done
	PROBE

	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" \
		--workdir "$proj" \
		--allow-cwd \
		-- "$FIXTURE_BASH/bin/bash" "$probe" "${roots[@]}" \
		>"$outside/roots.out" 2>"$outside/roots.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the root probe did not run (exit %s):\n%s' \
			"$rc" "$(tail -20 "$outside/roots.err")")"
		return 1
	fi

	# Each root is asserted twice: the child resolved the value the description
	# gave it, and that value is writable. The first without the second is a
	# variable pointing somewhere the session cannot use, which is what an
	# ancestor grant would hide and what M6a measured every $HOME-relative
	# fallback doing.
	for root in "${roots[@]}"; do
		want=$(jq -r --arg k "$root" '.environment.set_vars[$k]' "$FIXTURE_PROFILE" |
			sed "s|\$WORKDIR|$project|g")
		got=$(sed -n "s/^ROOT :: $root :: \(.*\) :: .*$/\1/p" "$outside/roots.out")
		write=$(sed -n "s/^ROOT :: $root :: .* :: \(.*\)$/\1/p" "$outside/roots.out")
		if [ "$got" != "$want" ]; then
			found=1
			fail "$(printf 'the session resolved %s to %s, not to the %s the description names' \
				"$root" "${got:-<absent from the probe>}" "$want")"
		elif [ "$write" != ok ]; then
			found=1
			fail "$(printf 'the session cannot write to the %s it was pointed at: %s :: %s' \
				"$root" "$want" "$write")"
		fi
	done

	# Criterion 4, by observation. The supervisor resolves its own protected
	# state root from the ambient value before the child's environment applies,
	# so moving the child does not make the project ungrantable. Asserting that
	# the two resolutions are independent means finding the supervisor's record
	# under the ambient root and finding none under the child's — the plan calls
	# this D13's load-bearing assumption and says to observe it rather than
	# assume it.
	if [ -z "$(find "$state/nono/audit" -mindepth 2 -maxdepth 2 -name session.json 2>/dev/null)" ]; then
		found=1
		fail "the supervisor kept no session record under the ambient state root, so nothing says the two resolutions are independent"
	fi
	if [ -n "$(find "$project/.agents/state" -name session.json 2>/dev/null)" ]; then
		found=1
		fail "the supervisor's own state followed the child's redirection into the project, which is the overlap that makes the project ungrantable"
	fi

	[ "$found" -eq 0 ]
}

# Journey 3.1 — two projects at once share nothing, which is FR-8.
#
# The two sessions are started with & and joined with wait, because the risk
# this scenario is written against is contention: every supervised session
# writes beneath one shared supervisory state directory, and a sequential pair
# would never touch it at the same time. One fake $HOME, one config root and
# one ambient XDG_STATE_HOME are shared between them on purpose — that is the
# arrangement a consumer with two checkouts is actually in.
#
# Two rounds, because FR-8's two halves have no single observable. The agent
# answers "share no agent state": it writes state of its own accord, so where
# that lands is not something the check chose. It cannot answer "must not reach
# each other's project directory", because an agent handed a grant it has no
# use for does not exercise it — measured on M6a's plant A, where a granted
# host path changed the reach set while the agent's own writes stayed put. So a
# probe pair attempts the cross-project write the agent never would.
#
# The projects are siblings under a directory of their own rather than under
# the temporary root, so the plant this check exists for — granting the parent
# of the working directory, which is what a mistaken workspace-wide grant looks
# like — reaches the other project and nothing else. With the fake home beside
# them, that same grant would cover it and nono would refuse to start on
# deny-overlap, and the plant would prove nothing.
check_j3_1() {
	local agent=claude-code binary=claude
	local entry outside work home cfg state probe registry rc_a rc_b
	local name other root canary_a canary_b entry_path covered record seen found=0
	# TEMPORARY (M9d iteration 3).
	local watcher before_t after_t
	local -a landed=() changed=() records=() reached=()
	local -A projects=()

	session_fixture "$agent" || return 1
	entry=$(pinned_bin "$binary") || return 1

	outside=$(outside_root j3_1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	work="$outside/work"
	home="$outside/home"
	cfg="$outside/cfg"
	state="$outside/state"
	mkdir -p "$work/alpha" "$work/beta" "$home" "$cfg"
	session_env "$state"
	projects[alpha]=$(cd "$work/alpha" && pwd -P)
	projects[beta]=$(cd "$work/beta" && pwd -P)

	# Two checkouts, because that is the Given, and because the agent walks up
	# to the worktree root when it looks for project-scoped extensions: two
	# directories that were not repositories would share whatever ancestor the
	# walk found instead.
	for name in alpha beta; do
		git init -q "${projects[$name]}" >/dev/null 2>&1 || {
			fail "cannot make ${projects[$name]} a checkout, so the scenario's Given does not hold"
			return 1
		}
		find "${projects[$name]}" -printf '%p\t%s\t%T@\n' | sort >"$outside/before.$name"
	done
	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/home.before"

	# TEMPORARY (M9d iteration 3), for check_j2_1's reason.
	watcher=$(dbg_watch_start "$home" "$outside/seen")
	# shellcheck disable=SC2064
	trap "{ kill $watcher; } 2>/dev/null; rm -rf '$outside'" RETURN

	# Genuinely concurrent, per the RED. Each status is collected separately so
	# a pair where only one session survived cannot read as a pair that did not
	# interfere.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "${projects[alpha]}" "$entry/$binary" plugin list \
		>"$outside/alpha.out" 2>"$outside/alpha.err" &
	local pid_a=$!
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "${projects[beta]}" "$entry/$binary" plugin list \
		>"$outside/beta.out" 2>"$outside/beta.err" &
	local pid_b=$!
	wait "$pid_a" && rc_a=0 || rc_a=$?
	wait "$pid_b" && rc_b=0 || rc_b=$?

	if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ]; then
		fail "$(printf 'a concurrent session did not run: alpha exit %s, beta exit %s\n%s\n%s' \
			"$rc_a" "$rc_b" "$(tail -10 "$outside/alpha.err")" "$(tail -10 "$outside/beta.err")")"
		return 1
	fi

	# The control (D9), and it accumulates rather than returning: two sessions
	# that each wrote nothing leave every project unchanged and would satisfy
	# both halves below without either boundary having done anything.
	for name in alpha beta; do
		mapfile -t landed < <(find "${projects[$name]}/.agents" -type f 2>/dev/null | sort)
		if [ "${#landed[@]}" -eq 0 ]; then
			found=1
			fail "$(printf 'the %s session wrote no state inside its own checkout, so an unchanged sibling proves nothing' "$name")"
		fi
	done

	# Share no agent state. The two sessions had one home directory between
	# them, so state that was not project-scoped would have collided there.
	# The registry is subtracted rather than assumed empty, exactly as
	# check_j2_1 does, so an entry added later relaxes this by what it declares.
	# TEMPORARY (M9d iteration 3).
	dbg_watch_stop "j3_1 home" "$watcher" "$outside/seen" "$home"

	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/home.after"
	registry=$(nix eval --json "$REPO_ROOT#leakRegistry" \
		--apply "es: builtins.filter (e: builtins.elem \"$agent\" e.agents) es" |
		jq -r '.[].path' | sed "s|\$HOME|$home|g")
	changed=()
	while IFS=$'\t' read -r root _; do
		[ -n "$root" ] || continue
		covered=0
		while IFS= read -r entry_path; do
			[ -n "$entry_path" ] || continue
			case "$root" in
			"$entry_path" | "$entry_path"/*) covered=1 ;;
			esac
		done <<<"$registry"
		if [ "$covered" -eq 0 ]; then
			changed+=("$root")
		fi
	done < <(comm -13 "$outside/home.before" "$outside/home.after")
	if [ "${#changed[@]}" -ne 0 ]; then
		found=1
		# TEMPORARY (M9d iteration 2), for check_j2_1's reason.
		while IFS= read -r line; do
			dbg "j3_1 home diff: $line"
		done < <(diff "$outside/home.before" "$outside/home.after")
		while IFS= read -r line; do
			dbg "j3_1 home now: $line"
		done < <(find "$home" -maxdepth 1 -printf '%y\t%p\t%s\t%T@\n' | sort)

		# TEMPORARY (M9d iteration 3), for check_j2_1's reason: the pre-flight
		# canary put to the run. One session, not the pair, because the
		# question is where the canary lands and not whether two collide.
		dbg "j3_1 XDG_RUNTIME_DIR as the check saw it: ${XDG_RUNTIME_DIR:-<unset>}"
		mkdir -p "$outside/run"
		before_t=$(find "$home" -maxdepth 0 -printf '%s\t%T@\n')
		env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
			"XDG_RUNTIME_DIR=$outside/run" \
			env -C "${projects[alpha]}" "$entry/$binary" plugin list \
			>"$outside/rerun.out" 2>"$outside/rerun.err" || true
		after_t=$(find "$home" -maxdepth 0 -printf '%s\t%T@\n')
		dbg "j3_1 with XDG_RUNTIME_DIR set: $before_t -> $after_t"

		fail "$(printf 'two concurrent sessions shared state in the home directory, outside the leak registry:\n%s' \
			"$(printf '%s\n' "${changed[@]}")")"
	fi

	# Neither reach includes the other. Selection is by the agent's own command
	# and not by a project path, because a record carries no working directory
	# and the grant this check exists to catch is an ancestor of both projects:
	# selecting "the record naming alpha" then finds none, or finds both, and
	# the check falls over on its own bookkeeping before reaching its subject.
	# That is measured, not foreseen — the first plant did exactly this.
	#
	# Each session leaves three records, the pre-flight's enforceability probe
	# and its companion alongside the agent's own, so the agent's two are the
	# ones whose command is the agent. This runs before the probes, because a
	# probe session leaves a record of its own and there would then be four.
	records=()
	while IFS= read -r entry_path; do
		if jq -e --arg b "/bin/$binary" '.command[0] | endswith($b)' \
			"$entry_path" >/dev/null 2>&1; then
			records+=("$entry_path")
		fi
	done < <(find "$state/nono/audit" -mindepth 2 -maxdepth 2 -name session.json)
	if [ "${#records[@]}" -ne 2 ]; then
		fail "$(printf 'expected one session record per concurrent agent session, found %s' \
			"${#records[@]}")"
		return 1
	fi

	# A reach that contains a checkout is as bad as one that names it, so an
	# ancestor counts as reaching it. The property is stated over the pair
	# rather than per session — two records, each reaching exactly one of the
	# two checkouts and between them both — because a record cannot be
	# attributed to a session by any field it carries, and two sessions whose
	# reach is indistinguishable is itself the failure.
	seen=
	for record in "${records[@]}"; do
		reached=()
		for name in alpha beta; do
			if jq -e --arg p "${projects[$name]}" \
				'any(.tracked_paths[]; . as $t | $t == $p or ($t | startswith($p + "/")) or ($p | startswith($t + "/")))' \
				"$record" >/dev/null 2>&1; then
				reached+=("$name")
			fi
		done
		if [ "${#reached[@]}" -ne 1 ]; then
			found=1
			fail "$(printf 'a concurrent session reaches %s of the two checkouts (%s), not just its own: %s' \
				"${#reached[@]}" "${reached[*]:-none}" \
				"$(jq -r '[.tracked_paths[] | select(startswith("/nix/store") | not)] | join(" ")' "$record")")"
			continue
		fi
		case " $seen " in
		*" ${reached[0]} "*)
			found=1
			fail "$(printf 'both concurrent sessions reach the %s checkout and only it, so one of them reached the wrong project' \
				"${reached[0]}")"
			;;
		esac
		seen="$seen ${reached[0]}"
	done

	# The other project directory is unchanged. The agent cannot demonstrate
	# this: it has no reason to write next door even when it may. So each
	# session tries, concurrently, and the refusal is asserted from the host
	# after both have exited — a denial reported from inside the sandbox is the
	# sandbox's own account of itself, and M5b measured nono's summary claiming
	# no denials for a write it had just refused.
	canary_a="CROSS-CANARY-$RANDOM$RANDOM"
	canary_b="CROSS-CANARY-$RANDOM$RANDOM"
	for name in alpha beta; do
		probe="${projects[$name]}/probe-cross.sh"
		cat >"$probe" <<-'PROBE'
			mine=$1
			theirs=$2
			canary=$3
			if printf '%s\n' "$canary" >"$mine/own.txt" 2>/dev/null; then
				printf 'OWN :: ok\n'
			else
				printf 'OWN :: denied\n'
			fi
			if printf '%s\n' "$canary" >"$theirs/crossed.txt" 2>/dev/null; then
				printf 'CROSS :: ok\n'
			else
				printf 'CROSS :: denied\n'
			fi
		PROBE
	done

	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "${projects[alpha]}" --allow-cwd \
		-- "$FIXTURE_BASH/bin/bash" "${projects[alpha]}/probe-cross.sh" \
		"${projects[alpha]}" "${projects[beta]}" "$canary_a" \
		>"$outside/cross.alpha.out" 2>"$outside/cross.alpha.err" &
	pid_a=$!
	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "${projects[beta]}" --allow-cwd \
		-- "$FIXTURE_BASH/bin/bash" "${projects[beta]}/probe-cross.sh" \
		"${projects[beta]}" "${projects[alpha]}" "$canary_b" \
		>"$outside/cross.beta.out" 2>"$outside/cross.beta.err" &
	pid_b=$!
	wait "$pid_a" && rc_a=0 || rc_a=$?
	wait "$pid_b" && rc_b=0 || rc_b=$?
	if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ]; then
		fail "$(printf 'a concurrent probe did not run: alpha exit %s, beta exit %s\n%s\n%s' \
			"$rc_a" "$rc_b" "$(tail -10 "$outside/cross.alpha.err")" \
			"$(tail -10 "$outside/cross.beta.err")")"
		return 1
	fi

	for name in alpha beta; do
		[ "$name" = alpha ] && other=beta || other=alpha
		# The control for this half, and first: a probe that could not write
		# even inside its own project would report the sibling denied for
		# reasons that have nothing to do with the boundary between them.
		if ! grep -qxF 'OWN :: ok' "$outside/cross.$name.out"; then
			found=1
			fail "$(printf 'the %s probe could not write inside its own checkout, so its refusal next door proves nothing' "$name")"
			continue
		fi
		if ! grep -qxF 'CROSS :: denied' "$outside/cross.$name.out"; then
			found=1
			fail "$(printf 'the %s session wrote into the %s checkout' "$name" "$other")"
		fi
		if [ -e "${projects[$other]}/crossed.txt" ]; then
			found=1
			fail "$(printf 'the %s checkout gained a file written by the %s session: %s' \
				"$other" "$name" "${projects[$other]}/crossed.txt")"
		fi
	done

	[ "$found" -eq 0 ]
}

# Journey 4.1: every credential value a confined session can read is a
# substitute. The strongest observable in the spec, and the one with the
# sharpest vacuity hazard — a session handed no credential at all satisfies
# "every readable value is a substitute" perfectly — which is why the control
# comes first and asserts that a credential arrived (D9).
#
# What "the user has authenticated once on the machine" looks like here is the
# real value in the supervisor's own environment. On Linux there is no
# keychain, so that is the store, and M7a measured nono reading it there and
# never handing it to the child.
#
# Four sessions, because the scenario has two halves and one of them needs a
# control of its own:
#   ctrl  — the real value handed through under a name no nono service policy
#           claims, the probe writing its environment into its own project.
#           The positive control on the observation itself: it establishes that
#           the probe reports values faithfully and that the project-tree
#           search finds the canary when the canary is there.
#   live  — the shipped description, the same probe. The substitute-form half.
#   agent — the real entry point in the live project, so SC-6 has agent state
#           actually written to a checkout to search rather than an empty tree.
#   again — a second live session, for the per-session property.
check_j4_1() {
	local agent=claude-code binary=claude
	local outside home cfg live ctrl entry_dir env_pkg description proj arm
	local real value entry first second found=0 rc
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV crossed carriers

	session_fixture "$agent" || return 1
	entry_dir=$(pinned_bin "$binary") || return 1
	env_pkg=$(substrate_member "$FIXTURE_SUBSTRATE" env) || {
		fail "the substrate for $agent provides no env, so the session cannot print its own environment"
		return 1
	}

	outside=$(outside_root j4_1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	home="$outside/home"
	cfg="$outside/cfg"
	live="$outside/work/live"
	ctrl="$outside/work/ctrl"
	mkdir -p "$home" "$cfg" "$live" "$ctrl"
	session_env "$outside/state"

	# Per run, and shaped like the real thing, so a substring match against it
	# is a match against something a provider would have accepted.
	real="sk-ant-real-canary-$RANDOM$RANDOM"

	# The probe writes its own environment into its own project, so one
	# invocation answers both "what did the child see" and "what is now at rest
	# in the checkout". Builtins and the substrate's own env only, per check_r1:
	# PATH is inherited whole, so a name resolved inside the session can land on
	# a binary the session may not read.
	cat >"$live/probe-env.sh" <<-'PROBE'
		"$1" -0 >"$2"
	PROBE
	cp "$live/probe-env.sh" "$ctrl/probe-env.sh"

	# The ctrl arm hands the real value through under a name nono's anthropic
	# policy does not claim, which is the only way to watch the probe read a
	# real credential out: M7a measured the route overriding allow_vars for the
	# name it does claim, so granting that name would yield the substitute too.
	jq '.environment.allow_vars += ["MOCK_UNROUTED_KEY"]' \
		"$FIXTURE_PROFILE" >"$outside/ctrl.json"

	for arm in ctrl live; do
		case $arm in
		ctrl)
			proj=$ctrl
			description="$outside/ctrl.json"
			;;
		live)
			proj=$live
			description=$FIXTURE_PROFILE
			;;
		esac

		env "${SESSION_ENV[@]}" "HOME=$home" \
			"ANTHROPIC_API_KEY=$real" "MOCK_UNROUTED_KEY=$real" \
			"$(pinned_bin nono)/nono" run \
			--profile "$description" --workdir "$proj" --allow-cwd -- \
			"$FIXTURE_BASH/bin/bash" "$proj/probe-env.sh" \
			"$env_pkg/bin/env" "$proj/env.bin" \
			>"$outside/out.$arm" 2>"$outside/err.$arm" && rc=0 || rc=$?
		printf '%s\n' "$rc" >"$outside/rc.$arm"
	done

	# The control, and first (D9). Without it, "the live session saw a
	# substitute rather than the real value" is a claim about a probe that may
	# be unable to see anything at all.
	if [ ! -s "$ctrl/env.bin" ]; then
		fail "$(printf 'the control session printed no environment (exit %s), so the live session observes nothing:\n%s' \
			"$(cat "$outside/rc.ctrl")" "$(cat "$outside/err.ctrl")")"
		return 1
	fi
	mapfile -d '' -t crossed <"$ctrl/env.bin"
	value=
	for entry in "${crossed[@]}"; do
		[ "${entry%%=*}" = MOCK_UNROUTED_KEY ] && value=${entry#*=}
	done
	if [ "$value" != "$real" ]; then
		fail 'the probe cannot read a real credential even when the boundary hands it one, so the live session proves nothing'
		return 1
	fi
	# And the search SC-6 rests on must be able to find one.
	if ! grep -rqlF "$real" "$ctrl" 2>/dev/null; then
		fail 'the project-tree search cannot find a credential that is demonstrably at rest in a checkout'
		return 1
	fi

	if [ ! -s "$live/env.bin" ]; then
		fail "$(printf 'the session printed no environment (exit %s):\n%s' \
			"$(cat "$outside/rc.live")" "$(cat "$outside/err.live")")"
		return 1
	fi
	mapfile -d '' -t crossed <"$live/env.bin"
	value=
	for entry in "${crossed[@]}"; do
		[ "${entry%%=*}" = ANTHROPIC_API_KEY ] && value=${entry#*=}
	done

	# The vacuity control: a credential reached the session at all.
	if [ -z "$value" ]; then
		fail 'the session was handed no credential, so every readable value being a substitute holds vacuously'
		return 1
	fi

	# The scenario. Asserted as a form rather than as "it differs from the real
	# value", because a truncation differs too and still authenticates.
	if [[ ! $value =~ ^[0-9a-f]{64}$ ]]; then
		found=1
		fail "$(printf 'the credential the session can read is not of the substitute form: %s character(s), not 64 lowercase hex' \
			"${#value}")"
	fi
	# The carriers are named rather than printed, per check_r3: printing them
	# would put the credential and the whole environment in the suite's output.
	carriers=()
	for entry in "${crossed[@]}"; do
		[[ $entry == *"$real"* ]] && carriers+=("${entry%%=*}")
	done
	if [ "${#carriers[@]}" -gt 0 ]; then
		found=1
		fail "$(printf 'the real credential is readable inside the session, carried by: %s' "${carriers[*]}")"
	fi

	# SC-6, over the whole checkout rather than the agent's own state. The agent
	# runs first so there is state to search; the probe's own artifacts are
	# removed before the search, because they are this check's leavings rather
	# than the session's, and the environment they hold is already asserted
	# above.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		"ANTHROPIC_API_KEY=$real" \
		env -C "$live" "$entry_dir/$binary" plugin list \
		>"$outside/out.agent" 2>"$outside/err.agent" || true
	rm -f "$live/env.bin" "$live/probe-env.sh"
	if grep -rqlF "$real" "$live" 2>/dev/null; then
		found=1
		fail "$(printf 'the real credential is at rest inside the project directory: %s' \
			"$(grep -rlF "$real" "$live" 2>/dev/null | tr '\n' ' ')")"
	fi

	# Per session, which is more than FR-6 asks for and cheap to establish: a
	# substitute copied out of one session is not even the string the next one
	# sees.
	first=$value
	env "${SESSION_ENV[@]}" "HOME=$home" "ANTHROPIC_API_KEY=$real" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "$ctrl" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$ctrl/probe-env.sh" \
		"$env_pkg/bin/env" "$ctrl/again.bin" \
		>/dev/null 2>&1 || true
	second=
	if [ -s "$ctrl/again.bin" ]; then
		mapfile -d '' -t crossed <"$ctrl/again.bin"
		for entry in "${crossed[@]}"; do
			[ "${entry%%=*}" = ANTHROPIC_API_KEY ] && second=${entry#*=}
		done
	fi
	if [ -z "$second" ]; then
		found=1
		fail 'a second session was handed no credential, so the substitute cannot be shown to be per session'
	elif [ "$second" = "$first" ]; then
		found=1
		fail 'two sessions were handed the same substitute, so one copied out of a session stays valid in the next'
	fi

	[ "$found" -eq 0 ]
}

# Journey 5.1: one login on the machine serves every project and every agent.
#
# Both axes were measured to hold before this check was written (research.md §
# M7b), so the RED it starts from is the planted one recorded in plan.md rather
# than a capability that had to be built.
#
# What "authenticated once on the machine" is here: the real value in the
# supervisor's own environment, the same store M7a measured nono reading. There
# is no login step in any arm, which is the whole of "with no further login" — a
# session that had to authenticate would have to do it from inside, and nothing
# inside is given the means.
#
# The sessions are the product of the agent table and two unrelated checkouts:
#
#   * across projects, because the same agent runs in two sibling checkouts
#     that know nothing of each other, and neither is the one the credential
#     was put in the environment for;
#   * across agents, as a property over the table rather than against a named
#     second agent. Only claude-code is in it until M8, so naming a second
#     would either block this task on M8 or assert against a stand-in
#     description that says nothing about the table. The product grows on its
#     own when M8 lands and needs no edit here.
#
# D14 said the other agents obtain what they need from the authenticating one.
# They do not, and what happens instead is stronger: each declares the service
# in its own entry and the supervisor mints it an independent substitute, so no
# agent reads another's credential store and FR-6 rests on no grant between
# them. Distinctness is what carries that, asserted over every session at once
# rather than pairwise between two named ones.
#
# One $HOME and one state root for every arm, because a login that served only
# the session it was made in would still pass a check that gave each arm a
# machine of its own.
#
# The control is one further session, and it is the criterion's third identity
# (D9): `github` declared alongside `anthropic`, with only the anthropic
# credential in the environment. Without it, a route that handed every declared
# service a substitute would satisfy every assertion above — the substitute's
# form cannot tell an authenticated identity from an unauthenticated one.
# `github` because it is one of only three built-in services that name an
# environment variable at 0.74.0; openai, gemini and google-ai name none, so
# nothing in a calling environment could authenticate them either way and their
# absence would prove nothing.
check_j5_1() {
	# The service and the name it claims are the mechanism's own policy rather
	# than this repository's description, so they are written down here for the
	# same reason check_r3's `routed` list is a literal.
	local service=anthropic credvar=ANTHROPIC_API_KEY
	local unauth=github unauthvar=GITHUB_TOKEN
	local outside home real agent project proj arm desc rc value entry
	local env_pkg expected found=0 i j
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV table crossed carriers
	# Assigned rather than only declared: `local -a` leaves an array unset, and
	# `${#arr[@]}` on an unset name is an unbound-variable error under `set -u`.
	# An arm that fails before appending is the case this exists for.
	local -a arms=() substitutes=()

	if ! mapfile -t table < <(nix eval --json "$REPO_ROOT#agents" \
		--apply builtins.attrNames | jq -r '.[]'); then
		fail 'the agent table does not evaluate, so there is no set to assert the property over'
		return 1
	fi
	# Anti-vacuity: a property over an empty table holds by matching nothing.
	if [ "${#table[@]}" -eq 0 ]; then
		fail 'the agent table is empty, so "every agent in the table is authenticated" holds vacuously'
		return 1
	fi

	outside=$(outside_root j5_1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	# Outside the project, per check_r1: 48 of the deny rules are $HOME-relative
	# and a $HOME under the workdir overlaps a granted parent, which nono
	# refuses to start with.
	home="$outside/home"
	mkdir -p "$home" "$outside/work/alpha" "$outside/work/beta"
	session_env "$outside/state"

	# Per run and shaped like the real thing, so the absence asserted below is
	# the absence of something a provider would have accepted, and a value left
	# behind by an earlier run cannot satisfy it.
	real="sk-ant-real-canary-$RANDOM$RANDOM"

	# The probe writes its dump inside its own granted workdir: research.md §
	# M7b records a harness that wrote outside it and got an exit of 1 with no
	# output, which reads exactly like the mechanism refusing to start.
	for project in alpha beta; do
		cat >"$outside/work/$project/probe-env.sh" <<-'PROBE'
			"$1" -0 >"$2"
		PROBE
	done

	for agent in "${table[@]}"; do
		session_fixture "$agent" || return 1
		env_pkg=$(substrate_member "$FIXTURE_SUBSTRATE" env) || {
			fail "the substrate for $agent provides no env, so its session cannot print its own environment"
			return 1
		}

		for project in alpha beta; do
			arm="$agent/$project"
			proj="$outside/work/$project"

			env "${SESSION_ENV[@]}" "HOME=$home" "$credvar=$real" \
				"$(pinned_bin nono)/nono" run \
				--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
				"$FIXTURE_BASH/bin/bash" "$proj/probe-env.sh" \
				"$env_pkg/bin/env" "$proj/env.$agent.bin" \
				>"$outside/out.$agent.$project" 2>"$outside/err.$agent.$project" && rc=0 || rc=$?

			if [ ! -s "$proj/env.$agent.bin" ]; then
				found=1
				fail "$(printf 'the %s session printed no environment (exit %s), so it observes nothing:\n%s' \
					"$arm" "$rc" "$(cat "$outside/err.$agent.$project")")"
				continue
			fi
			mapfile -d '' -t crossed <"$proj/env.$agent.bin"

			value=
			for entry in "${crossed[@]}"; do
				[ "${entry%%=*}" = "$credvar" ] && value=${entry#*=}
			done

			# The scenario, per session. An empty value is the whole of "this
			# agent was not authenticated": nothing was minted for it, which is
			# what emptying its credentialServices produces.
			if [ -z "$value" ]; then
				found=1
				fail "$(printf 'the %s session was handed no credential, so the one login on this machine did not serve it' "$arm")"
				continue
			fi
			# The form rather than inequality with the real value, per
			# check_j4_1: a truncation differs and still authenticates.
			if [[ ! $value =~ ^[0-9a-f]{64}$ ]]; then
				found=1
				fail "$(printf 'the credential the %s session was handed is not of the substitute form: %s character(s), not 64 lowercase hex' \
					"$arm" "${#value}")"
			fi
			arms+=("$arm")
			substitutes+=("$value")

			# The carriers are named rather than printed, per check_r3.
			carriers=()
			for entry in "${crossed[@]}"; do
				[[ $entry == *"$real"* ]] && carriers+=("${entry%%=*}")
			done
			if [ "${#carriers[@]}" -gt 0 ]; then
				found=1
				fail "$(printf 'the real credential is readable inside the %s session, carried by: %s' \
					"$arm" "${carriers[*]}")"
			fi

			# "With no further login", from the supervisor's side: the route
			# says when it could not find a credential, and for an agent this
			# machine's login serves it must not be saying it.
			if grep -qaF "credential_not_found /$service" "$outside/err.$agent.$project"; then
				found=1
				fail "$(printf 'the supervisor reports %s unauthenticated for the %s session, so that session would need a login of its own' \
					"$service" "$arm")"
			fi
		done
	done

	# Bookkeeping, so a loop that quietly ran fewer sessions than the table has
	# entries cannot pass on the arms it did run.
	expected=$((${#table[@]} * 2))
	if [ "${#substitutes[@]}" -ne "$expected" ]; then
		found=1
		fail "$(printf '%s of %s sessions were handed a credential, so the property does not hold over the whole table' \
			"${#substitutes[@]}" "$expected")"
	fi

	# Each of its own. Nothing is shared between two projects or between two
	# agents, so no session's substitute is a thing another session could have
	# copied out — which is what makes a machine-scoped login safe to hold while
	# every other piece of agent state stays project-scoped (FR-4).
	for ((i = 0; i < ${#substitutes[@]}; i++)); do
		for ((j = i + 1; j < ${#substitutes[@]}; j++)); do
			if [ "${substitutes[i]}" = "${substitutes[j]}" ]; then
				found=1
				fail "$(printf 'the %s and %s sessions were handed the same substitute, so neither is minted its own' \
					"${arms[i]}" "${arms[j]}")"
			fi
		done
	done

	# The control (D9). One session, the reference agent, with a second identity
	# declared that this machine has never authenticated.
	session_fixture "${table[0]}" || return 1
	env_pkg=$(substrate_member "$FIXTURE_SUBSTRATE" env) || {
		fail "the substrate for ${table[0]} provides no env for the control session"
		return 1
	}
	desc="$outside/ctrl.json"
	jq --arg s "$unauth" '.network.credentials += [$s]' "$FIXTURE_PROFILE" >"$desc"
	proj="$outside/work/alpha"

	env "${SESSION_ENV[@]}" "HOME=$home" "$credvar=$real" \
		"$(pinned_bin nono)/nono" run \
		--profile "$desc" --workdir "$proj" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$proj/probe-env.sh" \
		"$env_pkg/bin/env" "$proj/env.ctrl.bin" \
		>"$outside/out.ctrl" 2>"$outside/err.ctrl" && rc=0 || rc=$?

	if [ ! -s "$proj/env.ctrl.bin" ]; then
		fail "$(printf 'the control session printed no environment (exit %s), so the sessions above are unattributable:\n%s' \
			"$rc" "$(cat "$outside/err.ctrl")")"
		return 1
	fi
	mapfile -d '' -t crossed <"$proj/env.ctrl.bin"
	value=
	for entry in "${crossed[@]}"; do
		[ "${entry%%=*}" = "$credvar" ] && value=${entry#*=}
	done
	# The control's own positive half: the authenticated identity still arrives
	# in this session, so the unauthenticated one being absent is the
	# authentication's doing and not the extra declaration breaking the route.
	if [[ ! $value =~ ^[0-9a-f]{64}$ ]]; then
		found=1
		fail 'the control session was handed no substitute for the identity this machine did authenticate, so its refusal of the other one attributes to nothing'
	fi
	value=
	for entry in "${crossed[@]}"; do
		[ "${entry%%=*}" = "$unauthvar" ] && value=${entry#*=}
	done
	if [ -n "$value" ]; then
		found=1
		fail "$(printf 'an identity this machine never authenticated arrived in the session under %s, so the route authenticates whatever is declared rather than what was logged in' \
			"$unauthvar")"
	fi
	if ! grep -qaF "credential_not_found /$unauth" "$outside/err.ctrl"; then
		found=1
		fail "$(printf 'the supervisor does not report %s unauthenticated, so an unauthenticated route is indistinguishable from an authenticated one' \
			"$unauth")"
	fi

	[ "$found" -eq 0 ]
}

# R8 — a substitute that is no longer valid answers differently from a denied
# path.
#
# The scenario's Given is a stored substitute that has stopped being valid. A
# session presenting a 64-hex token that is not the one this session was minted
# is exactly that, and research.md § M7c measured what comes back: the route
# answers 401 itself, with none of the upstream's headers on it. So the arm
# needs no provider, no network beyond the loopback port the session was already
# given, and no waiting on someone else's rate limit. The other reading of the
# Given — the session's own substitute, forwarded and rejected by the provider —
# leaves the machine, and is listed as a coverage gap in plan.md instead.
#
# What is asserted is the family, `401` or `407`, which is HTTP's own vocabulary
# for "who you are was not accepted". The particular body this route writes is
# not asserted: FR-16 asks that an authentication failure be identifiable and be
# distinguishable from a denial, not that a version of some upstream keeps
# phrasing it the way it does today.
#
# The denial arm is the other half, taken from the same session so that nothing
# but the operation differs: a file outside the project that is world-readable
# on the host, so the refusal is the confinement's and not the filesystem's. Its
# path arrives as an argument rather than in the environment, because the
# session's `allow_vars` drops anything the description did not name — the
# measurement's first attempt put it in `SECRET` and the probe read
# `/nonexistent` instead, which fails for the wrong reason.
#
# The denial is recognised by the wording the platform refuses with, and that
# wording is measured on the host rather than written down here: Landlock
# returns EACCES and Seatbelt EPERM, so the one refusal reads `Permission
# denied` and the other `Operation not permitted`. FR-16 is about a reader
# being able to tell the two failures apart, so what the denial says is the
# criterion here and not an implementation detail — but it is this platform's
# phrase that has to be asserted, and the derivation carries a control of its
# own so no phrase can be taken off a line that was not a refusal.
#
# Four controls, because two of the three observables are failures (D9):
#
#   1. In the same session, a file inside the project is read successfully, so a
#      session that died at startup or a probe that could read nothing at all
#      cannot pass.
#   2. The denial target is read once from outside the boundary first, so the
#      refusal attributes to confinement.
#   3. A second session, same description, with no credential in the calling
#      environment: the same stale request must come back outside the
#      authentication family. Without it, a route that answered 401 to
#      everything — including to the substitute it had itself minted — would
#      satisfy the first arm. It also draws the line the scenario is on: a
#      credential that was never there is a different answer again from one that
#      is no longer valid.
#   4. The file the wording is measured from is read once from outside the
#      boundary too, and the line it is taken from has to name that file.
#      Without the first, the phrase could be `No such file or directory` and
#      every assertion below would be looking for the wrong thing; without the
#      second, it could be taken off nono's own report instead.
check_r8() {
	local agent=claude-code
	local outside home proj denied inside cu desc rc arm i
	local canary stale auth denial status phrase_src vocab phrase
	local found=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV cred=()

	session_fixture "$agent" || return 1
	cu=$(substrate_member "$FIXTURE_SUBSTRATE" env) || {
		fail "the substrate for $agent provides no coreutils, so the session cannot read a file or time out a request"
		return 1
	}

	outside=$(outside_root r8) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	home="$outside/home"
	proj="$outside/work"
	mkdir -p "$home" "$proj"
	session_env "$outside/state"

	# Per run, so a stale match in a file left by an earlier run cannot satisfy
	# the in-project read.
	canary="PROJECT-FILE-CONTENT-$RANDOM$RANDOM"
	inside="$proj/inside.txt"
	printf '%s\n' "$canary" >"$inside"

	denied="$outside/secret.txt"
	printf 'a file the session was never granted\n' >"$denied"
	chmod 0644 "$denied"
	# Control 2.
	if ! grep -q . "$denied"; then
		fail 'the denial target is not readable outside the boundary, so a refusal inside it would prove nothing'
		return 1
	fi

	# The vocabulary a denial is written in belongs to the platform, not to this
	# check: Landlock refuses with EACCES and Seatbelt with EPERM, so the same
	# refusal reads `Permission denied` on one and `Operation not permitted` on
	# the other. So it is measured on the host the check is running on, from a
	# second file outside the project read by the same program the probe reads
	# with — a phrase written down here would describe whichever platform it was
	# written on.
	#
	# The child redirects its own stderr into its granted workdir rather than
	# letting it join the harness's, because nono writes its capability table
	# there too and the phrase would be taken from that instead.
	phrase_src="$outside/vocabulary.txt"
	printf 'a second file the session was never granted\n' >"$phrase_src"
	# Control 4, and the derivation's whole footing: unconfined, this file reads.
	# Without it the phrase could be measured off a path that was not there, and
	# every assertion below would then be looking for `No such file or directory`
	# in a message that correctly says nothing of the kind.
	if ! grep -q . "$phrase_src"; then
		fail 'the file the denial wording is measured from is not readable outside the boundary, so the wording would not be a denial'
		return 1
	fi
	# The positional parameters belong to the shell inside the session, so the
	# script text must reach it unexpanded.
	# shellcheck disable=SC2016
	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" -c '"$1" "$2" 2>"$3"' bash \
		"$cu/bin/cat" "$phrase_src" "$proj/vocabulary.err" >/dev/null 2>&1 || :
	vocab=$(tail -n 1 "$proj/vocabulary.err" 2>/dev/null)
	phrase=${vocab##*: }
	# And the line has to be about the file that was refused. If it is not, it
	# came from somewhere else — nono's own report, or a shell that never ran the
	# program — and the phrase taken off the end of it means nothing.
	if [ -z "$phrase" ] || [ "$phrase" = "$vocab" ] ||
		! printf '%s' "$vocab" | grep -qF "$phrase_src"; then
		fail "$(printf 'the wording this platform refuses a read with could not be measured, so a denial cannot be told from an authentication failure by it:\n%s' \
			"$vocab")"
		return 1
	fi

	# A substitute in the shape of a real one that is not the one this session
	# holds: minted per run, so it is never the session's own by accident.
	stale=
	for ((i = 0; i < 16; i++)); do
		stale+=$(printf '%04x' "$RANDOM")
	done

	# The probe writes into its own granted workdir, per check_j5_1. There is no
	# HTTP client anywhere in the session's reach, so the request goes onto
	# bash's own socket; coreutils supplies the timeout and the read.
	cat >"$proj/probe-r8.sh" <<-'PROBE'
		set -u
		cu=$1
		out=$2
		inside=$3
		denied=$4
		stale=$5
		mkdir -p "$out"

		# Control 1.
		"$cu/bin/cat" "$inside" >"$out/inside.txt" 2>&1

		url=${ANTHROPIC_BASE_URL:-}
		if [ -z "$url" ]; then
			printf 'the session was handed no provider route\n' >"$out/auth.txt"
		else
			hostport=${url#http://}
			path=/${hostport#*/}
			hostport=${hostport%%/*}
			body='{"model":"claude-3-5-haiku-20241022","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
			if exec 3<>"/dev/tcp/${hostport%%:*}/${hostport##*:}" 2>"$out/connect.txt"; then
				printf 'POST %s/v1/messages HTTP/1.1\r\nHost: %s\r\nx-api-key: %s\r\nauthorization: Bearer %s\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\ncontent-length: %s\r\nconnection: close\r\n\r\n%s' \
					"$path" "$hostport" "$stale" "$stale" "${#body}" "$body" >&3
				"$cu/bin/timeout" 25 "$cu/bin/cat" <&3 >"$out/auth.txt" 2>&1
				exec 3<&-
			else
				printf 'the session could not reach the route it was handed\n' >"$out/auth.txt"
			fi
		fi

		"$cu/bin/cat" "$denied" >"$out/denial.txt" 2>&1
	PROBE

	for arm in stale unauthenticated; do
		cred=()
		[ "$arm" = stale ] && cred=("ANTHROPIC_API_KEY=sk-ant-real-canary-$RANDOM$RANDOM")
		rm -rf "$proj/out-$arm"

		env "${SESSION_ENV[@]}" "HOME=$home" "${cred[@]+"${cred[@]}"}" \
			"$(pinned_bin nono)/nono" run \
			--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
			"$FIXTURE_BASH/bin/bash" "$proj/probe-r8.sh" \
			"$cu" "$proj/out-$arm" "$inside" "$denied" "$stale" \
			>"$outside/out.$arm" 2>"$outside/err.$arm" && rc=0 || rc=$?

		if ! grep -qF "$canary" "$proj/out-$arm/inside.txt" 2>/dev/null; then
			found=1
			fail "$(printf 'the %s session never read the file inside the project (exit %s), so it observed no session:\n%s' \
				"$arm" "$rc" "$(cat "$outside/err.$arm")")"
			continue
		fi

		auth=$(cat "$proj/out-$arm/auth.txt" 2>/dev/null)
		# The status line, with the carriage return the wire format puts on it.
		status=$(printf '%s' "$auth" | head -n 1 | tr -d '\r')

		if [ "$arm" = unauthenticated ]; then
			# Control 3. The route must not answer the authentication family to
			# a session it was never given a credential for, or the arm above
			# says nothing about the credential.
			if [[ $status =~ ^HTTP/1\.[01][[:space:]]+(401|407)([[:space:]]|$) ]]; then
				found=1
				fail "$(printf 'a session with no credential at all is answered in the authentication family too (%s), so that answer does not identify a credential that stopped being valid' \
					"$status")"
			fi
			continue
		fi

		denial=$(cat "$proj/out-$arm/denial.txt" 2>/dev/null)

		if [ -z "$auth" ] || [ -z "$denial" ]; then
			found=1
			fail "$(printf 'one of the two failures produced no message at all (auth %s byte(s), denial %s byte(s)), so neither can be told from the other' \
				"${#auth}" "${#denial}")"
			continue
		fi

		# The scenario's first Then: what came back identifies an authentication
		# failure.
		if [[ ! $status =~ ^HTTP/1\.[01][[:space:]]+(401|407)([[:space:]]|$) ]]; then
			found=1
			fail "$(printf 'a request carrying a substitute that is no longer valid was not answered in the authentication family:\n%s' \
				"$status")"
		fi

		# The scenario's second Then, both ways round: neither message carries
		# the other's vocabulary, so a reader cannot mistake one for the other.
		if printf '%s' "$auth" | grep -qF "$phrase"; then
			found=1
			fail "$(printf 'the authentication failure reads as a confinement denial (%s):\n%s' "$phrase" "$auth")"
		fi
		if ! printf '%s' "$denial" | grep -qF "$phrase"; then
			found=1
			fail "$(printf 'reading a path outside the project did not fail on permission (%s), so there is no denial to be distinguished from:\n%s' \
				"$phrase" "$denial")"
		fi
		if printf '%s' "$denial" | grep -qE '\b(401|407|[Uu]nauthorized)\b'; then
			found=1
			fail "$(printf 'the confinement denial reads as an authentication failure:\n%s' "$denial")"
		fi
		if [ "$auth" = "$denial" ]; then
			found=1
			fail 'the two failures produce the same message, so they are not distinguishable'
		fi
	done

	[ "$found" -eq 0 ]
}

# The state a session left inside the project, content-addressed, so a file
# rewritten with the same bytes is the same state while a file recording which
# session wrote it is not. The harness's own scratch is pruned: the probe script
# and its dump live inside the granted workdir, per research.md § M7b, and are
# this check's residue rather than the environment's.
project_state_manifest() {
	local root=$1 path
	(
		cd "$root" || exit 1
		find . -mindepth 1 -path ./harness -prune -o -print | sort | while IFS= read -r path; do
			if [ -d "$path" ]; then
				printf 'dir   %s\n' "$path"
			elif [ -f "$path" ]; then
				printf 'file  %s  %s\n' "$(sha256sum <"$path" | cut -d' ' -f1)" "$path"
			else
				printf 'other %s\n' "$path"
			fi
		done
	)
}

# One variable's value out of an `env -0` dump, by name.
env_dump_value() {
	local file=$1 name=$2 entry
	local -a entries=()
	mapfile -d '' -t entries <"$file"
	for entry in "${entries[@]}"; do
		if [ "${entry%%=*}" = "$name" ]; then
			printf '%s' "${entry#*=}"
			return 0
		fi
	done
	return 1
}

# Rep3: authenticating twice is harmless.
#
# There is no login to run twice. M7b measured the whole of "this machine is
# authenticated" to be a value in the calling environment: nothing logs in, and
# the supervisor mints a substitute from that value for each session it starts.
# So "authenticate again" is that value being supplied again — and a second
# login yields a *new* token, which is why the second authentication here
# carries a different one. That is what the second canary is for: anything in
# the resulting state that depended on which login produced it would differ
# between the two, and the comparison below would say so.
#
# Each authentication is observed twice, because the state has two halves and
# neither is readable from the other's session. The entry point a user types is
# what leaves state at rest, and `claude --version` is the whole of a start —
# the wrapper's own writes happen and the agent exits in about a second, as
# check_r5 also relies on. A probe session started from the same description is
# what the state handed to the agent is read out of.
#
# "Indistinguishable" is then asserted as: the two environments are identical
# once the values the supervisor mints per session are replaced by what they
# are. The *whole* environment rather than a credential-shaped subset of it,
# because the scenario does not get to choose which variables count. Measured,
# the only entries that differ between two sessions are the substitute, the
# loopback authority it is served on, the interception session directory, the
# browser shim and the capability file — every one of them session-scoped by
# D14's own table — so a release that made anything else vary per session is
# something this check should notice rather than tolerate. Each mask is a long
# unique string taken out of that session's own dump, never a fragment like a
# bare port number that could match somewhere else in it.
#
# The state root is deliberately not compared. nono writes an audit record per
# session there by design (D13), outside every project, so two authentications
# must differ there and a check that compared it would be asserting the opposite
# of the decision.
check_rep3() {
	local agent=claude-code entry=claude credvar=ANTHROPIC_API_KEY
	local outside home proj cfg entry_dir env_pkg dump
	local real value authority rc i k entry found=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV
	# Assigned rather than only declared, per check_j5_1: `local -a` leaves an
	# array unset, and `${#arr[@]}` on an unset name is an error under `set -u`.
	local -a crossed=() needles=() masks=() tokens=()

	session_fixture "$agent" || return 1

	# The flake attribute of an entry point is the binary's name, not the
	# agent's, as recorded on check_r4.
	entry_dir=$(pinned_bin "$entry") || {
		fail "the entry point $entry does not build"
		return 1
	}
	env_pkg=$(substrate_member "$FIXTURE_SUBSTRATE" env) || {
		fail "the substrate for $agent provides no env, so a session cannot print its own environment"
		return 1
	}

	outside=$(outside_root rep3) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	# Outside the project, per check_r1. The config root is the entry point's
	# own requirement: it creates $XDG_CONFIG_HOME rather than defaulting it.
	home="$outside/home"
	proj="$outside/work/proj"
	cfg="$outside/cfg"
	mkdir -p "$home" "$proj/harness" "$cfg"

	# A host identity, so the entry point's create-if-absent copy (FR-23) has
	# something to write and the at-rest half has something to compare. Without
	# it the entry point writes nothing at all and two empty manifests would
	# match for the wrong reason — which the control below is what catches.
	printf '[user]\n\tname = Rep3 Person\n\temail = rep3@example.invalid\n' \
		>"$home/.gitconfig"

	session_env "$outside/state"
	cat >"$proj/harness/probe-env.sh" <<-'PROBE'
		"$1" -0 >"$2"
	PROBE

	for i in 1 2; do
		# Distinct per authentication, and shaped like the real thing: a second
		# login does not hand back the first login's token.
		real="sk-ant-real-canary-$i-$RANDOM$RANDOM"

		# The start a user performs, in the project, through the entry point.
		(
			cd "$proj" || exit 1
			env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
				"$credvar=$real" \
				"$entry_dir/$entry" --version
		) >"$outside/entry.$i.out" 2>"$outside/entry.$i.err" && rc=0 || rc=$?
		if [ "$rc" -ne 0 ]; then
			found=1
			fail "$(printf 'authentication %s started no session through the entry point (exit %s), so there is no state it produced:\n%s' \
				"$i" "$rc" "$(tail -n 5 "$outside/entry.$i.err")")"
			continue
		fi

		# The same description, with a shell in it, so the state the agent is
		# handed can be read.
		dump="$proj/harness/env.$i.bin"
		env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
			"$credvar=$real" \
			"$(pinned_bin nono)/nono" run \
			--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
			"$FIXTURE_BASH/bin/bash" "$proj/harness/probe-env.sh" \
			"$env_pkg/bin/env" "$dump" \
			>"$outside/probe.$i.out" 2>"$outside/probe.$i.err" && rc=0 || rc=$?
		if [ ! -s "$dump" ]; then
			found=1
			fail "$(printf 'authentication %s printed no environment (exit %s), so it observes nothing:\n%s' \
				"$i" "$rc" "$(tail -n 5 "$outside/probe.$i.err")")"
			continue
		fi
		mapfile -d '' -t crossed <"$dump"

		needles=()
		masks=()

		value=$(env_dump_value "$dump" "$credvar") || value=
		if [ -z "$value" ]; then
			found=1
			fail "$(printf 'authentication %s handed the session no credential, so there is no authenticated state to compare' "$i")"
			continue
		fi
		if [[ ! $value =~ ^[0-9a-f]{64}$ ]]; then
			found=1
			fail "$(printf 'the credential authentication %s handed the session is not of the substitute form: %s character(s), not 64 lowercase hex' \
				"$i" "${#value}")"
		fi
		tokens+=("$value")
		needles+=("$value")
		masks+=('<substitute>')

		# The loopback authority the substitute is served on, masked as a unit
		# rather than by its port, which is short enough to occur elsewhere.
		if value=$(env_dump_value "$dump" ANTHROPIC_BASE_URL) && [ -n "$value" ]; then
			authority=${value#*://}
			authority=${authority%%/*}
			needles+=("$authority")
			masks+=('<loopback-authority>')
		fi
		# The interception session directory (M7e's subject) and the browser
		# shim are per-session directories under stable parents, so the
		# directory is what is masked and the file name is still compared.
		if value=$(env_dump_value "$dump" SSL_CERT_FILE) && [ -n "$value" ]; then
			needles+=("$(dirname -- "$value")")
			masks+=('<intercept-session>')
		fi
		if value=$(env_dump_value "$dump" BROWSER) && [ -n "$value" ]; then
			needles+=("$(dirname -- "$value")")
			masks+=('<browser-shim>')
		fi
		if value=$(env_dump_value "$dump" NONO_CAP_FILE) && [ -n "$value" ]; then
			needles+=("$value")
			masks+=('<capability-file>')
		fi

		for entry in "${crossed[@]}"; do
			for ((k = 0; k < ${#needles[@]}; k++)); do
				entry=${entry//"${needles[k]}"/${masks[k]}}
			done
			printf '%s\n' "$entry"
		done | sort >"$outside/state.$i"

		project_state_manifest "$proj" >"$outside/at-rest.$i"
	done

	# Bookkeeping, so an authentication that fell out of the loop early cannot
	# leave the comparison below reading one state twice or none at all.
	if [ "${#tokens[@]}" -ne 2 ]; then
		fail "$(printf '%s of 2 authentications produced a state, so there is no second one to be indistinguishable from' \
			"${#tokens[@]}")"
		return 1
	fi

	# The control (D9), and first: both halves are non-empty and the
	# authenticated one carries the credential, so two absent states cannot pass
	# as two indistinguishable ones.
	for i in 1 2; do
		if ! grep -qFx "$credvar=<substitute>" "$outside/state.$i"; then
			found=1
			fail "$(printf 'the state authentication %s produced does not carry the captured credential, so comparing it to the other proves nothing' "$i")"
		fi
		if ! grep -qF '  ./.agents/git/config' "$outside/at-rest.$i"; then
			found=1
			fail "$(printf 'authentication %s left nothing at rest in the project, so two at-rest states matching compares nothing' "$i")"
		fi
	done

	# And the masking is a reduction rather than a no-op: the substitute is
	# minted per session (check_j5_1), so if these two were equal the states
	# would match for a reason this scenario does not claim.
	if [ "${tokens[0]}" = "${tokens[1]}" ]; then
		found=1
		fail 'both authentications were handed the same substitute, so the two states are equal before anything is masked'
	fi

	# The scenario. Both halves, because neither implies the other: an
	# environment that varied per login would leave the project untouched, and a
	# record of which session authenticated would leave the environment alone.
	if ! diff -q "$outside/state.1" "$outside/state.2" >/dev/null; then
		found=1
		fail "$(printf 'authenticating a second time produced a different authenticated state:\n%s' \
			"$(diff -- "$outside/state.1" "$outside/state.2" || true)")"
	fi
	if ! diff -q "$outside/at-rest.1" "$outside/at-rest.2" >/dev/null; then
		found=1
		fail "$(printf 'authenticating a second time left different state at rest inside the project:\n%s' \
			"$(diff -- "$outside/at-rest.1" "$outside/at-rest.2" || true)")"
	fi

	[ "$found" -eq 0 ]
}

# Journey 6.1 and FR-17. An ordinary tool's HTTPS exchange with the remote
# succeeds while the session's traffic is being inspected.
#
# Three arms in one session, per plan.md § check_j6_1. The shape is forced by
# D9: `git` exits 0 when trust propagated to it, and it would exit 0 again if
# nothing were inspected at all, so one observation cannot carry a difference.
#
#   1. The mechanism engaged — the five trust-bundle variables are set, the
#      file they name is readable from inside, and it holds whole PEM
#      certificate blocks. Plus the banner's network line, which is an
#      observable the child's environment cannot influence.
#   2. The exchange did its work — `git ls-remote` against the remote, matched
#      as a shape rather than pinned to a value, so it survives the remote
#      moving on.
#   3. The negative control, in the same session — the same exchange with the
#      trust bundle pointed at /dev/null must fail, and fail with a
#      certificate error rather than a confinement denial.
#
# Arm 3 is permanent and deliberately absent from plan.md's planted-violations
# table: the property under test *is* the difference between arms 2 and 3, so
# removing it would be a regression rather than a plant.
#
# "Parses as a certificate" is asserted structurally here and semantically by
# the other two arms. There is no openssl in the substrate to parse it with,
# and asking the tool that actually loads it is the better instrument anyway:
# arm 3 shows what a file that is not a certificate produces — `error adding
# trust anchors from file: /dev/null` — and arm 2 shows this one does not.
#
# The session is handed a credential because a real one has one. The exchange
# itself is credential-free (M1c), and nothing below reads that value.
check_j6_1() {
	local agent=claude-code
	# The project's own canonical remote (FR-19), so the exchange is with a
	# host this repository already depends on rather than an arbitrary third
	# party. It is the destination, never an expected answer.
	local remote='https://github.com/GRBurst/agent-sandbox'
	local outside home proj git_pkg rc found=0
	local var value key answer
	local readable=no begin=0 end=0 bytes=0
	local trusted_rc=1 untrusted_rc=0
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV
	local -a trust=(SSL_CERT_FILE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE GIT_SSL_CAINFO)
	# Assigned rather than only declared, per check_j5_1.
	local -a missing=()

	session_fixture "$agent" || return 1
	git_pkg=$(substrate_member "$FIXTURE_SUBSTRATE" git) || {
		fail "the substrate for $agent provides no git, so the session has no ordinary tool to exchange with a remote"
		return 1
	}

	outside=$(outside_root j6_1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	home="$outside/home"
	proj="$outside/work/proj"
	mkdir -p "$home" "$proj/harness"
	session_env "$outside/state"

	# Inside the granted workdir, per check_j5_1.
	cat >"$proj/harness/probe-j6_1.sh" <<-'PROBE'
		set -u
		git=$1
		out=$2
		url=$3

		: >"$out/trust.tsv"
		for v in SSL_CERT_FILE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS CURL_CA_BUNDLE GIT_SSL_CAINFO; do
			printf '%s\t%s\n' "$v" "${!v-}" >>"$out/trust.tsv"
		done

		# Read from inside: the mechanism deletes the session directory the
		# bundle lives in when the session ends, so there is nothing left to
		# inspect afterwards.
		readable=no
		begin=0
		end=0
		bytes=0
		if [ -n "${SSL_CERT_FILE-}" ] && [ -r "${SSL_CERT_FILE-}" ]; then
			readable=yes
			while IFS= read -r line || [ -n "$line" ]; do
				bytes=$((bytes + ${#line} + 1))
				case $line in
				*'BEGIN CERTIFICATE'*) begin=$((begin + 1)) ;;
				*'END CERTIFICATE'*) end=$((end + 1)) ;;
				esac
			done <"$SSL_CERT_FILE"
		fi
		printf 'readable\t%s\nbegin\t%s\nend\t%s\nbytes\t%s\n' \
			"$readable" "$begin" "$end" "$bytes" >"$out/bundle.tsv"

		"$git" ls-remote "$url" HEAD >"$out/trusted.out" 2>"$out/trusted.err"
		printf '%s\n' "$?" >"$out/trusted.rc"

		# Arm 3, in this same session: every variable the mechanism set, pointed
		# somewhere that is not a certificate.
		SSL_CERT_FILE=/dev/null REQUESTS_CA_BUNDLE=/dev/null NODE_EXTRA_CA_CERTS=/dev/null \
			CURL_CA_BUNDLE=/dev/null GIT_SSL_CAINFO=/dev/null \
			"$git" ls-remote "$url" HEAD >"$out/untrusted.out" 2>"$out/untrusted.err"
		printf '%s\n' "$?" >"$out/untrusted.rc"
	PROBE

	env "${SESSION_ENV[@]}" "HOME=$home" "ANTHROPIC_API_KEY=sk-ant-real-canary-$RANDOM$RANDOM" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
		"$FIXTURE_BASH/bin/bash" "$proj/harness/probe-j6_1.sh" \
		"$git_pkg/bin/git" "$proj/harness" "$remote" \
		>"$outside/out" 2>"$outside/err" && rc=0 || rc=$?

	if [ ! -s "$proj/harness/trust.tsv" ]; then
		fail "$(printf 'the session observed nothing (exit %s), so no arm of this check ran:\n%s' \
			"$rc" "$(cat "$outside/err")")"
		return 1
	fi

	# Arm 1, the mechanism engaged, read out of the child's own environment.
	while IFS=$'\t' read -r var value; do
		[ -n "$value" ] || missing+=("$var")
	done <"$proj/harness/trust.tsv"
	if [ "${#missing[@]}" -gt 0 ]; then
		found=1
		fail "$(printf 'the session was handed no trust in the inspecting authority, so a tool that validates a certificate is broken by the interception: %s unset' \
			"${missing[*]}")"
	fi

	# Bookkeeping: a loop that read fewer lines than there are variables would
	# otherwise report every one of them present.
	if [ "$(wc -l <"$proj/harness/trust.tsv")" -ne "${#trust[@]}" ]; then
		found=1
		fail "$(printf 'the probe reported on %s variable(s), not the %s this arm is about' \
			"$(wc -l <"$proj/harness/trust.tsv")" "${#trust[@]}")"
	fi

	# The same arm from the supervisor's side, so a change in how the mechanism
	# exports those five names does not take arm 1 down with it. The banner
	# distinguishes a tunnel from an inspected destination in one word.
	if ! grep -Eq 'net[[:space:]]+proxy' "$outside/err"; then
		found=1
		fail "$(printf 'the session reports no inspecting proxy, so there is no interception for a tool to survive: %s' \
			"$(grep -E 'net[[:space:]]' "$outside/err" | head -n 1 || printf '(no network line in the banner)')")"
	fi

	while IFS=$'\t' read -r key value; do
		case $key in
		readable) readable=$value ;;
		begin) begin=$value ;;
		end) end=$value ;;
		bytes) bytes=$value ;;
		esac
	done <"$proj/harness/bundle.tsv"

	if [ "$readable" != yes ]; then
		found=1
		fail 'the authority the session is told to trust is not readable from inside it, so the trust it was handed is nominal'
	elif [ "$begin" -lt 1 ] || [ "$begin" -ne "$end" ]; then
		found=1
		fail "$(printf 'the file the session is told to trust holds no whole certificate: %s BEGIN and %s END marker(s) in %s byte(s)' \
			"$begin" "$end" "$bytes")"
	fi

	trusted_rc=$(cat "$proj/harness/trusted.rc")
	untrusted_rc=$(cat "$proj/harness/untrusted.rc")
	answer=$(cat "$proj/harness/trusted.out")

	# Arm 2, the exchange. This is also arm 3's positive control (D9): without
	# it, a session that could not reach the network at all would satisfy arm 3
	# and prove nothing.
	if [ "$trusted_rc" -ne 0 ]; then
		found=1
		fail "$(printf 'the exchange with the remote failed (exit %s) while the session was trusting the inspecting authority:\n%s' \
			"$trusted_rc" "$(cat "$proj/harness/trusted.err")")"
	elif [[ ! $answer =~ ^[0-9a-f]{40}[[:space:]]+HEAD$ ]]; then
		# The shape, never the value: the remote moves on, and a check pinned
		# to today's commit would fail on its own success.
		found=1
		fail "$(printf 'the exchange returned nothing of the shape a ref listing has: %s' "$answer")"
	fi

	# Arm 3, the permanent negative control.
	if [ "$untrusted_rc" -eq 0 ]; then
		found=1
		fail 'the exchange succeeded with the trust bundle pointed at /dev/null, so arm 2 succeeding says nothing about trust having been propagated'
	elif ! grep -Eqi 'certificate|trust anchor' "$proj/harness/untrusted.err"; then
		found=1
		fail "$(printf 'the exchange without the bundle failed for a reason that is not a certificate error, so the difference between the two arms is not the trust:\n%s' \
			"$(cat "$proj/harness/untrusted.err")")"
	elif grep -qF 'Permission denied' "$proj/harness/untrusted.err"; then
		# The documented failure mode this journey exists for, inverted: a
		# denial must not be what arm 3 is reading as a certificate error.
		found=1
		fail "$(printf 'the exchange without the bundle was refused by the confinement rather than by the certificate:\n%s' \
			"$(cat "$proj/harness/untrusted.err")")"
	fi

	[ "$found" -eq 0 ]
}

# One session, two commits, so that each is the other's control (D9).
#
# Journey 6.2 and R11 differ in exactly one thing — whether the checkout's own
# configuration demands a signature — and neither is evidence on its own. A
# session that cannot commit at all satisfies R11's refusal, and a session that
# read no configuration whatever satisfies Journey 6.2's success. Running both
# commits in one session is what makes the difference attributable to the
# demand, so the two checks share this helper rather than each building a
# session of its own.
#
# The checkout is one this environment configured: the entry point runs first
# and writes `.agents/git/config` out of the host identity (FR-23), which is
# what gives either commit an author at all.
#
# The demand is planted in the checkout's own `.git/config` and nowhere else.
# A demand written to the host's global file is erased by GIT_CONFIG_GLOBAL
# (D11), so a check that planted it there would watch the commit succeed and
# report a refusal it never provoked.
#
# Sets ARMS_PROJ to the project the session ran in, ARMS_TRACE to the syscall
# trace where the platform has a tracer and empty where it has none, and
# ARMS_NOISE to the trailer of a session that made no commit. Leaves the
# session's own report in $outside/probe.out and its stderr, nono's trailer
# included, in $outside/probe.err.
commit_session() {
	local outside=$1
	local agent=claude-code binary=claude
	local entry home proj cfg gitdir git strace rc
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV traced

	entry=$(pinned_bin "$binary")
	session_fixture "$agent" || return 1
	gitdir=$(substrate_member "$FIXTURE_SUBSTRATE" git) || {
		fail "the substrate for $agent provides no git, so there is no commit to make"
		return 1
	}
	git="$gitdir/bin/git"

	# A tracer where the platform has one. Its absence is not a failure here:
	# R11 reads only what the probe reports, and Journey 6.2 has nono's own
	# supervisor to fall back on, so a helper that refused without strace failed
	# both checks on macOS over an instrument only one of them uses.
	strace=$(substrate_member "$FIXTURE_SUBSTRATE" strace) || strace=

	# A sibling of the fake home rather than a directory inside it: the
	# description carries $HOME-relative deny rules, and nono refuses to start
	# on a workdir that overlaps one.
	home="$outside/home"
	proj="$outside/proj"
	cfg="$outside/cfg"
	mkdir -p "$home" "$cfg" "$proj/plain" "$proj/demand"

	printf '[user]\n\tname = Commit Person %s\n\temail = commit-%s@example.invalid\n' \
		"$RANDOM" "$RANDOM" >"$home/.gitconfig"

	session_env "$outside/state"

	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" \
		env -C "$proj" "$entry/$binary" --version \
		>"$outside/entry.out" 2>"$outside/entry.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the entry point does not start in a scratch project (exit %s), so there is no checkout this environment configured:\n%s' \
			"$rc" "$(tail -20 "$outside/entry.err")")"
		return 1
	fi

	cat >"$proj/probe.sh" <<-'PROBE'
		git=$1
		work=$2

		cd "$work/plain" || exit 1
		"$git" init -q .
		printf 'a\n' >f
		"$git" add f
		"$git" commit -m "an ordinary commit" >"$work/plain.log" 2>&1
		printf 'PLAIN_RC :: %s\n' "$?"
		"$git" config --get commit.gpgsign >"$work/plain.gpgsign" 2>&1
		printf 'PLAIN_DEMAND_RC :: %s\n' "$?"
		printf 'PLAIN_HEAD :: %s\n' "$("$git" rev-parse --verify HEAD 2>/dev/null || printf none)"
		printf 'PLAIN_GPGSIG :: %s\n' "$("$git" cat-file commit HEAD 2>/dev/null | grep -c '^gpgsig')"
		printf 'PLAIN_SIGSTATUS :: %s\n' "$("$git" log -1 --format='%G?' 2>/dev/null)"

		cd "$work/demand" || exit 1
		"$git" init -q .
		"$git" config --local commit.gpgsign true
		printf 'b\n' >f
		"$git" add f
		"$git" commit -m "a commit the checkout demands a signature for" >"$work/demand.log" 2>&1
		printf 'DEMAND_RC :: %s\n' "$?"
		printf 'DEMAND_HEAD :: %s\n' "$("$git" rev-parse --verify HEAD 2>/dev/null || printf none)"
		printf 'DEMAND_OBJECTS :: %s\n' "$("$git" rev-list --count --all 2>/dev/null)"
	PROBE

	# The tracer wraps the whole session rather than the one commit inside it, so
	# that what it observes is the span nono's trailer observes where there is no
	# tracer: everything the session did, both commits included.
	traced=()
	if [ -n "$strace" ]; then
		traced=("$strace/bin/strace" -f -e trace=openat -o "$proj/session.trace")
	else
		# The noise floor, for the platform whose supervisor is the instrument.
		# macOS refuses a handful of paths to every process there is, the
		# text-encoding file each CoreFoundation program opens among them, and a
		# session measured against zero would be failed by its platform rather
		# than by its own reach. Same profile, same home, and git rather than
		# `true` so that git's own startup is inside the floor — but no commit.
		env "${SESSION_ENV[@]}" "HOME=$home" \
			"$(pinned_bin nono)/nono" run \
			--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
			"$git" --version >/dev/null 2>"$outside/noise.err" || :
	fi

	env "${SESSION_ENV[@]}" "HOME=$home" \
		"$(pinned_bin nono)/nono" run \
		--profile "$FIXTURE_PROFILE" --workdir "$proj" --allow-cwd -- \
		"${traced[@]}" "$FIXTURE_BASH/bin/bash" "$proj/probe.sh" "$git" "$proj" \
		>"$outside/probe.out" 2>"$outside/probe.err" && rc=0 || rc=$?

	# The last line the probe writes. A session that died halfway would
	# otherwise leave both checks asserting against an absence.
	if ! grep -qF 'DEMAND_OBJECTS ::' "$outside/probe.out"; then
		fail "$(printf 'the session did not run both commits to the end (exit %s):\n%s\n%s' \
			"$rc" "$(cat "$outside/probe.out")" "$(tail -20 "$outside/probe.err")")"
		return 1
	fi

	ARMS_PROJ=$proj
	ARMS_TRACE=${strace:+$proj/session.trace}
	ARMS_NOISE="$outside/noise.err"
}

# Journey 6.2 — a commit made inside a session succeeds, carries no signature,
# and reaches for nothing it is refused.
#
# The third Then is asserted as the absence of a denial rather than as a list
# of files: a read outside the session's reach cannot succeed, so the only way
# producing the commit could have depended on one is by being refused. An empty
# denial set is therefore the statement that the commit needed nothing from
# outside — and it is not vacuous, because the commit in the same session
# succeeded, which a session denied what it needed could not have managed.
#
# Which instrument answers that is the platform's to decide, and this is the
# one place the two are named. Landlock tells nono nothing about what it
# blocked, so on Linux the observable is a syscall trace. Seatbelt reports
# every refusal to it, and no tracer runs on macOS without SIP disabled or
# root, so there the observable is nono's own trailer, measured against the
# floor a session that made no commit was refused.
#
# FR-24's default is asserted against the configuration this environment wrote
# and not only against the object: a session that happened to commit unsigned
# because it had no key would pass on the object alone.
check_j6_2() {
	local outside out proj found=0
	local ARMS_PROJ ARMS_TRACE ARMS_NOISE
	local head sig status denials=''

	outside=$(outside_root j6_2) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	commit_session "$outside" || return 1
	out="$outside/probe.out"
	proj=$ARMS_PROJ

	if ! grep -qF 'PLAIN_RC :: 0' "$out"; then
		fail "$(printf 'a commit inside the session failed, so committing is not what the environment ships:\n%s' \
			"$(cat "$proj/plain.log" 2>/dev/null)")"
		return 1
	fi

	head=$(sed -n 's/^PLAIN_HEAD :: //p' "$out")
	if ! printf '%s' "$head" | grep -qE '^[0-9a-f]{40}$'; then
		found=1
		fail "$(printf 'the commit reported success and left no commit object behind: %s' "$head")"
	fi

	sig=$(sed -n 's/^PLAIN_GPGSIG :: //p' "$out")
	status=$(sed -n 's/^PLAIN_SIGSTATUS :: //p' "$out")
	if [ "$sig" != "0" ] || [ "$status" != "N" ]; then
		found=1
		fail "$(printf 'the commit carries a signature, so producing it needed key material: %s gpgsig header(s), signature status %s' \
			"$sig" "$status")"
	fi

	# FR-24 on the configuration rather than on the object. `git config --get`
	# exits 1 for a key set nowhere, so a zero exit here is a demand this
	# environment wrote itself.
	if grep -qF 'PLAIN_DEMAND_RC :: 0' "$out"; then
		found=1
		fail "$(printf 'the configuration this environment wrote asks for a signature: commit.gpgsign = %s' \
			"$(cat "$proj/plain.gpgsign" 2>/dev/null)")"
	fi

	# One claim, whichever instrument the platform has. Each arm carries its own
	# answer to "was anything watching", because an empty denial set from an
	# instrument that never ran is silence dressed as evidence.
	if [ -n "$ARMS_TRACE" ]; then
		if [ ! -s "$ARMS_TRACE" ]; then
			found=1
			fail 'the session was not traced at all, so an empty set of denials would mean nothing'
		else
			denials=$(trace_denials "$ARMS_TRACE")
		fi
	elif ! session_reported "$outside/probe.err"; then
		found=1
		fail "$(printf 'nono said nothing about what the session was refused, so an empty set of denials would mean nothing:\n%s' \
			"$(tail -20 "$outside/probe.err")")"
	else
		denials=$(session_denials "$outside/probe.err" |
			{ grep -vxF -f <(session_denials "$ARMS_NOISE") || true; })
	fi

	if [ -n "$denials" ]; then
		found=1
		fail "$(printf 'producing the commits reached for something outside the session:\n%s' "$denials")"
	fi

	# Control. The same session is refused when the checkout's own
	# configuration demands a signature, so the success above belongs to a
	# session that reads the configuration it is given rather than to one that
	# reads none.
	if grep -qF 'DEMAND_RC :: 0' "$out"; then
		found=1
		fail "the same session commits even where the checkout demands a signature, so an unsigned commit says nothing about what was asked of it"
	fi

	[ "$found" -eq 0 ]
}

# R11 — a signature the session cannot produce is refused, loudly.
#
# The demand goes in the checkout's own `.git/config`, which is the only place
# it survives: GIT_CONFIG_GLOBAL points the toolchain at a file inside the
# project (D11), so a demand written to the host's global configuration is
# erased before the session ever sees it and the commit succeeds. That is the
# case FR-24 configures away, and it is not this one.
check_r11() {
	local outside out proj found=0
	local ARMS_PROJ ARMS_TRACE ARMS_NOISE
	local objects head message

	outside=$(outside_root r11) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	commit_session "$outside" || return 1
	out="$outside/probe.out"
	proj=$ARMS_PROJ

	# Control, and it comes first because everything below is about a failure.
	# The ordinary commit in the same session succeeded, so the refusal that
	# follows is attributable to the demand rather than to a session that
	# cannot write, cannot commit, or never started.
	if ! grep -qF 'PLAIN_RC :: 0' "$out"; then
		fail "$(printf 'the session cannot commit even where nothing demands a signature, so a refused signed commit proves nothing:\n%s' \
			"$(cat "$proj/plain.log" 2>/dev/null)")"
		return 1
	fi

	if grep -qF 'DEMAND_RC :: 0' "$out"; then
		fail "$(printf 'a checkout whose own configuration demands a signature committed anyway, so the session either signed with key material it should not reach or ignored the demand:\n%s' \
			"$(cat "$proj/demand.log" 2>/dev/null)")"
		return 1
	fi

	objects=$(sed -n 's/^DEMAND_OBJECTS :: //p' "$out")
	head=$(sed -n 's/^DEMAND_HEAD :: //p' "$out")
	if [ "$objects" != "0" ] || [ "$head" != "none" ]; then
		found=1
		fail "$(printf 'the refused commit left an object behind: %s object(s), HEAD %s' \
			"$objects" "$head")"
	fi

	# The message is matched for what it names — the act that could not be
	# performed and the material it needed — rather than for a string one
	# version of the toolchain happens to emit. A host carrying no signing
	# program says `cannot run gpg`; one where the program sits outside the
	# boundary says `cannot exec 'gpg': Permission denied`. Both name gpg, and
	# both say the data went unsigned, which is what keeps the failure from
	# reading as the checkout being unwritable.
	message=$(cat "$proj/demand.log" 2>/dev/null)
	if ! printf '%s' "$message" | grep -qi 'sign' ||
		! printf '%s' "$message" | grep -qiE 'gpg|key'; then
		found=1
		fail "$(printf 'the refusal does not name the key material it could not reach, so it reads as the checkout being unwritable:\n%s' \
			"$message")"
	fi

	[ "$found" -eq 0 ]
}

# Journey 2.1 for `opencode`, which M8c added to the agent table.
#
# The name is deliberately not a scenario identifier. `check_sc3` maps the
# spec's scenarios onto checks named `check_j<n>_<m>`, `check_r<n>` and
# `check_rep<n>`, and Journey 2.1 already has `check_j2_1`. A second check
# claiming the same identifier would either collide or invent a scenario the
# spec does not carry; this one extends the journey to the second agent
# instead, and stays out of the bijection.
#
# What it asserts, and why in this shape:
#
#   * `opencode debug paths` is the agent's own answer about where it will
#     write, so the roots are read from the agent rather than from the list of
#     variables this environment set. M8c measured that eight of the nine
#     follow the four `XDG_*` roots plus `TMPDIR`, which the confinement
#     already places under the working directory, and that none of the 84
#     `OPENCODE_*` names in the binary moves any of them. Asserting the
#     variables would therefore assert this environment's own intent back at
#     itself; asserting the agent's answer catches a root that stops following
#     them.
#
#   * The ninth root, `home`, *is* `$HOME`. No variable relocates it, so it is
#     asserted to lie outside the project and the home directory is required to
#     come through the session unchanged — the same property `check_j2_1`
#     asserts for the reference agent.
#
#   * `opencode providers list` names the environment variable it found and
#     counts the credentials it has stored. M8c measured that this agent reads
#     `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL` straight from its
#     environment, which is exactly the pair the mediated route injects, so a
#     session that is handed the route reports one environment variable and
#     zero stored credentials. Zero stored is the half that matters for D14:
#     the credential arrived by the route, not from a store this environment
#     would have had to grant.
#
#   * The session starts at all with the skill-surface file already in the state
#     the agent leaves it in. That is not a detail: M9a found every entry point
#     unable to start after its own first run, and nothing in this suite saw it,
#     because every check began from a project where the file did not exist yet.
#     The fixture below seeds it instead of hoping a subcommand persists it,
#     which was measured to depend on which subcommand ran.
check_opencode() {
	local agent=opencode binary=opencode
	local entry outside home proj cfg state project rc real surface
	local root value homeroot='' found=0
	local -a rooted=() strayed=() landed=() changed=()

	session_fixture "$agent" || return 1
	entry=$(pinned_bin "$binary") || return 1

	# Sibling of the fake home, never beneath it: the description carries
	# $HOME-relative deny rules, and a granted directory under the home is
	# unenforceable.
	outside=$(outside_root opencode) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	home="$outside/home"
	proj="$outside/proj"
	cfg="$outside/cfg"
	state="$outside/state"
	mkdir -p "$home" "$proj" "$cfg"
	session_env "$state"
	project=$(cd "$proj" && pwd -P)

	# Where this check captures what the session prints, inside the project
	# because that is the one place the session is granted. A program resolves
	# the paths of the descriptors it inherits when it starts, and Seatbelt
	# answers by path, so a capture file the session is granted nothing on is
	# reported as a refused read before the agent has run — which is how this
	# agent and `pi` died on macOS while `claude-code`, whose runtime does not
	# ask, went on capturing to the same place unharmed. Landlock never
	# re-checks a descriptor that is already open, so Linux cannot see it.
	capture="$project/.capture"
	mkdir -p "$capture"

	# The home already carries this agent's roots, for the reason `check_j2_1`
	# records: with nothing there, a session that lost its relocation writes
	# nowhere and the diff below stays empty for the wrong reason.
	mkdir -p "$home/.config/opencode" "$home/.local/share/opencode"
	printf '{}\n' >"$home/.config/opencode/opencode.json"

	# The project already holds the skill-surface file, in the state a session
	# leaves it in. This agent edits its configuration through a JSONC editor,
	# and inserting a key into an empty object leaves a trailing comma behind,
	# so the file the first start wrote as `{}` comes back as `{…,}` — legal for
	# the agent, unreadable to `jq`, and fatal to every start after the first.
	# Seeded here rather than produced by running a session twice, because which
	# subcommand persists the schema was measured to vary; the state is the
	# subject, and how the agent arrives at it is not.
	#
	# The path comes from the agent table, so moving the surface moves this too.
	surface=$(nix eval --raw "$REPO_ROOT#agents.$agent.skillSurface.path" \
		--apply "f: f \"$project\"") || return 1
	mkdir -p "$(dirname "$surface")"
	# `$schema` is the agent's own key name and stays literal.
	# shellcheck disable=SC2016
	printf '{\n  "$schema": "https://opencode.ai/config.json",}\n' >"$surface"

	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/before"

	# A credential in the calling environment, so the mediated route has
	# something to substitute. The value is a canary: it must not survive into
	# anything the session prints.
	real="sk-ant-real-canary-$RANDOM$RANDOM"

	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" "ANTHROPIC_API_KEY=$real" \
		env -C "$proj" "$entry/$binary" debug paths \
		>"$capture/paths.out" 2>"$capture/paths.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the agent did not answer where it writes (exit %s):\n%s' \
			"$rc" "$(tail -20 "$capture/paths.err")")"
		return 1
	fi

	# Two columns, name then absolute path, one root per line.
	while read -r root value; do
		[ -n "$value" ] || continue
		if [ "$root" = home ]; then
			homeroot=$value
			continue
		fi
		case "$value" in
		"$project"/*) rooted+=("$root") ;;
		*) strayed+=("$root=$value") ;;
		esac
	done < <(grep -E '^[a-z]+[[:space:]]+/' "$capture/paths.out")

	if [ "${#rooted[@]}" -eq 0 ]; then
		found=1
		fail "$(printf 'the agent reported no root under the project, so nothing was asserted:\n%s' \
			"$(head -12 "$capture/paths.out")")"
	fi
	if [ "${#strayed[@]}" -gt 0 ]; then
		found=1
		fail "$(printf 'the agent will write outside the project:\n%s' \
			"$(printf '%s\n' "${strayed[@]}")")"
	fi

	# The one root that is $HOME itself. It cannot be moved, so the assertion
	# is that it stays outside the project rather than that it lands inside.
	if [ -z "$homeroot" ]; then
		found=1
		fail 'the agent reported no home root, so the one root no variable can move went unobserved'
	else
		case "$homeroot" in
		"$project" | "$project"/*)
			found=1
			fail "the agent's home root resolved inside the project ($homeroot), so this session proves nothing about a home it cannot reach"
			;;
		esac
	fi

	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" "ANTHROPIC_API_KEY=$real" \
		env -C "$proj" "$entry/$binary" providers list \
		>"$capture/providers.out" 2>"$capture/providers.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		found=1
		fail "$(printf 'the agent could not report its providers (exit %s):\n%s' \
			"$rc" "$(tail -20 "$capture/providers.err")")"
	else
		# The variable the mediated route injects, named by the agent itself.
		if ! grep -qE 'Anthropic.*ANTHROPIC_API_KEY' "$capture/providers.out"; then
			found=1
			fail "$(printf 'the agent found no provider credential in its environment, so the mediated route did not reach it:\n%s' \
				"$(cat "$capture/providers.out")")"
		fi
		# And nothing stored, which is the half D14 is about: the credential
		# came from the route rather than from a store this environment would
		# have had to grant. A non-zero count here would mean the session read
		# an authentication file, and the only one on this machine belongs to
		# the other agent.
		if ! grep -q '0 credentials' "$capture/providers.out"; then
			found=1
			fail "$(printf 'the agent reported stored credentials, so it read an authentication store rather than taking the mediated route:\n%s' \
				"$(cat "$capture/providers.out")")"
		fi
		if grep -qF "$real" "$capture/providers.out" "$capture/providers.err"; then
			found=1
			fail 'the credential the supervisor holds was printed by the session, so it crossed the boundary unsubstituted'
		fi
	fi

	# The control: without state in the project, an unchanged home proves
	# nothing. It accumulates rather than returning, because a lost relocation
	# breaks the control and the subject at once. The capture directory is this
	# check's own doing and would make the control true whatever the session
	# did, so it is not counted; `-not -path` takes a pattern rather than a
	# regular expression, which is the form BSD find has too.
	mapfile -t landed < <(find "$project" -mindepth 1 \
		-not -path "$capture" -not -path "$capture/*" 2>/dev/null | sort)
	if [ "${#landed[@]}" -eq 0 ]; then
		found=1
		fail "the session wrote nothing inside the project, so an unchanged home directory would prove nothing"
	fi

	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/after"
	mapfile -t changed < <(comm -13 "$outside/before" "$outside/after" | cut -f1)
	if [ "${#changed[@]}" -gt 0 ]; then
		found=1
		fail "$(printf 'the session changed the home directory:\n%s' \
			"$(printf '%s\n' "${changed[@]}")")"
	fi

	# And the file is this environment's own product afterwards rather than the
	# JSONC it was seeded with, which is what `skillSurface.owned` is for: the
	# state the agent left is discarded on the next start instead of being
	# merged into. Asserting it parses is asserting the start after this one
	# reaches the agent — the property the two sessions above cannot show,
	# because they succeeded before the file was rewritten.
	if ! jq -e . "$surface" >/dev/null 2>&1; then
		found=1
		fail "$(printf 'the skill-surface file is not valid JSON after a session, so the next start cannot read it:\n%s\n%s' \
			"$surface" "$(cat "$surface")")"
	fi

	[ "$found" -eq 0 ]
}

# Journey 2.1 for `pi`, plus FR-22. Out of the bijection for check_opencode's
# reason: Journey 2.1 already has check_j2_1, and FR-22 carries no scenario of
# its own.
#
# What it asserts, and why in this shape:
#
#   * Relocation is read from what the session wrote, not from the variable
#     this environment set. `pi` has no `debug paths` to interrogate, so the
#     observable is the files themselves: M8d measured `auth.json` and
#     `models-store.json` appearing directly in the relocated root and nothing
#     landing anywhere else. Asserting PI_CODING_AGENT_DIR's value instead
#     would assert this environment's intent back at itself, and
#     `check_confinement_validates` already does that for every entry in the
#     table.
#
#   * `pi auth check --provider anthropic --json --credentials` prints the
#     credential the agent resolved, verbatim. That is a stronger observation
#     than the other two agents allow: rather than inferring from a provider
#     listing that a credential arrived, this reads the value the agent is
#     holding and asserts it is the supervisor's substitute and not the real
#     key. D14 sketched a `providers.<id>.baseUrl` in a file this environment
#     writes; M8d measured the bundled SDK defaulting `baseURL` from
#     ANTHROPIC_BASE_URL and `apiKey` from ANTHROPIC_API_KEY, which is exactly
#     the pair the mediated route injects, so no file is written and none is
#     asserted here.
#
#   * FR-22 is the absence of a thing, which is how spec.md frames it: this
#     environment declares no `pi` package, so the startup that would install
#     missing ones has nothing to install and reaches no registry. `pi list`
#     is the agent's own answer to that, and the relocated root is checked for
#     the npm tree an install would have left. Neither asserts that a session
#     *cannot* fetch — M8d measured the confinement's proxy carrying arbitrary
#     HTTPS, so it can, and the handbook records that.
check_pi() {
	local agent=pi binary=pi
	local entry outside home proj cfg state project capture rc real root cred
	local found=0
	local -a landed=() changed=() strayed=()

	session_fixture "$agent" || return 1
	entry=$(pinned_bin "$binary") || return 1

	outside=$(outside_root pi) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	home="$outside/home"
	proj="$outside/proj"
	cfg="$outside/cfg"
	state="$outside/state"
	mkdir -p "$home" "$proj" "$cfg"
	session_env "$state"
	project=$(cd "$proj" && pwd -P)

	# Inside the project, for the reason `check_opencode` records: this agent's
	# runtime asks what the descriptors it inherited are called, and a capture
	# it is granted nothing on is refused before it starts.
	capture="$project/.capture"
	mkdir -p "$capture"

	# The home carries the root this agent falls back to when the relocation is
	# lost — `$HOME/.pi/agent`, which M8d read out of the binary as the sole
	# default. Populated for check_j2_1's reason: with nothing there, a session
	# that lost its relocation writes nowhere the diff below would notice.
	mkdir -p "$home/.pi/agent"
	printf '{}\n' >"$home/.pi/agent/auth.json"

	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/before"

	real="sk-ant-real-canary-$RANDOM$RANDOM"
	root="$project/.agents/pi"

	# One invocation carries both the credential arm and the relocation arm: it
	# is the call that makes the agent resolve a provider, and resolving one is
	# what makes it write its stores.
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" "ANTHROPIC_API_KEY=$real" \
		env -C "$proj" "$entry/$binary" auth check --provider anthropic --json --credentials \
		>"$capture/auth.out" 2>"$capture/auth.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the agent reports its anthropic credential is unusable (exit %s):\n%s\n%s' \
			"$rc" "$(cat "$capture/auth.out")" "$(tail -20 "$capture/auth.err")")"
		return 1
	fi

	if [ "$(jq -r '.status // ""' "$capture/auth.out")" != ready ]; then
		found=1
		fail "$(printf 'the agent does not consider the mediated route usable:\n%s' \
			"$(cat "$capture/auth.out")")"
	fi
	if [ "$(jq -r '.authType // ""' "$capture/auth.out")" != api_key ]; then
		found=1
		fail "$(printf 'the agent resolved the credential by some route other than the injected key:\n%s' \
			"$(cat "$capture/auth.out")")"
	fi

	# The value the agent is holding. FR-6: 64 hex characters minted for this
	# session, and not the key the supervisor read out of its own environment.
	cred=$(jq -r '.credentials // ""' "$capture/auth.out")
	if ! printf '%s' "$cred" | grep -qE '^[0-9a-f]{64}$'; then
		found=1
		fail "the credential the agent holds is not a per-session substitute: ${cred:+${#cred} characters, }not 64 hex"
	fi
	if [ "$cred" = "$real" ] || grep -qF "$real" "$capture/auth.out" "$capture/auth.err"; then
		found=1
		fail 'the credential the supervisor holds reached the session unsubstituted'
	fi

	# FR-22, asked the only way that is not vacuous: something has to want
	# installing. A declaration this environment did not provision is planted in
	# the settings the session reads, because M8d measured that a declared
	# package is what the agent installs on startup — with PI_OFFLINE it lists
	# the declaration and fetches nothing, without it the startup runs a real
	# `npm install` and the tree appears. Asserting no package tree in a session
	# that was asked to install none would assert nothing at all.
	printf '{"packages":["npm:left-pad"]}\n' >"$root/settings.json"
	env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$cfg" "ANTHROPIC_API_KEY=$real" \
		env -C "$proj" "$entry/$binary" list \
		>"$capture/list.out" 2>"$capture/list.err" && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		found=1
		fail "$(printf 'the agent could not report its packages (exit %s):\n%s' \
			"$rc" "$(tail -20 "$capture/list.err")")"
	elif ! grep -qF 'npm:left-pad' "$capture/list.out"; then
		# The control. If the agent did not read the declaration, an absent
		# package tree says only that nothing asked to be fetched.
		found=1
		fail "$(printf 'the agent did not read the planted package declaration, so finding nothing installed proves nothing:\n%s' \
			"$(cat "$capture/list.out")")"
	fi
	# The subject: the declaration went unfulfilled. A package this environment
	# did not provision stays unprovisioned, whatever the session was asked for.
	mapfile -t strayed < <(find "$root" -maxdepth 3 -name node_modules 2>/dev/null | sort)
	if [ "${#strayed[@]}" -gt 0 ]; then
		found=1
		fail "$(printf 'the session installed a package that was declared but never provisioned through nix, so it fetched code from inside the boundary:\n%s' \
			"$(printf '%s\n' "${strayed[@]}")")"
	fi

	# Relocation, observed. The store the agent writes when it resolves a
	# provider is the one M8d measured, and it is under the working directory.
	if [ ! -f "$root/auth.json" ]; then
		found=1
		fail "$(printf 'the agent wrote no credential store under %s, so its state did not follow the relocation:\n%s' \
			"$root" "$(find "$project" -mindepth 1 2>/dev/null | head -12)")"
	fi

	# The control, for check_opencode's reason: without state in the project, an
	# unchanged home proves nothing, and this check's own capture directory is
	# not state the session wrote.
	mapfile -t landed < <(find "$project" -mindepth 1 \
		-not -path "$capture" -not -path "$capture/*" 2>/dev/null | sort)
	if [ "${#landed[@]}" -eq 0 ]; then
		found=1
		fail "the session wrote nothing inside the project, so an unchanged home directory would prove nothing"
	fi

	find "$home" -printf '%p\t%s\t%T@\n' | sort >"$outside/after"
	mapfile -t changed < <(comm -13 "$outside/before" "$outside/after" | cut -f1)
	if [ "${#changed[@]}" -gt 0 ]; then
		found=1
		fail "$(printf 'the session changed the home directory:\n%s' \
			"$(printf '%s\n' "${changed[@]}")")"
	fi

	[ "$found" -eq 0 ]
}
# A manifest of a directory tree, precise enough that "unchanged" means it.
#
# Names, types and modes, and the content of every file. Timestamps are left
# out on purpose: a check that reads them cannot tell a rewrite that preserved
# the bytes from a touch, and it is the bytes the consumer cares about.
tree_manifest() {
	find "$1" -mindepth 1 \( -type f -o -type d -o -type l \) -printf '%y\t%m\t%p\n' | sort
	find "$1" -type f -exec sha256sum {} + | sort -k2
}

# The path each agent would read the surface at, as the agent table describes
# it. Derived rather than written down, because the two mechanisms M8e measured
# differ in where the read lands: an agent pointed at the host directory opens
# the host path, and an agent pointed by a symlink under its own configuration
# root opens that path instead. Prints one path per skill name given.
surface_reads() {
	local agent=$1 project=$2 kind root name
	shift 2
	kind=$(nix eval --raw "$REPO_ROOT#agents.$agent.skillSurface.kind") || return 1
	case $kind in
	symlink-children)
		# One link per child of a declared directory, under the agent's own
		# configuration root, so the read lands on the link's path.
		root=$(nix eval --raw "$REPO_ROOT#agents.$agent.skillSurface.path" \
			--apply "f: f \"$project\"") || return 1
		for name; do printf '%s/%s/SKILL.md\n' "$root" "${name##*/}"; done
		;;
	json-array)
		# Pointed at the declared directory itself, so the read is the
		# consumer's own path, given here already qualified.
		for name; do printf '%s/SKILL.md\n' "$name"; done
		;;
	*)
		return 1
		;;
	esac
}

# Journey 8.1. The one host path a session reads on purpose.
#
# The property is a conjunction whose halves fail differently, so both are
# asserted for every agent in the table: the declared surface *arrives* — the
# agent opens the file the consumer wrote, from inside the boundary — and
# nothing else does, neither an ancestor of what was declared nor a sibling
# beside it.
#
# The grant is read off the capability set the session prints for itself, and
# what it read is read off a syscall trace of the shipped entry point rather
# than each agent's own listing command, because M8f measured that only one of
# the three has one. Both observe what the wrapper did rather than what it was
# asked to do.
#
# The two halves are not observable on the same platforms. Every session prints
# its capability set, so the grant is asserted everywhere. A successful read is
# a different matter: Landlock reports nothing to nono, so Linux traces the
# syscall, and on macOS there is no observation to be had at all — dtruss needs
# SIP disabled, fs_usage needs root, and nono reports refusals and grants but
# never a read that went through. So the arrival of the surface, and the
# absence of the neighbour beside it, are skipped there with the reason said
# out loud rather than asserted from something weaker. docs/HANDBOOK.md carries
# that gap; research.md § M9e carries what was measured to establish it.
#
# Two traps, both recorded in research.md § M8f. `-s 4096`, because strace
# truncates strings at 32 characters by default and every path here is longer
# than that. And the successful-open pattern excludes O_PATH, which needs no
# read permission and so succeeds whether the grant is there or not.
check_j8_1() {
	local outside home host proj agent binary entry strace_bin nono_bin
	local canary want stray trace rc project i opened wrote skipped=''
	local found=0
	local -a table=() binaries=() declared=() invocation=() expect=() control=() digests=() grant=() traced=()
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV
	local system

	system=$(nix eval --impure --raw --expr builtins.currentSystem) || {
		fail 'the current system does not resolve, so no entry point can be named'
		return 1
	}
	if ! mapfile -t table < <(nix eval --json "$REPO_ROOT#agents" \
		--apply builtins.attrNames | jq -r '.[]'); then
		fail 'the agent table does not evaluate, so there is no set to assert the property over'
		return 1
	fi
	# The command each agent answers to, read off the entry points the flake
	# builds. Keyed the same way, so one list indexes the other.
	if ! mapfile -t binaries < <(nix eval --json "$REPO_ROOT#agentBinaries.$system" |
		jq -r 'to_entries | sort_by(.key) | .[].value'); then
		fail 'the entry point names do not evaluate, so no agent can be started'
		return 1
	fi
	# Anti-vacuity: a property over an empty table holds by matching nothing.
	if [ "${#table[@]}" -eq 0 ] || [ "${#table[@]}" -ne "${#binaries[@]}" ]; then
		fail "the agent table has ${#table[@]} entries and ${#binaries[@]} commands, so there is no set to assert the property over"
		return 1
	fi

	nono_bin=$(pinned_bin nono) || return 1

	outside=$(outside_root j8_1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	# The home is a sibling of the project rather than its parent, per
	# check_r1: the description carries $HOME-relative deny rules and nono
	# refuses to start on a workdir that overlaps one.
	home="$outside/home"
	host="$outside/host"
	proj="$outside/proj"
	mkdir -p "$home" "$proj"
	session_env "$outside/state"
	project=$(cd "$proj" && pwd -P)

	# Two declared directories rather than one, so "each declared directory is
	# named in its own right" is distinguishable from "something containing
	# both is named", and a third beside them that is never declared. The
	# canary is per run, so nothing an earlier run left behind can satisfy any
	# of this.
	canary="surface-canary-$RANDOM$RANDOM"
	declared=("$host/alpha" "$host/beta")
	mkdir -p "${declared[0]}/one" "${declared[1]}/two" "$host/undeclared/three"
	printf -- '---\nname: one\ndescription: %s, the first declared surface\n---\n\n%s-one\n' \
		"$canary" "$canary" >"${declared[0]}/one/SKILL.md"
	printf -- '---\nname: two\ndescription: %s, the second declared surface\n---\n\n%s-two\n' \
		"$canary" "$canary" >"${declared[1]}/two/SKILL.md"
	printf -- '---\nname: three\ndescription: %s, never declared\n---\n\n%s-three\n' \
		"$canary" "$canary" >"$host/undeclared/three/SKILL.md"

	tree_manifest "$host" >"$outside/before"
	# What a copy of the surface would look like, wherever it landed.
	mapfile -t digests < <(sha256sum \
		"${declared[0]}/one/SKILL.md" "${declared[1]}/two/SKILL.md" |
		cut -d' ' -f1)

	for ((i = 0; i < ${#table[@]}; i++)); do
		agent=${table[i]}
		binary=${binaries[i]}
		entry=$(pinned_bin "$binary") || return 1
		session_fixture "$agent" || return 1
		strace_bin=$(substrate_member "$FIXTURE_SUBSTRATE" strace) || strace_bin=
		if ! mapfile -t expect < <(surface_reads "$agent" "$project" \
			"${declared[0]}/one" "${declared[1]}/two"); then
			fail "the agent table does not say where $agent reads a declared surface, so its arrival cannot be observed"
			return 1
		fi
		if ! mapfile -t control < <(surface_reads "$agent" "$project" \
			"$host/undeclared/three"); then
			fail "the agent table does not say where $agent reads a declared surface, so a wider one cannot be ruled out"
			return 1
		fi

		# Discovery has to be forced: M8e measured that a cheap invocation
		# never reaches it. Print mode does, and the authentication failure
		# that follows is the signal that it got there. `debug skill` is
		# opencode's own, and reaches discovery without a request.
		case $binary in
		opencode) invocation=(debug skill) ;;
		claude | pi) invocation=(-p hi) ;;
		*)
			fail "no invocation is known to make $binary discover its skills, so the arrival of the surface cannot be observed"
			return 1
			;;
		esac

		# The tracer wraps the session where there is one. Where there is
		# none the session still runs, because the grant it was given is
		# observable from its own stderr and only the two arms that need a
		# syscall are lost.
		trace="$outside/trace.$agent"
		traced=()
		if [ -n "$strace_bin" ]; then
			traced=("$strace_bin/bin/strace" -ff -s 4096
				-e "trace=openat,execve" -o "$trace.")
		fi
		env "${SESSION_ENV[@]}" "HOME=$home" "XDG_CONFIG_HOME=$outside/cfg" \
			"ANTHROPIC_API_KEY=sk-ant-canary-$RANDOM$RANDOM" \
			"AGENT_SANDBOX_SKILLS=${declared[0]}:${declared[1]}" \
			env -C "$proj" "${traced[@]}" \
			"$entry/$binary" "${invocation[@]}" \
			>"$outside/out.$agent" 2>"$outside/err.$agent" && rc=0 || rc=$?

		# One file per traced process, joined afterwards. Tracing into a
		# single file instead is what made this check flake: a shared stream
		# interleaves concurrent processes, so strace splits a syscall into an
		# `<unfinished ...>` line and a `<... resumed>` line and the path
		# stops sharing a line with its return value. Whether that happened to
		# any particular openat was a matter of scheduling.
		cat "$trace".* >"$trace" 2>/dev/null || :

		# What the session was granted, read off the capability set nono
		# prints before the program runs. This is the control the trace's
		# existence used to be for the arms below it: a capability set is
		# printed only by a session that started, so an empty one means
		# nothing was observed rather than that nothing was granted.
		granted_reach "$outside/err.$agent" >"$outside/reach.$agent"
		if [ ! -s "$outside/reach.$agent" ]; then
			found=1
			fail "$(printf 'the %s session printed no capability set (exit %s), so what it was granted cannot be observed:\n%s' \
				"$agent" "$rc" "$(tail -n 5 "$outside/err.$agent")")"
			continue
		fi
		if [ -n "$strace_bin" ] && [ ! -s "$trace" ]; then
			found=1
			fail "$(printf 'the %s session produced no trace (exit %s), so it observes nothing:\n%s' \
				"$agent" "$rc" "$(tail -n 5 "$outside/err.$agent")")"
			continue
		fi

		# The surface arrives. Each declared directory separately, so one of
		# them arriving cannot stand in for the other.
		#
		# This is the one arm no instrument on macOS can carry: a successful
		# read leaves no trace there. dtruss needs SIP disabled, fs_usage
		# needs root, nono's trailer reports refusals only and its audit
		# trail reports grants only, so there is nothing to read a
		# successful open out of. Rather than assert something weaker under
		# the same name, the arm is skipped and the check says so.
		if [ -n "$strace_bin" ]; then
			for want in "${expect[@]}"; do
				opened=$(grep -F -- "\"$want\", O_RDONLY|O_NOCTTY" "$trace" |
					grep -cE '\) = [0-9]+$') || opened=0
				if [ "$opened" -eq 0 ]; then
					found=1
					fail "$(printf 'the %s session never read the declared surface at %s (exit %s), so it did not arrive' \
						"$agent" "$want" "$rc")"
				fi
			done
		else
			skipped="the substrate for $agent provides no strace, and a successful read leaves no observation on this platform, so the arrival of the declared surface and the absence of its neighbours are not asserted here"
		fi

		# The grant the wrapper made: each declared directory readable in its
		# own right, no ancestor of either, and none of them writable.
		#
		# Asserted per path rather than as a whole set, because the
		# capability set is everything the session was granted — the
		# execution substrate and the project among it — while what this
		# check is about is the surface.
		for want in "${declared[@]}"; do
			if ! reach_grants "$outside/reach.$agent" "$want" 'r'; then
				found=1
				fail "$(printf 'the %s session was not granted the declared surface at %s, so it cannot arrive:\n%s' \
					"$agent" "$want" "$(cat "$outside/reach.$agent")")"
			fi
			if reach_grants "$outside/reach.$agent" "$want" 'w'; then
				found=1
				fail "the $agent session was granted write to the declared surface at $want, so the surface is handed over rather than lent"
			fi
		done
		for want in "$host" "$host/undeclared" "$host/undeclared/three"; do
			if reach_grants "$outside/reach.$agent" "$want" '.'; then
				found=1
				fail "the $agent session was granted $want, which the consumer did not declare, so what arrives is wider than what was declared"
			fi
		done

		# Nothing beside the declaration arrives. Not vacuous: a wrapper that
		# pointed the agent at the declared directories' common parent would
		# satisfy every assertion above and pull this one in as well.
		if [ -n "$strace_bin" ]; then
			for want in "${control[@]}"; do
				if grep -qF -- "\"$want\", O_RDONLY|O_NOCTTY" "$trace"; then
					found=1
					fail "the $agent session read an undeclared skill beside the surface at $want, so what arrives is wider than what was declared"
				fi
			done
		fi

		# Pointed at, not copied (P8). By digest rather than by searching for
		# the canary text, because an agent that loaded the skill records its
		# description in its own transcript, and a transcript is the session's
		# work rather than a copy of the surface. `find -type f` does not
		# follow symlinks, so the link the symlink-children mechanism plants
		# is correctly not counted as one either.
		stray=$(find "$project" -type f -exec sha256sum {} + 2>/dev/null |
			grep -Ff <(printf '%s\n' "${digests[@]}") - || true)
		if [ -n "$stray" ]; then
			found=1
			fail "$(printf 'the %s session has the surface copied into the project rather than pointed at:\n%s' \
				"$agent" "$stray")"
		fi

		# Lent, not handed over — and observed by trying rather than by
		# hoping. The comparison after the loop cannot tell a read-only
		# grant from a read-write one unless something in a session actually
		# attempts the write, so one session does. The mode replayed here is
		# the one the wrapper's own session reported being granted, not a
		# mode recomputed from the declaration, so a wrapper that widened it
		# is caught here and not only by the arm above.
		grant=()
		for want in "${declared[@]}"; do
			case $(awk -v p="$want" '$2 == p { print $1 }' "$outside/reach.$agent") in
			'r+w') grant+=(--allow "$want") ;;
			w) grant+=(--write "$want") ;;
			r) grant+=(--read "$want") ;;
			esac
		done
		wrote=$(env "${SESSION_ENV[@]}" "HOME=$home" \
			env -C "$proj" "$nono_bin/nono" run \
			--profile "$FIXTURE_PROFILE" --workdir "$project" --allow-cwd \
			"${grant[@]}" -- "$FIXTURE_BASH/bin/bash" -c \
			"printf tainted >'${declared[0]}/one/SKILL.md' && echo WROTE || echo DENIED" \
			2>/dev/null | tail -n 1)
		if [ "$wrote" != DENIED ]; then
			found=1
			fail "the grant the $agent entry point passes let a session write to the declared surface ($wrote), so the surface is handed over rather than lent"
		fi
	done

	# Lent, not handed over. Once, after every session: the surface is one
	# host tree and any of them writing to it is the same violation.
	tree_manifest "$host" >"$outside/after"
	if ! diff -q "$outside/before" "$outside/after" >/dev/null; then
		found=1
		fail "$(printf 'the declared surface changed across the sessions that read it:\n%s' \
			"$(diff "$outside/before" "$outside/after")")"
	fi

	[ "$found" -eq 0 ] || return 1

	# Everything observable here held. Reported as a skip rather than a pass
	# where an arm could not be observed at all, so the strongest half of the
	# property does not quietly read as asserted.
	if [ -n "$skipped" ]; then
		printf '%s\n' "$skipped"
		return "$SKIP_STATUS"
	fi
}

# Which of the given paths a session can actually read, under a given grant.
#
# The grant is passed as the flags the entry point itself built, terminated by
# `--`, so what is exercised is the reach the shipped wrapper asked for rather
# than the reach this check would have preferred to see. Reads with bash's own
# redirection because the enumerated substrate carries no cat, and requires the
# content to be non-empty so a path that exists but yields nothing cannot pass
# for a readable one. Prints the readable paths, sorted.
#
# Each answer is marked and the marker stripped again, because nono writes its
# own diagnostics to stdout rather than stderr: measured, a session started
# without a resolvable credential prints a `Credential not found for route`
# warning that would otherwise be indistinguishable from a readable path and
# would land in the difference set as though the surface had brought it.
session_readable() {
	local nono=$1 profile=$2 bash_path=$3 project=$4 home_dir=$5
	local -a grant=()
	shift 5
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		grant+=("$1")
		shift
	done
	[ "${1:-}" = -- ] || return 1
	shift
	# The probe body runs inside the session, so it is deliberately unexpanded
	# here.
	# shellcheck disable=SC2016
	env "${SESSION_ENV[@]}" "HOME=$home_dir" \
		env -C "$project" "$nono" run --profile "$profile" \
		--workdir "$project" --allow-cwd "${grant[@]+"${grant[@]}"}" -- \
		"$bash_path" -c \
		'for p in "$@"; do if { v=$(<"$p"); } 2>/dev/null && [ -n "$v" ]; then printf "READABLE\t%s\n" "$p"; fi; done' \
		probe "$@" 2>/dev/null | sed -n 's/^READABLE\t//p' | sort
}

# R9. Journey 8's harder half: reaching for the surface must not drag in the
# installation it sits inside.
#
# A grant that brings the declared surface *and* something else satisfies
# check_j8_1 completely, so no single observation can carry this. The property
# is a difference: the same planted home directory is used twice, once with the
# surface declared and once without, and the readable sets are subtracted. What
# the declaration is responsible for is exactly what appears in one and not the
# other, and that difference is asserted equal to the declaration in both
# directions — nothing missing, and nothing extra.
#
# The reach is observed by reading, not by reasoning about the grant: each arm
# replays the capability set its session printed for itself and asks a process
# under that set which of the planted paths it can actually open.
#
# The grant is read off that capability set rather than off the wrapper's execve
# line, because a syscall trace is Landlock-only and this property holds on
# every platform. It is also the wider observation of the two: argv carries the
# flags the wrapper built, while the capability set carries everything the
# session ended up with, the profile's own grants included.
#
# The self-referential case M1e found gets its own arm. A host confinement
# description sitting in the same home directory must take no part in deciding
# what the session may reach, so the grant is compared against a run made with
# that description deleted. Equal grants is the only outcome that means the
# boundary was decided inside the repository.
check_r9() {
	local outside home proj agent binary entry nono_bin
	local project i rc want canary got missing extra arm surface mode
	local found=0
	local -a table=() binaries=() invocation=() declared=() probe=() secrets=()
	local -a grant=()
	local FIXTURE_PROFILE FIXTURE_SUBSTRATE FIXTURE_BASH
	local -a SESSION_ENV
	local system

	system=$(nix eval --impure --raw --expr builtins.currentSystem) || {
		fail 'the current system does not resolve, so no entry point can be named'
		return 1
	}
	if ! mapfile -t table < <(nix eval --json "$REPO_ROOT#agents" \
		--apply builtins.attrNames | jq -r '.[]'); then
		fail 'the agent table does not evaluate, so there is no set to assert the property over'
		return 1
	fi
	if ! mapfile -t binaries < <(nix eval --json "$REPO_ROOT#agentBinaries.$system" |
		jq -r 'to_entries | sort_by(.key) | .[].value'); then
		fail 'the entry point names do not evaluate, so no agent can be started'
		return 1
	fi
	if [ "${#table[@]}" -eq 0 ] || [ "${#table[@]}" -ne "${#binaries[@]}" ]; then
		fail "the agent table has ${#table[@]} entries and ${#binaries[@]} commands, so there is no set to assert the property over"
		return 1
	fi

	nono_bin=$(pinned_bin nono) || return 1

	outside=$(outside_root r9) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	home="$outside/home"
	proj="$outside/proj"
	mkdir -p "$proj"
	session_env "$outside/state"
	project=$(cd "$proj" && pwd -P)

	# A home directory that already configures these agents for every project,
	# which is R9's Given. Two declared skill directories and a third beside
	# them under the same parent, so a declaration widened to their common
	# ancestor is distinguishable from one that names each in its own right.
	canary="host-canary-$RANDOM$RANDOM"
	declared=("$home/skills/alpha" "$home/skills/beta")
	mkdir -p "${declared[0]}/one" "${declared[1]}/two" "$home/skills/gamma/three" \
		"$home/.claude/projects/p" "$home/.pi/agent/sessions" \
		"$home/.config/nono/profiles"
	printf -- '---\nname: one\ndescription: %s, declared\n---\n\n%s-one\n' \
		"$canary" "$canary" >"${declared[0]}/one/SKILL.md"
	printf -- '---\nname: two\ndescription: %s, declared\n---\n\n%s-two\n' \
		"$canary" "$canary" >"${declared[1]}/two/SKILL.md"
	printf -- '---\nname: three\ndescription: %s, never declared\n---\n\n%s-three\n' \
		"$canary" "$canary" >"$home/skills/gamma/three/SKILL.md"

	# The three classes FR-21 keeps out, and the confinement description whose
	# reach would define the boundary from outside it.
	secrets=(
		"$home/.claude/.credentials.json"
		"$home/.claude/projects/p/history.jsonl"
		"$home/.pi/agent/sessions/state.jsonl"
		"$home/.config/nono/profiles/host.json"
	)
	printf '{"token":"%s-credential"}\n' "$canary" >"${secrets[0]}"
	printf '{"role":"user","text":"%s-history"}\n' "$canary" >"${secrets[1]}"
	printf '{"session":"%s-state"}\n' "$canary" >"${secrets[2]}"
	printf '{"meta":{"name":"%s-host"}}\n' "$canary" >"${secrets[3]}"

	# The control: something a session reaches in every arm regardless of the
	# declaration, so a session that read nothing at all cannot pass by having
	# an empty difference.
	printf '%s-project\n' "$canary" >"$proj/canary.txt"

	probe=(
		"${declared[0]}/one/SKILL.md"
		"${declared[1]}/two/SKILL.md"
		"$home/skills/gamma/three/SKILL.md"
		"${secrets[@]}"
		"$project/canary.txt"
	)
	# What the declaration is answerable for, and nothing else.
	want=$(printf '%s\n' "${declared[0]}/one/SKILL.md" "${declared[1]}/two/SKILL.md" | sort)

	for ((i = 0; i < ${#table[@]}; i++)); do
		agent=${table[i]}
		binary=${binaries[i]}
		entry=$(pinned_bin "$binary") || return 1
		session_fixture "$agent" || return 1
		case $binary in
		opencode) invocation=(debug skill) ;;
		claude | pi) invocation=(-p hi) ;;
		*)
			fail "no invocation is known to start $binary far enough to observe its reach"
			return 1
			;;
		esac

		# Both arms, then the same arm again with the host confinement
		# description deleted. Each writes its grant and its readable set.
		for arm in declared bare nohost; do
			case $arm in
			declared | nohost)
				surface="AGENT_SANDBOX_SKILLS=${declared[0]}:${declared[1]}"
				;;
			bare)
				surface=AGENT_SANDBOX_SKILLS=
				;;
			esac
			if [ "$arm" = nohost ]; then
				# Only the grant is read from this arm, so the cheapest
				# invocation that still reaches `exec nono run` will do.
				# Its stderr is kept all the same, because that is where
				# the session prints the grant.
				rm -rf "$home/.config/nono"
				env "${SESSION_ENV[@]}" "HOME=$home" \
					"XDG_CONFIG_HOME=$outside/cfg" "$surface" \
					env -C "$proj" \
					"$entry/$binary" --version \
					>/dev/null 2>"$outside/err.$agent.$arm" || :
				mkdir -p "$home/.config/nono/profiles"
				printf '{"meta":{"name":"%s-host"}}\n' "$canary" >"${secrets[3]}"
			else
				env "${SESSION_ENV[@]}" "HOME=$home" \
					"XDG_CONFIG_HOME=$outside/cfg" \
					"ANTHROPIC_API_KEY=sk-ant-canary-$RANDOM$RANDOM" \
					"$surface" \
					env -C "$proj" \
					"$entry/$binary" "${invocation[@]}" \
					>"$outside/out.$agent.$arm" 2>"$outside/err.$agent.$arm" &&
					rc=0 || rc=$?
			fi

			# Two classes of line are dropped, because neither says
			# anything about the reach the description asked for and
			# both move between two runs of the same description.
			#
			# nono summarises part of its floor as `+ N system/group
			# paths`, and that count was measured reading 34 against
			# 33 for two sessions whose expanded sets were identical
			# apart from their own pids, so a comparison including it
			# reports a difference that is not one.
			#
			# The pid is the other: a session is granted its own
			# /proc/<pid>, which differs on every run by
			# construction.
			granted_reach "$outside/err.$agent.$arm" |
				awk '$1 != "+" && $2 !~ "^/proc/[0-9]+"' \
					>"$outside/grant.$agent.$arm"

			[ "$arm" = nohost ] && continue

			# The control, per arm: the session has to have started and got
			# somewhere. The pre-flight's own refusals are 77 and 78, and a
			# capability set is printed by a session that started, so an
			# empty one says nothing was observed rather than that nothing
			# was granted.
			if [ "$rc" = 77 ] || [ "$rc" = 78 ] ||
				[ ! -s "$outside/grant.$agent.$arm" ]; then
				found=1
				fail "$(printf 'the %s session did not start in the %s arm (exit %s), so its reach means nothing:\n%s' \
					"$agent" "$arm" "$rc" "$(tail -n 5 "$outside/err.$agent.$arm")")"
				continue
			fi

			# Replay the set the session reported, by mode. The modes that
			# carry no path flag are skipped: `x` and `net` are not grants
			# of a path to read, and `+` is nono summarising paths it did
			# not list, so there is no path to pass on.
			grant=()
			while read -r mode got _; do
				case $mode in
				'r+w') grant+=(--allow "$got") ;;
				w) grant+=(--write "$got") ;;
				r) grant+=(--read "$got") ;;
				esac
			done <"$outside/grant.$agent.$arm"
			session_readable "$nono_bin/nono" "$FIXTURE_PROFILE" \
				"$FIXTURE_BASH/bin/bash" "$project" "$home" \
				"${grant[@]+"${grant[@]}"}" -- "${probe[@]}" \
				>"$outside/readable.$agent.$arm"

			# Anti-vacuity for the difference: a probe that could read
			# nothing at all would subtract to the empty set and pass every
			# containment below.
			if ! grep -qxF -- "$project/canary.txt" "$outside/readable.$agent.$arm"; then
				found=1
				fail "the $agent session could not read its own project in the $arm arm, so nothing it could not read means anything"
			fi

			# FR-21, in both arms. Stored credentials, conversation history,
			# session state and the host's confinement description sit in the
			# same home directory as the surface and stay out of reach whether
			# the surface is declared or not.
			for got in "${secrets[@]}"; do
				if grep -qxF -- "$got" "$outside/readable.$agent.$arm"; then
					found=1
					fail "the $agent session read $got in the $arm arm, so declaring an authoring surface drags in the installation around it"
				fi
			done
		done

		# The difference, both directions. What one arm can read and the other
		# cannot is exactly what was declared.
		got=$(comm -13 "$outside/readable.$agent.bare" \
			"$outside/readable.$agent.declared")
		missing=$(comm -13 <(printf '%s\n' "$got") <(printf '%s\n' "$want"))
		extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))
		if [ -n "$missing" ]; then
			found=1
			fail "$(printf 'declaring the surface did not make these readable to %s:\n%s' \
				"$agent" "$missing")"
		fi
		if [ -n "$extra" ]; then
			found=1
			fail "$(printf 'declaring the surface also made these readable to %s:\n%s' \
				"$agent" "$extra")"
		fi

		# The self-referential case: the same declaration, with the host's own
		# confinement description gone, has to produce the same grant.
		if ! diff -q "$outside/grant.$agent.declared" \
			"$outside/grant.$agent.nohost" >/dev/null; then
			found=1
			fail "$(printf 'deleting the host confinement description changed what the %s session was granted, so configuration outside the boundary decided the boundary:\n%s' \
				"$agent" "$(diff "$outside/grant.$agent.declared" "$outside/grant.$agent.nohost")")"
		fi
	done

	[ "$found" -eq 0 ]
}
