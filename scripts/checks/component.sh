# shellcheck shell=bash
#
# Component layer: one module against nono's own resolver, no kernel
# enforcement and no session. Every claim here is observed against the
# generated artefact, never against the plan's description of it.
#
# `set -euo pipefail`, `fail` and `REPO_ROOT` come from scripts/validate.sh.

# nono reads its own configuration root, and M1e observed that when
# XDG_CONFIG_HOME does not exist it warns and silently falls back to the host's
# $HOME/.config. A check that inherited that fallback would be asserting against
# whatever profiles and packs the developing machine happens to carry, so every
# nono invocation in this layer runs against a directory this function creates.
# NONO_NO_UPDATE_CHECK stops the network call M1e found on almost any invocation.
# The resolver is the pinned one, because a resolution is only evidence about
# the version this repository ships: the developing host offered 0.73.0 from a
# user profile against the flake's 0.74.0.
nono_hermetic() {
	local cfg=$1
	shift
	mkdir -p "$cfg"
	env NONO_NO_UPDATE_CHECK=1 XDG_CONFIG_HOME="$cfg" "$(pinned_bin nono)/nono" "$@"
}

# The profile is a derivation, so it is realised rather than read. Building it is
# also the only way to learn that lib/confinement.nix evaluates at all.
confinement_profile() {
	nix build --no-link --print-out-paths "$REPO_ROOT#confinement-$1"
}

# The resolved filesystem reach of a description, as `access<TAB>path` lines.
#
# nono has no flag for the working directory, so $WORKDIR is wherever it was
# invoked: the project's own grant only appears when the resolver runs from the
# project root. The pid is normalised away because nono grants the resolving
# process its own /proc entry, which differs between two invocations and says
# nothing about the description.
manifest_grants() {
	local profile=$1 cfg=$2
	(
		cd "$REPO_ROOT" || exit 1
		nono_hermetic "$cfg" profile show "$profile" --format manifest
	) | jq -r '.filesystem.grants[] | "\(.access)\t\(.path)"' |
		sed 's#/proc/[0-9][0-9]*#/proc/<pid>#' | sort -u
}

# The resolved deny set of a description, as paths. Same working-directory
# reasoning as manifest_grants: a deny is expanded against $WORKDIR too.
manifest_denies() {
	local profile=$1 cfg=$2
	(
		cd "$REPO_ROOT" || exit 1
		nono_hermetic "$cfg" profile show "$profile" --format manifest
	) | jq -r '.filesystem.deny[].path' | sort -u
}

