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
nono_hermetic() {
	local cfg=$1
	shift
	mkdir -p "$cfg"
	env NONO_NO_UPDATE_CHECK=1 XDG_CONFIG_HOME="$cfg" nono "$@"
}

# The profile is a derivation, so it is realised rather than read. Building it is
# also the only way to learn that lib/confinement.nix evaluates at all.
confinement_profile() {
	nix build --no-link --print-out-paths "$REPO_ROOT#confinement-$1"
}

check_confinement_validates() {
	local found=0 lib=$REPO_ROOT/lib/confinement.nix
	local profile tmp cfg agent=claude-code

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

	# D10: the store is absent from the floor, so a session without nix_runtime
	# exits 127 before the agent runs. D11: git_config grants read on the host's
	# git configuration, and read-only is no protection when the danger is that a
	# directive in it runs a program inside the boundary.
	jq -e '.groups.include | index("nix_runtime")' "$profile" >/dev/null ||
		{
			printf 'groups.include does not carry nix_runtime, so the session cannot execute from the store\n'
			found=1
		}
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
