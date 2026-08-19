# shellcheck shell=bash
# Unit layer: pure parsing and evaluation. No build, no network, no $HOME.
#
# Sourced by scripts/validate.sh, which owns `set -euo pipefail`, `fail` and
# the constants SPEC, REPO_ROOT and SCRIPT_DIR.

# The scenario identifiers spec.md declares, read out of the spec itself so a
# new scenario is covered without editing anything here.
#   ### Journey N            -> jN_<ordinal of its Given within the journey>
#   1. **RN — …**            -> rN
#   1. **RepN — …**          -> repN
# Only the `## Scenarios` section is read; Risks and the review checklist
# number their bullets too, and neither declares a scenario.
spec_scenario_ids() {
	awk '
		/^## Scenarios/ { in_scenarios = 1; next }
		/^## /          { in_scenarios = 0; next }
		!in_scenarios   { next }

		/^### Journey [0-9]+/ {
			journey = $0
			sub(/^### Journey /, "", journey)
			sub(/ .*$/, "", journey)
			given = 0
			next
		}
		/^### / { journey = ""; next }

		journey != "" && /^[0-9]+\. \*\*Given\*\*/ {
			given++
			printf "j%s_%d\n", journey, given
			next
		}
		journey == "" && /^[0-9]+\. \*\*R(ep)?[0-9]+ / {
			id = $0
			sub(/^[0-9]+\. \*\*/, "", id)
			sub(/ .*$/, "", id)
			print tolower(id)
		}
	' "$1" | sort -u
}

# The scenario identifiers the suite carries a check for. Derived from the
# layer files, so moving a check between layers does not disturb the bijection.
suite_scenario_check_ids() {
	local raw rc=0
	raw=$(grep -hoE '^check_(j[0-9]+_[0-9]+|r[0-9]+|rep[0-9]+)\(\)' "$SCRIPT_DIR"/checks/*.sh) || rc=$?
	# grep exits 1 for "no match", which is the state until the first scenario
	# check lands; any higher status is a real failure.
	[ "$rc" -le 1 ] || return "$rc"
	[ -n "$raw" ] || return 0
	printf '%s\n' "$raw" | sed 's/^check_//; s/()$//' | sort -u
}

# SC-3. Every scenario maps to exactly one check, and every check back to a
# scenario. Both sides are derived from their source rather than restated.
check_sc3() {
	local spec_ids impl_ids missing extra id

	spec_ids=$(spec_scenario_ids "$SPEC")
	impl_ids=$(suite_scenario_check_ids)

	# Anti-vacuity: an empty left-hand side would make the bijection hold by
	# matching nothing, and report OK while testing nothing.
	if [ -z "$spec_ids" ]; then
		fail "parsed no scenarios out of $SPEC; the parser and the spec have drifted"
		return 1
	fi

	missing=$(comm -23 <(printf '%s\n' "$spec_ids") <(printf '%s\n' "$impl_ids"))
	extra=$(comm -13 <(printf '%s\n' "$spec_ids") <(printf '%s\n' "$impl_ids"))

	if [ -n "$missing" ] || [ -n "$extra" ]; then
		printf 'scenario ↔ check bijection broken\n'
		if [ -n "$missing" ]; then
			while read -r id; do
				printf 'scenario with no check: %s\n' "$id"
			done <<<"$missing"
		fi
		if [ -n "$extra" ]; then
			while read -r id; do
				printf 'check with no scenario: %s\n' "$id"
			done <<<"$extra"
		fi
		return 1
	fi
}