check_confinement_validates() {
	local found=0 lib=$REPO_ROOT/lib/confinement.nix
	local profile tmp cfg store agent=claude-code

	[ -f "$lib" ] || {
		fail "lib/confinement.nix: no such file"
		return 1
	}

	profile=$(confinement_profile "$agent") || {
		fail "the confinement description for $agent does not build"
		return 1
	}

	tmp=$(mktemp -d "$REPO_ROOT/.tmp/component.XXXXXX")
	cfg=$tmp/config
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	# nono's schema is the authority on shape, so nothing here restates it.
	# --strict is used because it turns a deprecated-key warning into a failure,
	# and a profile accepted with a warning nobody reads is the silent fallback
	# P9 forbids.
	if ! nono_hermetic "$cfg" profile validate --strict "$profile" >"$tmp/validate.out" 2>&1; then
		printf 'the generated description for %s does not validate:\n' "$agent"
		cat "$tmp/validate.out"
		found=1
	fi

	# Negative control, in the same run. The assertion above is that a command
	# exits 0; if that command ever stopped inspecting the file it would still
	# exit 0 and this check would pass while asserting nothing. So a copy with
	# one unresolvable group reference must be rejected.
	jq '.groups.include += ["__no_such_group__"]' "$profile" >"$tmp/broken.json"
	if nono_hermetic "$cfg" profile validate --strict "$tmp/broken.json" >/dev/null 2>&1; then
		printf 'negative control absent: validate accepted a profile naming a group that does not exist, so its acceptance above proves nothing\n'
		found=1
	fi

	# D10: no parent is named. M1e observed that a description naming `default`
	# and one naming nothing resolve byte-identically, so naming it would imply
	# an inheritance that does not happen.
	if jq -e 'has("extends")' "$profile" >/dev/null; then
		printf 'the description names a parent, but D10 says naming one implies an inheritance that does not happen\n'
		found=1
	fi

	# M1e: omitting meta.name is a parse error rather than a default.
	if [ "$(jq -r '.meta.name // ""' "$profile")" != "$agent" ]; then
		printf 'meta.name is %s, not the agent name %s\n' \
			"$(jq -r '.meta.name // "absent"' "$profile")" "$agent"
		found=1
	fi

	# D15: the store is absent from the floor, so a session that cannot read it
	# exits 127 before the agent runs. Independent of check_sc1, which asserts the
	# registry and the grants agree with each other and so stays green when both
	# lose the substrate together. The store's own prefix comes from Nix, because
	# a check that spells it out would pass on a store mounted elsewhere.
	store=$(nix eval --raw --impure --expr 'builtins.storeDir') || {
		fail "the store prefix does not evaluate"
		return 1
	}
	jq -e --arg s "$store" '[.filesystem.read // []] | flatten | index($s)' "$profile" >/dev/null ||
		{
			printf 'filesystem.read does not carry %s, so the session cannot execute from the store\n' "$store"
			found=1
		}

	# D11: git_config grants read on the host's git configuration, and read-only
	# is no protection when the danger is that a directive in it runs a program
	# inside the boundary.
	if jq -e '.groups.include | index("git_config")' "$profile" >/dev/null; then
		printf 'groups.include carries git_config, which D11 excludes\n'
		found=1
	fi

	# The relocation variables are not restated here. They are read from the
	# agent table and asserted to appear in the description with the same value,
	# so the two cannot drift and M8b adding a variable needs no edit here.
	local want got k v
	# shellcheck disable=SC2016 # $WORKDIR is nono's to expand, not the shell's
	want=$(nix eval --json "$REPO_ROOT#agents.\"$agent\".stateVars" \
		--apply 'f: f "$WORKDIR"') || {
		fail "the agent table does not expose stateVars for $agent"
		return 1
	}
	got=$(jq -c '.environment.set_vars' "$profile")
	while IFS=$'\t' read -r k v; do
		[ -n "$k" ] || continue
		if [ "$(jq -r --arg k "$k" '.[$k] // "<absent>"' <<<"$got")" != "$v" ]; then
			printf 'set_vars does not carry the agent table entry %s=%s\n' "$k" "$v"
			found=1
		fi
	done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$want")

	# FR-23 / D11. These two are the confinement's own, not the agent's: the
	# toolchain is directed at configuration this environment wrote rather than
	# merely denied, so its effective configuration is the same on every machine.
	for k in GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM; do
		jq -e --arg k "$k" 'has($k)' <<<"$got" >/dev/null ||
			{
				printf 'set_vars does not carry %s, so the version-control toolchain is undirected\n' "$k"
				found=1
			}
	done

	[ "$found" -eq 0 ]
}

