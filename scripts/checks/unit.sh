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

# The devShell, reduced to the two things R7 asks about: the name nix gives
# each package, and the text of the hook that exports the variables. One
# evaluation rather than two, and `mkShell` folds its `packages` argument into
# nativeBuildInputs, which is why that is what gets read.
devshell_facts() {
	local system
	system=$(nix eval --impure --raw --expr builtins.currentSystem) || return
	nix eval --json ".#devShells.$system.default" --apply \
		'd: { packages = map (p: p.pname or p.name) d.nativeBuildInputs; hook = d.shellHook; }'
}

# R7. No artefact of the prior Kafka project survives — not as a package, not
# as a variable the hook exports, not in the flake's description, not as an
# ignore rule.
#
# The forbidden names are literals because here the names *are* the criterion.
# Everything they are matched against is read back out of the flake and out of
# .gitignore, so a name that moves between those places is still caught.
check_r7() {
	local facts packages hook description ignores name found=0
	# Names as nix reports them: `openjdk25` answers to `openjdk`, so a version
	# bump cannot smuggle one back in under a new attribute.
	local -a bad_packages=(kcat kafkactl postgresql lazysql openjdk maven nodejs zellij)
	local -a bad_vars=(KCAT_CONFIG KAFKA_CTL_CONFIG PSQLRC PSQL_HISTORY MAVEN_ARGS MAVEN_OPTS)
	local -a bad_ignores=('materialize/.config/' 'current-context.yml' '.env')
	# D9's positive control. Without it every assertion below is satisfied by a
	# devShell that declares no packages at all.
	local needed=jq

	facts=$(devshell_facts) || {
		fail "could not evaluate the devShell"
		return 1
	}
	packages=$(printf '%s' "$facts" | jq -r '.packages[]')
	hook=$(printf '%s' "$facts" | jq -r '.hook')
	description=$(nix flake metadata --json 2>/dev/null | jq -r '.description')
	ignores=$(cat "$REPO_ROOT/.gitignore")

	for name in "${bad_packages[@]}"; do
		grep -qxF "$name" <<<"$packages" && {
			printf 'kafka artefact present in devShell: %s\n' "$name"
			found=1
		}
	done
	for name in "${bad_vars[@]}"; do
		grep -qE "\\b$name=" <<<"$hook" && {
			printf 'kafka artefact present in shellHook: %s\n' "$name"
			found=1
		}
	done
	for name in "${bad_ignores[@]}"; do
		grep -qxF "$name" <<<"$ignores" && {
			printf 'kafka artefact present in .gitignore: %s\n' "$name"
			found=1
		}
	done
	if grep -qiE 'kafka|hivemind|playground' <<<"$description"; then
		printf 'kafka artefact present in description: %s\n' "$description"
		found=1
	fi

	if ! grep -qxF "$needed" <<<"$packages"; then
		printf 'positive control absent: the devShell declares no %s, so the assertions above hold vacuously\n' "$needed"
		found=1
	fi

	[ "$found" -eq 0 ]
}

# The bootstrap region of .envrc: everything it exports before it hands over to
# the flake. P1 allows exactly this exception, because nix cannot read the flake
# without these already set. The region is defined by its position rather than by
# a list, so a third bootstrap variable added later is covered without editing
# this check.
envrc_bootstrap_exports() {
	awk '/^[[:space:]]*use[[:space:]]+flake/ { exit }
	     /^[[:space:]]*export[[:space:]]/' "$REPO_ROOT/.envrc"
}

# The variables a fragment leaves behind, resolved by running it rather than by
# reading it. The two files are free to spell one value differently -- nix's
# indented strings escape where a shell does not -- and it is the value a shell
# ends up with that has to match, not the text that produced it.
resolve_bootstrap() {
	bash -c '
		cd "$1" || exit 1
		eval "$2" >/dev/null 2>&1 || exit 1
		shift 2
		for v; do printf "%s=%s\n" "$v" "${!v-<unset>}"; done
	' _ "$@"
}

# P1 mirror. These two variables have to live in two files, so the only thing
# keeping them honest is a check that reads both. Same directory for both
# resolutions, since the values embed $PWD.
check_bootstrap_mirror() {
	local names fragment hook root from_envrc from_flake

	fragment=$(envrc_bootstrap_exports)
	mapfile -t names < <(printf '%s\n' "$fragment" |
		sed -nE 's/^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p')

	# Anti-vacuity: with no names, both sides resolve to nothing and the
	# comparison below holds without having compared anything.
	if [ "${#names[@]}" -eq 0 ]; then
		fail "no exports found before 'use flake' in .envrc; the mirror comparison would be vacuous"
		return 1
	fi

	hook=$(devshell_facts | jq -r .hook) || return 1
	root=$(mktemp -d) || return 1
	from_envrc=$(resolve_bootstrap "$root" "$fragment" "${names[@]}")
	from_flake=$(resolve_bootstrap "$root" "$hook" "${names[@]}")
	rm -rf "$root"

	[ "$from_envrc" = "$from_flake" ] && return 0

	printf 'bootstrap variables differ between .envrc and flake.nix\n'
	printf '< .envrc\n> flake.nix\n'
	diff <(printf '%s\n' "$from_envrc") <(printf '%s\n' "$from_flake") || true
	return 1
}

