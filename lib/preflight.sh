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

# The probe reads before it writes, and on the passing path it writes nothing at
# all. That is the correction M9e made: the assertion used to be a canary file
# created outside the project, and macOS has nowhere to put one. The floor there
# grants /private, /tmp and /var/folders and $TMPDIR is the project, so the only
# writable location left is under /Users — the user's real home, written to on
# every single agent start. CI caught it as a fabricated home whose modification
# time moved during a session that had behaved perfectly.
#
# A read demonstrates enforcement exactly as well as a write, and leaves
# nothing. The write probe is kept because it costs no extra child, and because
# it can only ever land on the path where the boundary is already broken and the
# pre-flight is about to refuse.
#
# Distinguishing every way of being wrong is P9's requirement here: "nono could
# not start", "there was nowhere to test against" and "the child was not denied"
# are three different facts about the host and must not read alike.
preflight_or_die() {
	local probe canary rc err candidate verdicts=''

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
	# the probe target is deliberately outside it either way.

	# 1. A confined process can start at all. Its stdout is dropped, because a
	#    successful run prints a whole capability table nobody asked for, but
	#    its stderr is kept for the refusal to quote.
	if ! err=$(nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" --allow-cwd \
		-- true 2>&1 >/dev/null); then
		die 77 "cannot start a confined process. nono failed to initialise." "$err"
	fi

	# 2. A denial, observed at some location outside the project.
	#
	#    Two candidates, tried in order, because one name does not hold on every
	#    host. $XDG_RUNTIME_DIR comes first so the probe stays away from the
	#    home directory wherever the host offers somewhere else, and it is the
	#    one that survives a *nested* sandbox: an outer confinement that already
	#    denies $HOME leaves a pre-flight nothing to demonstrate with, while the
	#    outer session's own runtime directory is readable to it and granted to
	#    nobody inside. macOS sets no XDG_RUNTIME_DIR, so there $HOME is the
	#    answer and the read is what keeps that harmless.
	#
	#    A candidate that cannot serve is skipped with its reason rather than
	#    refused on the spot, and only an exhausted list refuses (P9): the
	#    refusal then carries every verdict, so the reason it gave up is
	#    readable rather than guessed at.
	#
	#    `( : > … )` and not `: > …`: `:` is a special builtin, so a redirection
	#    failure on it takes the whole shell down instead of setting a status,
	#    and the `2>/dev/null` never gets installed because redirections apply
	#    left to right. The assertion this replaces read that abort as the
	#    child's denial, and so passed by accident.
	canary=".agent-sandbox-preflight.$$"
	# The $1 and $2 belong to the inner shell, which receives the target and the
	# probe name as arguments. Interpolating them here would put the path inside
	# the script text, where a name with a space in it stops being one word.
	# shellcheck disable=SC2016
	probe='
		if ls -A "$1" >/dev/null 2>&1; then exit 10; fi
		if ( : >"$1/$2" ) 2>/dev/null; then rm -f "$1/$2" 2>/dev/null; exit 11; fi
		if [ -e "$1/$2" ]; then exit 12; fi
		exit 0
	'

	for candidate in "${XDG_RUNTIME_DIR:-}" "${HOME:-}"; do
		[ -n "$candidate" ] || continue

		# Inside the project is inside the grant, where a successful read is
		# correct behaviour and demonstrates nothing.
		case "$candidate" in
		"$PWD" | "$PWD"/*)
			verdicts+="  $candidate: inside the project, which the session is granted"$'\n'
			continue
			;;
		esac

		# The positive control (D5, D9). Unconfined, this read must succeed, or
		# its failure under confinement says nothing about confinement.
		if ! ls -A "$candidate" >/dev/null 2>&1; then
			verdicts+="  $candidate: not readable from here, so a denial under confinement would prove nothing"$'\n'
			continue
		fi

		# One child, both directions, reporting through its exit status. Read
		# first, because a boundary that leaks reads leaks the credentials R9 is
		# about whether or not it also leaks writes.
		nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" --allow-cwd \
			-- sh -c "$probe" sh "$candidate" "$canary" >/dev/null 2>&1 && rc=0 || rc=$?

		case "$rc" in
		0)
			return 0
			;;
		10)
			verdicts+="  $candidate: the confined read was not refused"$'\n'
			;;
		11 | 12)
			rm -f "$candidate/$canary"
			verdicts+="  $candidate: the confined write was not refused"$'\n'
			;;
		127)
			# Trying another location cannot help: the probe never ran.
			die 77 "cannot verify confinement: the probe could not run inside the confined process, so its failure says nothing about confinement."
			;;
		*)
			# The probe reports every outcome it knows about as a status of its
			# own, so anything else is the run itself having failed. Reading an
			# unrecognised status as success is the silent pass P9 forbids.
			die 77 "cannot verify confinement: the confined probe exited $rc at $candidate, which is not an outcome it reports."
			;;
		esac
	done

	# Nowhere left. Either the boundary is not applied or every location tried
	# was unusable, and the pre-flight cannot tell those apart without asking
	# the profile — a query it has no budget for. So it says both, and shows
	# what each candidate did.
	die 77 "$(printf 'cannot verify confinement: no location outside the project refused a confined process.\n%s' "$verdicts")"
}