# SC-1 / FR-2: the reach a description adds to nono's floor is the project
# directory plus the leak registry's entries, and nothing else. An equality, so
# an entry that is registered but not granted fails too.
#
# The floor is derived, not listed (D4). The same description with every
# capability key stripped resolves to exactly what nono supplies whatever the
# description says, so a floor that grows in a later nono release moves the
# baseline instead of breaking the check.
#
# No positive control is needed, per the reasoning M9a records for check_j1_1:
# the observable is a set rather than a failure, and the second half of the
# equality already fails if the resolver returns nothing at all.
check_sc1() {
	local found=0 agent=claude-code
	local profile tmp cfg project registry

	profile=$(confinement_profile "$agent") || {
		fail "the confinement description for $agent does not build"
		return 1
	}

	tmp=$(mktemp -d "$REPO_ROOT/.tmp/component.XXXXXX")
	cfg=$tmp/config
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	# A description that declares nothing, derived from this one rather than
	# written out, so the baseline cannot drift from the profile it is subtracted
	# from. meta survives because M1e found meta.name is required.
	jq '{meta}' "$profile" >"$tmp/floor.json"

	project=$(cd "$REPO_ROOT" && pwd -P)
	manifest_grants "$profile" "$cfg" >"$tmp/agent.grants"
	manifest_grants "$tmp/floor.json" "$cfg" >"$tmp/floor.grants"

	registry=$(nix eval --json "$REPO_ROOT#leakRegistry" \
		--apply "es: builtins.filter (e: builtins.elem \"$agent\" e.agents) es") || {
		fail "the leak registry does not evaluate"
		return 1
	}

	# Every grant this description adds is either the project's own subtree or a
	# registered path. entryType requires an absolute path, so an entry compares
	# against a resolved grant without any expansion.
	local seen_project=0 access path mode
	while IFS=$'\t' read -r access path; do
		[ -n "$path" ] || continue
		case $path in
		"$project")
			seen_project=1
			[ "$access" = readwrite ] || {
				printf 'the project directory is granted %s, not readwrite: %s (%s)\n' \
					"$access" "$path" "$agent"
				found=1
			}
			continue
			;;
		"$project"/*) continue ;;
		esac
		# The entry is bound before the pipe, because `$p |` rebinds `.` to the
		# path being tested and `.path` would then index a string.
		jq -e --arg p "$path" \
			'any(.[]; . as $e | $p == $e.path or ($p | startswith($e.path + "/")))' \
			<<<"$registry" >/dev/null && continue
		printf 'granted path outside project and not in registry: %s (%s)\n' "$path" "$agent"
		found=1
	done < <(comm -13 "$tmp/floor.grants" "$tmp/agent.grants")

	[ "$seen_project" -eq 1 ] || {
		printf 'the project directory is not granted at all: %s (%s)\n' "$project" "$agent"
		found=1
	}

	# The other direction. A registered exception that no longer reaches the
	# description is a stale entry, and FR-3 has no room for one.
	while IFS=$'\t' read -r path mode; do
		[ -n "$path" ] || continue
		grep -qxF "$mode	$path" "$tmp/agent.grants" || {
			printf 'registry entry not granted as %s: %s (%s)\n' "$mode" "$path" "$agent"
			found=1
		}
	done < <(jq -r '.[] | [.path, .mode] | @tsv' <<<"$registry")

	[ "$found" -eq 0 ]
}

# D4: the merge of nono's floor, the groups a description includes and the
# description's own declarations behaves as the plan claims. M1e established the
# schema says which fields exist and not how they combine, so every claim below
# is observed against a resolved description and none is read off the schema.
#
# `nono why` is deliberately absent. D15 found it reports a deny the kernel
# cannot enforce, so it is not a proxy for what the merge produces.
check_component_merge() {
	local found=0 agent=claude-code
	local profile tmp cfg project candidate group

	profile=$(confinement_profile "$agent") || {
		fail "the confinement description for $agent does not build"
		return 1
	}

	tmp=$(mktemp -d "$REPO_ROOT/.tmp/component.XXXXXX")
	cfg=$tmp/config
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	# A description that declares nothing and names no parent, derived from this
	# one rather than written out. Whatever it still resolves to is the floor.
	jq '{meta}' "$profile" >"$tmp/floor.json"

	project=$(cd "$REPO_ROOT" && pwd -P)
	manifest_grants "$profile" "$cfg" >"$tmp/agent.grants"
	manifest_grants "$tmp/floor.json" "$cfg" >"$tmp/floor.grants"
	manifest_denies "$profile" "$cfg" >"$tmp/agent.deny"
	manifest_denies "$tmp/floor.json" "$cfg" >"$tmp/floor.deny"

	# Anti-vacuity for every containment below: an empty floor would make them
	# all hold while asserting nothing.
	if [ ! -s "$tmp/floor.grants" ] || [ ! -s "$tmp/floor.deny" ]; then
		fail "the floor resolves to no grants or no denies, so the merge claims would hold vacuously"
		return 1
	fi

	# Claim 1. The floor's grants and denies are present although the
	# description names no parent (D10) and asks for neither.
	local path
	while read -r path; do
		[ -n "$path" ] || continue
		printf 'floor grant absent from the resolved description: %s (%s)\n' "$path" "$agent"
		found=1
	done < <(comm -23 "$tmp/floor.grants" "$tmp/agent.grants")

	while read -r path; do
		[ -n "$path" ] || continue
		printf 'floor deny absent from the resolved description: %s (%s)\n' "$path" "$agent"
		found=1
	done < <(comm -23 "$tmp/floor.deny" "$tmp/agent.deny")

	# Every deny the merge produces lies outside the project. D15 found Landlock
	# is allow-only, so a deny under the granted project subtree cannot be
	# enforced and nono refuses to start rather than pretend it is. That makes
	# this a precondition on every project the environment is consumed in, and
	# `nono profile validate --strict` accepts the overlap, so the set is the
	# only observer. A deny *above* the project is a different matter and fine:
	# it is expressed by not granting, which the project's own grant overrides.
	while read -r path; do
		case $path in
		"$project" | "$project"/*)
			printf 'deny path inside the project: %s (%s)\n' "$path" "$agent"
			found=1
			;;
		esac
	done <"$tmp/agent.deny"

	# Claim 2. A `required` group's deny outranks a grant the description makes
	# for the same path. The candidate is derived rather than named: the required
	# groups come from nono's own machine-readable listing, their resolved paths
	# from the group detail, and only a path that both a required group and the
	# merge agree on is used. A candidate that survived a bad parse of the group
	# detail could not appear in the resolved deny set.
	nono_hermetic "$cfg" profile groups --json |
		jq -r '.[] | select(.required == true and (.deny.access // 0) > 0) | .name' |
		while read -r group; do
			nono_hermetic "$cfg" profile groups "$group" | sed -n 's/.*-> \(\/.*\)$/\1/p'
		done | sort -u >"$tmp/required.deny"
	comm -12 "$tmp/required.deny" "$tmp/agent.deny" >"$tmp/candidates"

	if [ ! -s "$tmp/candidates" ]; then
		fail "no required group's deny reaches the merge, so precedence cannot be observed"
		return 1
	fi
	candidate=$(head -1 "$tmp/candidates")

	jq --arg x "$candidate" '.filesystem.read += [$x]' "$profile" >"$tmp/granted.json"
	manifest_grants "$tmp/granted.json" "$cfg" >"$tmp/granted.grants"
	manifest_denies "$tmp/granted.json" "$cfg" >"$tmp/granted.deny"

	# The grant has to be shown to have reached the merge, or a description nono
	# quietly dropped would look the same as a deny that outranked it.
	if ! awk -F'\t' -v p="$candidate" '$2 == p { hit = 1 } END { exit !hit }' \
		"$tmp/granted.grants"; then
		fail "the probe grant for $candidate never reached the merge, so precedence is untested"
		return 1
	fi

	if ! grep -qxF "$candidate" "$tmp/granted.deny"; then
		printf 'a description grant removed a required group deny: %s (%s)\n' "$candidate" "$agent"
		found=1
	fi

	# Claim 3. An included group contributes its grants additively. The probe
	# group is derived too, and the first one that adds anything is used: several
	# of the granting groups are already in the floor, where inclusion is a
	# no-op and the claim would hold vacuously.
	local added=0 removed
	while read -r group; do
		jq --arg g "$group" '.groups.include += [$g]' "$profile" >"$tmp/probe.json"
		manifest_grants "$tmp/probe.json" "$cfg" >"$tmp/probe.grants"
		comm -13 "$tmp/agent.grants" "$tmp/probe.grants" >"$tmp/probe.added"
		[ -s "$tmp/probe.added" ] || continue
		added=1
		removed=$(comm -23 "$tmp/agent.grants" "$tmp/probe.grants")
		if [ -n "$removed" ]; then
			printf 'including group %s removed a grant the description already had: %s\n' \
				"$group" "$(printf '%s' "$removed" | tr '\n' ' ')"
			found=1
		fi
		break
	done < <(nono_hermetic "$cfg" profile groups --json |
		jq -r '.[] | select(.required == false and (.deny | length) == 0 and (.allow.read // 0) > 0) | .name')

	[ "$added" -eq 1 ] || {
		fail "no group was observed to add a grant, so additivity would hold vacuously"
		return 1
	}

	[ "$found" -eq 0 ]
}
