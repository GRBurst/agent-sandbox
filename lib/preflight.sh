# shellcheck shell=bash
#
# FR-10 / R6. The guard every agent entry point runs before it starts anything.
#
# Functional, not introspective (D5): it observes a denial rather than reading
# /sys/kernel/security/lsm or an ABI version, because a probe list written for
# one confinement mechanism proves nothing about the one actually in use.
#
# Sourced by scripts/checks/integration.sh and embedded into each wrapper by
# lib/confined-agent.nix. PREFLIGHT_PROFILE is the profile the agent will run
# under; the pre-flight deliberately does not have one of its own, because it
# asserts a property of the host and a second artefact would only be a second
# thing to keep true.

# The exit status is pinned because a caller branches on it (FR-10). The message
# names the missing primitive so the user is not left guessing.
die() {
	printf 'agent-sandbox: %s\n' "$2" >&2
	printf 'agent-sandbox: required: kernel-enforced filesystem confinement (Landlock >= 5.13 on Linux, Seatbelt on macOS).\n' >&2
	printf 'agent-sandbox: refusing to start an agent. There is no override.\n' >&2
	exit "$1"
}

# Four assertions, because P9 forbids letting "nono could not start" or "the
# canary was never writable" look like "the child was denied".
preflight_or_die() {
	local canary rc
	canary="${XDG_RUNTIME_DIR:-$HOME}/.agent-sandbox-preflight.$$"

	# 1. A confined process can start at all.
	if ! nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" -- true >/dev/null 2>&1; then
		die 77 "cannot start a confined process. nono failed to initialise."
	fi

	# 2. The positive control (D5, D9). Unconfined, this write must succeed, or
	#    its failure under confinement says nothing about confinement. Fail
	#    closed: a canary we cannot write is a pre-flight we cannot run.
	if ! : >"$canary" 2>/dev/null; then
		die 77 "cannot verify confinement: no writable path outside the project to test against."
	fi
	rm -f "$canary"

	# 3. A confined process cannot write outside the project. On success nothing
	#    is written; only the failure path leaves a file, which we then remove.
	nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" \
		-- sh -c ": > \"$canary\"" >/dev/null 2>&1 && rc=0 || rc=$?
	if [ "$rc" -eq 0 ]; then
		rm -f "$canary"
		die 77 "confinement is not enforced: a confined process wrote outside the project."
	fi

	# 4. And it genuinely did not write it.
	if [ -e "$canary" ]; then
		rm -f "$canary"
		die 77 "confinement is not enforced: the denial was reported but the write landed."
	fi
}
