#!/usr/bin/env bash
# FR-12: the single entry point for every assertion this repository makes.
#
# A check is a `check_*` function in one of scripts/checks/<layer>.sh, and its
# layer is the file it lives in. Nothing here enumerates the checks, so this
# driver cannot drift from the suite it runs.
set -euo pipefail

# Cheapest first, so a fast failure is a fast failure.
LAYERS=(unit component integration e2e)

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# The feature under verification. Named rather than globbed: a second spec's
# scenarios would silently join the bijection SC-3 asserts.
SPEC="$REPO_ROOT/specs/001-agent-sandbox/spec.md"

# SPEC is read by the layer files sourced at runtime, which shellcheck cannot
# follow because their paths are built from $LAYERS.
# shellcheck disable=SC2034
readonly LAYERS SCRIPT_DIR REPO_ROOT SPEC

die() {
	printf 'validate.sh: %s\n' "$*" >&2
	exit 2
}

# Diagnostics a check prints on its way to a non-zero status. The runner owns
# the verdict line, so this prints the reason only.
fail() {
	printf '%s\n' "$*"
	return 1
}

# The bin directory of a pinned flake output, for checks that must run the
# version this repository ships rather than the one PATH happens to offer.
# AGENTS.md §3: a tool that resolves only because it is in the developer's user
# profile is not available to a stranger. M4b found the developing host
# carrying both `nono` and `claude` in a user profile, one of them a different
# version from the pin, so this is not hypothetical.
#
# Resolved on demand, not up front, because the unit layer is defined to need
# no build. Memoised per check, which is as far as it can reach: run_check
# evaluates each check in a command substitution, so the cache dies with it.
declare -A PINNED_BIN=()
pinned_bin() {
	local attr=$1 out
	if [ -z "${PINNED_BIN[$attr]:-}" ]; then
		out=$(nix build --no-link --print-out-paths "$REPO_ROOT#$attr") ||
			die "cannot build the pinned $attr"
		PINNED_BIN[$attr]="$out/bin"
	fi
	printf '%s\n' "${PINNED_BIN[$attr]}"
}

usage() {
	cat <<'EOF'
usage: validate.sh [--layer unit|component|integration|e2e] [--list]

  --layer L   run only layer L (default: every layer, cheapest first)
  --list      list the checks that would run, with their layer
EOF
}

layer_file() {
	printf '%s/checks/%s.sh\n' "$SCRIPT_DIR" "$1"
}

is_layer() {
	local candidate=$1 layer
	for layer in "${LAYERS[@]}"; do
		[ "$layer" = "$candidate" ] && return 0
	done
	return 1
}

# The check functions a layer file defines, in the order it defines them.
checks_in() {
	local file=$1 raw rc=0
	raw=$(grep -oE '^check_[a-z0-9_]+\(\)' "$file") || rc=$?
	# grep exits 1 for "no match", which is a legitimate empty layer; any
	# higher status is a real failure and must not be swallowed.
	[ "$rc" -le 1 ] || return "$rc"
	[ -n "$raw" ] || return 0
	printf '%s\n' "$raw" | sed 's/()$//'
}

# Every layer file is sourced regardless of --layer, because check_sc3 asserts
# over the whole suite rather than over the layer being run.
source_layers() {
	local layer file
	for layer in "${LAYERS[@]}"; do
		file=$(layer_file "$layer")
		[ -f "$file" ] || continue
		# shellcheck source=/dev/null
		. "$file"
	done
}

# A check returns 78 to say the observation it makes does not exist on this
# host: an instrument the layer needs is platform-specific, so there is nothing
# to run rather than something that passed. Reported as SKIP and, per P2's
# anti-vacuity rule, deliberately not counted as having run — a suite where
# every check skipped must not report success.
#
# 78 rather than 77, because 77 is a product-level status: the pre-flight's
# refusal of an unenforceable host, which `check_r6` asserts. A check that
# refused for that reason would be a failure of this repository's own promise,
# and must never be reported as a skip.
readonly SKIP_STATUS=78

