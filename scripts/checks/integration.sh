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
#   4. /nix/store granted read, or the child cannot exec at all and exits 127.
#      The generated profile carries this as the leak registry's one entry.
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
	local outside home state project session registry rc out found=0
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

	# The property, from plan.md: granted ∖ floor = {the project} ∪ the registry.
	# Derived from the registry rather than restated, so a new entry moves both
	# sides at once and only a leak nobody wrote down can fail this.
	if ! diff -u \
		<({
			printf '%s\n' "$project"
			jq -r '.[].path' <<<"$registry"
		} | sort -u) \
		<(jq -r '.tracked_paths[]' "${sessions[0]}" | sort -u) \
		>"$outside/reach.diff" 2>&1; then
		found=1
		fail "$(printf 'the session reaches more or less than the project plus the leak registry:\n%s' \
			"$(sed '1,2d' "$outside/reach.diff")")"
	fi

	[ "$found" -eq 0 ]
}
