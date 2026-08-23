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
	# Whatever the tool itself said, when it said anything. A guard that hides
	# the reason for its own refusal is the opaque failure P9 exists to prevent,
	# and "nono failed to initialise" on its own sent a reader looking in the
	# wrong place for a quarter of an hour.
	if [ -n "${3:-}" ]; then
		printf 'agent-sandbox: nono said: %s\n' "$3" >&2
	fi
	printf 'agent-sandbox: required: kernel-enforced filesystem confinement (Landlock >= 5.13 on Linux, Seatbelt on macOS).\n' >&2
	printf 'agent-sandbox: refusing to start an agent. There is no override.\n' >&2
	exit "$1"
}

# Four assertions, because P9 forbids letting "nono could not start" or "the
# canary was never writable" look like "the child was denied".
preflight_or_die() {
	local canary rc err
	canary="${XDG_RUNTIME_DIR:-$HOME}/.agent-sandbox-preflight.$$"

	# Every `nono run` below passes --allow-cwd, and the reason is not the one
	# first recorded here. The flag is the working-directory *consent*; without
	# it nono asks for that consent on stdin, and the question would go to
	# /dev/null with the rest of the output. So a terminal hung on a prompt it
	# could not see, while the suite — which runs every check under
	# `</dev/null` — took the non-interactive path and never saw one. The
	# earlier note said the pre-flight "does not need" the flag because its
	# canary lives outside the project. That is true of the grant and says
	# nothing about the prompt.
	#
	# The flag grants the project, which the assertions below do not rely on:
	# the canary is deliberately outside it either way.

	# 1. A confined process can start at all. Its stdout is dropped, because a
	#    successful run prints a whole capability table nobody asked for, but
	#    its stderr is kept for the refusal to quote.
	if ! err=$(nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" --allow-cwd \
		-- true 2>&1 >/dev/null); then
		die 77 "cannot start a confined process. nono failed to initialise." "$err"
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
	nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" --allow-cwd \
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