run_check() {
	local name=$1 output rc=0
	# No stdin, and this is load-bearing rather than tidy. run_layers feeds the
	# check names through a process substitution on the loop's stdin, which a
	# check inherits; an agent started in print mode reads stdin for its prompt,
	# drains the list, and every name after it is silently never run. Measured:
	# `check_j8_1`'s sessions swallowed `check_r9` and the suite reported 30
	# passes with nothing to say the thirty-first existed.
	output=$("$name" 2>&1 </dev/null) || rc=$?
	if [ "$rc" -eq 0 ]; then
		printf 'PASS  %s\n' "$name"
		return 0
	fi
	if [ "$rc" -eq "$SKIP_STATUS" ]; then
		printf 'SKIP  %s\n' "$name"
		[ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /'
		return "$SKIP_STATUS"
	fi
	printf 'FAIL  %s\n' "$name" >&2
	[ -z "$output" ] || printf '%s\n' "$output" | sed 's/^/      /' >&2
	return 1
}

list_checks() {
	local layer file name
	for layer in "$@"; do
		file=$(layer_file "$layer")
		[ -f "$file" ] || continue
		while read -r name; do
			printf '%-12s %s\n' "$layer" "$name"
		done < <(checks_in "$file")
	done
}

run_layers() {
	local layer file name rc ran=0 failed=0 skipped=0 found=0
	local -a defined=()
	for layer in "$@"; do
		file=$(layer_file "$layer")
		[ -f "$file" ] || continue
		printf '== %s\n' "$layer"
		mapfile -t defined < <(checks_in "$file")
		found=$((found + ${#defined[@]}))
		while read -r name; do
			rc=0
			run_check "$name" || rc=$?
			case "$rc" in
			0) ran=$((ran + 1)) ;;
			"$SKIP_STATUS") skipped=$((skipped + 1)) ;;
			*)
				ran=$((ran + 1))
				failed=$((failed + 1))
				;;
			esac
		done < <(checks_in "$file")
	done
	# P2's anti-vacuity rule: a suite that ran nothing reports success while
	# testing nothing, which is strictly worse than a red run. A skipped check
	# is not a run one, so a host where every check skipped fails here.
	[ "$ran" -gt 0 ] || die "no checks ran; the suite would report success without testing anything"
	# The same rule one step finer: a suite that ran all but one reports success
	# too, and says nothing about the one. What the layer files define is counted
	# before the loop and compared against what the loop reached, so a loop cut
	# short is a red run — which is how `check_r9` came to be missing from a
	# green one.
	[ "$found" -eq $((ran + skipped)) ] ||
		die "$found checks were found and $((ran + skipped)) ran; the suite stopped short of its own list"
	if [ "$failed" -gt 0 ]; then
		printf '%d of %d checks failed\n' "$failed" "$ran" >&2
		return 1
	fi
	if [ "$skipped" -gt 0 ]; then
		printf '%d checks passed, %d skipped\n' "$ran" "$skipped"
		return 0
	fi
	printf '%d checks passed\n' "$ran"
}

main() {
	local requested='' list=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--layer)
			[ $# -ge 2 ] || die "--layer needs a value"
			requested=$2
			shift 2
			;;
		--list)
			list=1
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			# P9: a closed set of arguments has no silently-succeeding catch-all.
			usage >&2
			die "unknown argument: $1"
			;;
		esac
	done

	local layers=()
	if [ -n "$requested" ]; then
		is_layer "$requested" || die "unknown layer: $requested"
		layers=("$requested")
	else
		layers=("${LAYERS[@]}")
	fi

	source_layers

	if [ "$list" -eq 1 ]; then
		list_checks "${layers[@]}"
		return 0
	fi

	run_layers "${layers[@]}"
}

main "$@"