# A candidate entry, put through the registry's own entry type. Evaluation
# succeeds and prints the entry when the type accepts it, and fails when it does
# not, so the caller reads the verdict off the exit status.
registry_typecheck() {
	nix eval --json "$REPO_ROOT#leakRegistryCheckEntry" --apply "f: f $1" 2>&1
}

# SC-2 / FR-3. The registry is the only place a path outside the project may be
# named, so its shape is asserted rather than trusted.
#
# The three invariants come from plan.md § Properties. They are quantified over
# the entries, and the registry is expected to be empty, so they would hold
# vacuously on their own. The type probes are what make the check bite today: a
# well-formed entry must be accepted and a malformed one rejected, which is a
# property of the entry type and needs no entry to exist.
check_registry() {
	local registry=$REPO_ROOT/lib/leak-registry.nix
	if [ ! -f "$registry" ]; then
		fail "lib/leak-registry.nix: no such file"
		return 1
	fi

	local entries found=0
	if ! entries=$(nix eval --json "$REPO_ROOT#leakRegistry"); then
		fail "nix eval --json .#leakRegistry failed"
		return 1
	fi

	# Invariants 1 and 2: both justifications are present, and no entry points
	# back inside the project. A path under $WORKDIR is not an exception to the
	# boundary, it is already inside it.
	local findings
	findings=$(jq -r '
		to_entries[] | .value as $e |
		( if ($e.why | length) == 0
		  then "registry entry '"'"'\($e.path)'"'"' does not say why it is needed"
		  else empty end ),
		( if ($e.whyNotNarrower | length) == 0
		  then "registry entry '"'"'\($e.path)'"'"' does not say why a narrower grant fails"
		  else empty end ),
		( if ($e.path | startswith("$WORKDIR")) or ($e.path | startswith("/") | not)
		  then "registry entry inside the project is not an exception: \($e.path)"
		  else empty end )
	' <<<"$entries") || {
		fail "the registry did not parse as a list of entries: $entries"
		return 1
	}
	if [ -n "$findings" ]; then
		printf '%s\n' "$findings"
		found=1
	fi

	# Invariant 3: every agent an entry excepts a path for is an agent that
	# exists. lib/agents.nix names them from M3b onwards; until an entry appears
	# there is nothing to cross-reference, and once one does the lookup has to
	# resolve or this fails. The ordering is enforced, not assumed.
	if [ "$(jq -r 'length' <<<"$entries")" -gt 0 ]; then
		local known
		if ! known=$(nix eval --json "$REPO_ROOT#agents" --apply builtins.attrNames); then
			fail "the registry has entries but the agent set does not evaluate"
			return 1
		fi
		findings=$(jq -r --argjson known "$known" '
			.[] as $e | $e.agents[] | select(. as $a | $known | index($a) | not) |
			"registry entry '"'"'\($e.path)'"'"' names an unknown agent: \(.)"
		' <<<"$entries")
		if [ -n "$findings" ]; then
			printf '%s\n' "$findings"
			found=1
		fi
	fi

	# The type accepts a well-formed entry. Without this the rejection below
	# would also be satisfied by a type that rejects everything.
	local control='{ path = "/etc/example"; mode = "read"; agents = [ ]; why = "control"; whyNotNarrower = "control"; }'
	local out
	if ! out=$(registry_typecheck "$control"); then
		printf 'positive control absent: the entry type rejects a well-formed entry, so the rejection below proves nothing\n%s\n' "$out"
		found=1
	fi

	# The type rejects what it exists to reject: a mode outside the enum, and a
	# key that is not an option. Both are shape, which is the type's business;
	# the emptiness of a justification is content, which is the loop's above.
	local rejected
	for rejected in \
		'{ path = "/etc/example"; mode = "sideways"; agents = [ ]; why = "x"; whyNotNarrower = "x"; }' \
		'{ path = "/etc/example"; mode = "read"; agents = [ ]; why = "x"; whyNotNarrower = "x"; extra = true; }'; do
		if out=$(registry_typecheck "$rejected"); then
			printf 'the entry type accepted a malformed entry: %s\n' "$rejected"
			found=1
		fi
	done

	[ "$found" -eq 0 ]
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
