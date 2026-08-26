# shellcheck shell=bash
#
# End-to-end layer. The repository consumed the way a stranger consumes it:
# from the published reference rather than from this working tree, into a home
# holding none of the author's configuration.
#
# `set -euo pipefail`, `fail` and `REPO_ROOT` come from scripts/validate.sh.
#
# AGENTS.md names this the layer that matters and the layer easiest to fake,
# and the two fakes are specific. A run can reach the working tree instead of
# the reference, and a run can inherit the developing environment. Each has a
# control below, because a green run here is worth nothing while either is
# still possible.

# The canonical published reference (FR-19), and the only place it is written.
#
# A literal on purpose. FR-19's obligation is that every document and every
# check name the same reference, so the literal *is* the criterion; deriving it
# from `git remote` would only make the check agree with whatever this machine
# happens to point at.
canonical_ref() { printf '%s\n' 'github:GRBurst/agent-sandbox'; }

# The environment a stranger arrives with, as assignments for `env -i`.
#
# `env -i` rather than `direnv exec .` or a bare `nix develop`, because
# `nix develop --command` prepends the devshell's PATH and *keeps the
# caller's*: probed from this checkout without it, `claude` resolved the
# developing wrapper at position 53 of PATH and the ref took no part at all.
#
# Three of these are load-bearing beyond being clean:
#
#   - PATH is *derived* from where nix itself lives. The literal that works on
#     NixOS does not exist on the macOS runner, and a check that hardcodes one
#     platform's answer cannot make FR-20's cross-platform claim.
#   - TMPDIR is inside the project. `env -i` strips it, and both fallbacks are
#     wrong: /tmp is denied to anyone developing this from inside a confined
#     session, and a TMPDIR beside the state root makes the `system_write_linux`
#     grant overlap it, which nono refuses to start on.
#   - XDG_CONFIG_HOME exists before the mechanism is invoked, or the mechanism
#     falls back to the real home and reads the author's configuration (M1e).
stranger_env() {
	local home=$1 state=$2 project=$3 nixbin
	nixbin=$(dirname "$(command -v nix)")
	mkdir -p "$home/.config" "$home/.local/share" "$home/.cache" \
		"$state/nono/audit" "$project/.tmp/session"
	# The audit ledger exists before the run, or the migration that fails runs
	# after the child exits and replaces the child's exit status with 1.
	touch "$state/nono/audit/ledger.ndjson"
	STRANGER_ENV=(
		"HOME=$home"
		"XDG_CONFIG_HOME=$home/.config"
		"XDG_DATA_HOME=$home/.local/share"
		"XDG_CACHE_HOME=$home/.cache"
		"XDG_STATE_HOME=$state"
		"TMPDIR=$project/.tmp/session"
		"USER=$(id -un)"
		NONO_NO_UPDATE_CHECK=1
		"PATH=$nixbin"
	)
	STRANGER_PATH=$nixbin
}

# git, with the developing host's configuration out of the way. A global
# `core.excludesFile` would otherwise decide what counts as untracked, so what
# this repository leaves behind would be measured against the author's machine,
# and a signing key would stop the commit below.
hermetic_git() {
	env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git "$@"
}

# The working tree as a stranger receives it: every tracked file, committed,
# and nothing else.
#
# Rep1 and Rep2 are the two scenarios this layer cannot reach from the
# published reference. Both need a violation planted in the thing under test —
# a wrapper that writes on entry, a verification run that writes a log — and a
# published revision is exactly what cannot have one planted in it. So the
# repository is consumed from a checkout of the working tree instead, made the
# way a stranger's checkout is made: `git ls-files` and a commit, so nothing
# untracked and nothing the environment has already written comes along. `nix
# flake metadata` reports it as a git tree with a locked revision and no dirt,
# which is what makes the entry below equivalent to the one check_j1_1 makes
# from the reference.
stranger_checkout() {
	local dest=$1 f d
	mkdir -p "$dest" || return 1
	while IFS= read -r -d '' f; do
		d=$(dirname "$f")
		if [ "$d" != . ]; then
			mkdir -p "$dest/$d" || return 1
		fi
		# -a, because one tracked path is a symlink and dereferencing it
		# would commit a second copy of what it points at.
		cp -a "$REPO_ROOT/$f" "$dest/$f" || return 1
	done < <(hermetic_git -C "$REPO_ROOT" ls-files -z)
	hermetic_git -C "$dest" init -q -b main &&
		hermetic_git -C "$dest" add -A &&
		hermetic_git -C "$dest" \
			-c user.name=stranger -c user.email=stranger@example.invalid \
			-c commit.gpgsign=false commit -qm 'the working tree as a stranger receives it'
}

# The tracked files and their contents, which is what Rep1 says must not move.
tracked_manifest() {
	(cd "$1" && hermetic_git ls-files -z | xargs -0 sha256sum)
}

# The state roots the environment declares inside the project, derived from the
# environment itself.
#
# .gitignore is the easy source and the wrong one. It already hides `*.log`
# anywhere in the tree, so a run that dropped a log into the checkout would
# leave `git status` with nothing to report, and an entry added later would
# widen that blind spot in silence. What the environment *declares* is a
# different list with a different owner: every variable the entered shell
# points inside the project, plus every $WORKDIR-relative path in an agent's
# own confinement description. A path under one of those is state the
# environment asked for; a path outside them is residue nobody asked for.
#
# Reduced to the first component because that is the unit the environment
# claims, and because the values below it carry a per-run suffix —
# $TMPDIR/nix-shell.xCOLd5 differs between two entries that are otherwise
# identical.
declared_roots() {
	local project=$1 dump=$2 entry value rest agent manifest tokens
	shift 2
	# git's own store, which is not the environment's to declare and not the
	# repository's content either. Reading the index refreshes it, so a
	# comparison that included it would be measuring the observer.
	local -a roots=(.git)
	while IFS= read -r -d '' entry; do
		value=${entry#*=}
		case $value in
		"$project"/*)
			rest=${value#"$project"/}
			roots+=("${rest%%/*}")
			;;
		esac
	done <"$dump"
	for agent in "$@"; do
		manifest=$(nix build --no-link --print-out-paths --accept-flake-config \
			"$project#confinement-$agent") || return 1
		tokens=$(jq -r '.environment.set_vars | to_entries[] | .value | strings
			| select(startswith("$WORKDIR/")) | ltrimstr("$WORKDIR/") | split("/")[0]' \
			"$manifest") || return 1
		while IFS= read -r rest; do
			if [ -n "$rest" ]; then
				roots+=("$rest")
			fi
		done <<<"$tokens"
	done
	printf '%s\n' "${roots[@]}" | sort -u
}

# The project tree outside those roots: every path, with contents hashed, so
# that a file appearing, changing or vanishing all read the same way.
tree_outside_roots() {
	local project=$1 rootfile=$2 root p
	local -a prune=()
	while IFS= read -r root; do
		prune+=(-path "./$root" -prune -o)
	done <"$rootfile"
	(
		cd "$project" || exit 1
		find . -mindepth 1 "${prune[@]}" -print0 |
			while IFS= read -r -d '' p; do
				if [ -L "$p" ]; then
					printf 'link  %s  %s\n' "$(readlink "$p")" "$p"
				elif [ -d "$p" ]; then
					printf 'dir   %s\n' "$p"
				elif [ -f "$p" ]; then
					printf 'file  %s  %s\n' "$(sha256sum <"$p" | cut -d' ' -f1)" "$p"
				else
					printf 'other %s\n' "$p"
				fi
			done | sort
	)
}

# The control the residue comparison needs: what it covers, rather than what it
# reports. Prints the tracked paths missing from a manifest, so an empty result
# means the comparison had the repository's own files in scope. A root list that
# grew until it swallowed the tree would otherwise compare two empty sets and
# agree.
tracked_paths_missing_from() {
	comm -23 \
		<(hermetic_git -C "$1" ls-files | sed 's|^|./|' | sort) \
		<(awk '{ print $NF }' "$2" | sort)
}

# The expected reach of a session, derived the way check_j1_1's property derives
# it: the project directory, the session's own execution substrate, and the leak
# registry. Journey 7's third `Then` is that these three terms are read out of
# the flake rather than restated in a check, so nothing below names a path.
#
# Taken from a flake reference passed in, not from $REPO_ROOT, because the arm
# that uses it needs the same derivation run against a tree with an entry
# planted in it.
expected_reach() {
	local flake=$1 agent=$2 project=$3 closure
	closure=$(nix build --no-link --print-out-paths --accept-flake-config \
		"$flake#substrate-$agent") || return 1
	{
		printf '%s\n' "$project"
		cat "$closure/store-paths"
		nix eval --json --accept-flake-config "$flake#leakRegistry" \
			--apply "es: builtins.filter (e: builtins.elem \"$agent\" e.agents) es" |
			jq -r '.[].path'
	} | sort -u
}

# One registry entry, added through the file's own `checkEntry` gate rather than
# written straight into the list, so what lands is an entry the type admitted.
#
# Not `sed -i`: BSD sed wants an argument there and GNU sed does not, and this
# layer is the one that has to run on both platforms.
plant_registry_entry() {
	local file=$1 path=$2 agent=$3 tmp=$4
	sed "s|map checkEntry \[ \]|map checkEntry [ { path = \\\"$path\\\"; mode = \\\"read\\\"; agents = [ \\\"$agent\\\" ]; why = \\\"planted by check_j7_1\\\"; whyNotNarrower = \\\"planted by check_j7_1\\\"; } ]|" \
		"$file" >"$tmp" || return 1
	# plan.md's rule for a planted violation: confirm it landed before believing
	# anything the run afterwards reports. A pattern that stopped matching would
	# otherwise leave both sides of the comparison below identical, and the arm
	# would report that the registry has no effect.
	if cmp -s "$file" "$tmp"; then
		return 1
	fi
	mv "$tmp" "$file"
}

# A workflow step, run the way the runner runs it: the `run` body written to a
# file, and the step's `shell` invoked with `{0}` replaced by that file's path.
# Reconstructing the invocation is what makes the control below an observation
# of the workflow rather than of a paraphrase of it kept beside it.
# The script is written outside the working directory, as the runner writes it,
# so running a step leaves nothing in the tree the step is measured against.
workflow_step() {
	local wf=$1 job=$2 stepid=$3 dir=$4 scratch=$5 script shell
	script="$scratch/workflow-step-$stepid"
	yq -r ".jobs.\"$job\".steps[] | select(.id == \"$stepid\") | .run" \
		"$wf" >"$script" || return 1
	[ -s "$script" ] || return 1
	shell=$(yq -r ".jobs.\"$job\".steps[] | select(.id == \"$stepid\") | .shell // \"bash -e {0}\"" \
		"$wf") || return 1
	(cd "$dir" && eval "${shell//\{0\}/$script}")
}

# The `run` body of a step, as text, for the arms that assert about the command
# rather than about its effect.
workflow_step_run() {
	yq -r ".jobs.\"$2\".steps[] | select(.id == \"$3\") | .run" "$1"
}

# Journey 1.1 — a stranger enters the environment from the published reference
# and starts an agent.
#
# The observable is the session's own audit record, not nono's banner and not a
# resolved manifest. Every run writes
# $XDG_STATE_HOME/nono/audit/<id>/session.json, whose `tracked_paths` holds the
# reach granted above the confinement floor. M4b widened the grant from each
# source in turn — the description's `read`, its `allow`, a `--read` flag, the
# working directory consent — and the set moved every time, so it is the set
# plan.md's property is written about rather than a summary of it. The banner
# collapses the floor to a count and the manifest is only the resolution: M4b
# found a manifest reporting the project readwrite for a session with no reach
# into the project at all.
#
# The agent is started by name, from inside the environment, because that is
# what Journey 1 promises. `claude` on PATH is the wrapper (D3) and the raw
# binary is reachable only by store path.
#
# No positive control against confinement (D9): the observable is a set rather
# than a verdict, and an unconfined agent writes no session record at all, so
# the comparison cannot even be attempted. The controls this check does need
# are about the ref and the environment, and they are the first three arms.
check_j1_1() {
	local agent=claude-code binary=claude
	local ref owner repo outside home state project session probe resolved dir
	local metadata registry substrate impure rc out found=0
	local -a sessions=() dirs=()

	ref=$(canonical_ref)

	# Outside the project, because nono refuses to start when a granted path
	# overlaps its own state root, and clean, because nono derives that root
	# from the environment a stranger would arrive with rather than this one.
	outside=$(outside_root j1_1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	home="$outside/home"
	state="$outside/state"
	project="$outside/project"
	mkdir -p "$project" "$outside/bin"

	# A sentinel on *this* shell's PATH, placed before the instrument is built
	# so that anything the instrument carries over carries it too. Nothing
	# executes it; its whole job is to be findable, and the arm below asserts
	# it is not found. Placed after the instrument it could never be, so the
	# control would be one that cannot fail.
	printf '#!/bin/sh\nexit 0\n' >"$outside/bin/agent-sandbox-caller-sentinel"
	chmod +x "$outside/bin/agent-sandbox-caller-sentinel"
	local PATH="$outside/bin:$PATH"

	stranger_env "$home" "$state" "$project"
	project=$(cd "$project" && pwd -P)

	# Control — the reference is a published one.
	#
	# This is the arm plan.md's plant fires: consuming from the working tree
	# instead means a ref that is a path or a dirty git tree, and neither
	# reaches `github` with a locked revision. Owner and repository are parsed
	# out of the literal rather than written twice, so FR-19's single name
	# stays single.
	if [[ ! $ref =~ ^github:[^/]+/[^/]+$ ]]; then
		fail "$(printf 'the canonical reference is not a published github reference: %s' "$ref")"
		return 1
	fi
	owner=${ref#github:}
	owner=${owner%%/*}
	repo=${ref##*/}

	# Diagnostics kept off stdout, not merged into it. Merged, a `nix` warning
	# lands in front of the JSON and jq fails to parse a document that is
	# otherwise fine — which is how a working-tree ref reported a parse error
	# rather than the path type it actually resolved to.
	metadata=$(nix flake metadata --json "$ref" 2>"$outside/metadata.err") || {
		fail "$(printf 'the canonical reference does not resolve: %s\n%s' "$ref" "$(cat "$outside/metadata.err")")"
		return 1
	}
	if ! jq -e --arg o "$owner" --arg r "$repo" \
		'.locked.type == "github" and .locked.owner == $o and .locked.repo == $r and (.locked.rev | type) == "string"' \
		>/dev/null <<<"$metadata"; then
		fail "$(printf 'the reference resolved to something other than a locked revision of %s/%s:\n%s' \
			"$owner" "$repo" "$(jq -c '.locked' <<<"$metadata")")"
		return 1
	fi

	# Control — nothing here reaches outside the lock (P8).
	#
	# Asserted on this file's own text rather than on an outcome, because an
	# impurity flag or an input override added later would make every arm below
	# pass against local state while still reading as an end-to-end check, and
	# neither shows up in anything the run produces.
	#
	# The two patterns are written as character classes so that neither the
	# patterns nor this comment match themselves. Written literally, the guard
	# counted its own three occurrences and failed on the first run — a guard
	# that reports the violation it is made of proves nothing about the code.
	impure=$(grep -c -E -e '-[-]impure' -e '-[-]override-input' "${BASH_SOURCE[0]}" || true)
	if [ "$impure" -ne 0 ]; then
		fail "$(printf 'the end-to-end layer overrides an input or waives purity in %s place(s), so what it enters is not the committed lock' "$impure")"
		found=1
	fi

	# Control — the run inherits nothing from the developing environment.
	#
	# Two halves, because the leak has two shapes. Before the environment is
	# entered no agent may resolve at all, or the check could pass on a machine
	# where the author installed them and the ref contributed nothing. And a
	# sentinel placed on *this* shell's PATH must not resolve inside the run,
	# which is what fires if the instrument ever goes back to inheriting the
	# caller's environment.
	#
	# Resolved against the instrument's own PATH rather than by spawning a
	# shell inside it: on macOS and on a CI runner that PATH holds nix alone,
	# so `sh -c` there would fail to exec and report every agent absent for the
	# wrong reason — a control that cannot fail.
	IFS=: read -r -a dirs <<<"$STRANGER_PATH"
	for probe in claude opencode pi nono; do
		for dir in "${dirs[@]}"; do
			if [ -x "$dir/$probe" ]; then
				fail "$(printf '%s resolves at %s before the environment has been entered, so this check could pass without the reference taking any part' "$probe" "$dir")"
				found=1
			fi
		done
	done

	# `bash` comes from the entered devshell, not from the instrument's PATH:
	# on macOS and on a CI runner that PATH holds nix and nothing else.
	# shellcheck disable=SC2016 # the inner shell expands these, not this one
	probe=$(cd "$project" && env -i "${STRANGER_ENV[@]}" \
		nix develop --accept-flake-config "$ref" --command bash -c \
		'for b in agent-sandbox-caller-sentinel claude; do printf "%s=%s\n" "$b" "$(command -v "$b" || echo ABSENT)"; done' 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		# Resolving the reference goes through the GitHub API, which allows
		# sixty unauthenticated calls an hour *per address*. A few suite runs
		# in one hour exhaust it and this check then goes red on a tree that is
		# perfectly consumable — and reads exactly like a broken end-to-end
		# path, which is the one thing it exists to detect. So the quota is
		# named when it is the cause.
		#
		# Still a failure rather than a skip. A skip here would let the only
		# check that consumes this repository the way a stranger does go quiet
		# whenever the quota is spent, and a shared address spends it faster
		# than one machine can. What changes is that the reader is told which
		# of the two they are looking at, per **P9**.
		#
		# Not pinned to a revision, which would resolve without the API and was
		# the alternative considered. FR-19's claim is that the canonical
		# reference — `HEAD` on it — is consumable, and a pinned check stops
		# making that claim, so the quota is the cheaper thing to live with.
		if grep -qiE 'HTTP error 403|rate limit exceeded' <<<"$probe"; then
			fail "$(printf 'the GitHub API refused to resolve %s: its unauthenticated quota of sixty calls an hour for this address is spent, so this says nothing about whether the reference is consumable. Wait for the reset and run it again.\n%s' \
				"$ref" "$probe")"
			return 1
		fi
		fail "$(printf 'the environment could not be entered from %s: exit %s\n%s' "$ref" "$rc" "$probe")"
		return 1
	fi
	if ! grep -qx 'agent-sandbox-caller-sentinel=ABSENT' <<<"$probe"; then
		fail "$(printf 'the run inherited the calling shell'"'"'s PATH:\n%s' "$probe")"
		found=1
	fi
	resolved=$(sed -n 's/^claude=//p' <<<"$probe")
	case $resolved in
	/nix/store/*) ;;
	*)
		fail "$(printf 'the agent entered from %s does not resolve to a store path, so the name is answered by this machine rather than by the reference: claude=%s' "$ref" "${resolved:-}")"
		return 1
		;;
	esac

	# The stranger's one command, and the whole of SC-5. `--accept-flake-config`
	# because a stranger is not a trusted user, and without it the declared
	# substituter is ignored and three agents are built from source.
	out=$(cd "$project" && env -i "${STRANGER_ENV[@]}" \
		nix develop --accept-flake-config "$ref" --command "$binary" --version 2>&1) && rc=0 || rc=$?
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

	registry=$(nix eval --json --accept-flake-config "$ref#leakRegistry" \
		--apply "es: builtins.filter (e: builtins.elem \"$agent\" e.agents) es") || {
		fail "the leak registry does not evaluate from $ref"
		return 1
	}
	substrate=$(nix build --no-link --print-out-paths --accept-flake-config "$ref#substrate-$agent") || {
		fail "the execution substrate for $agent does not build from $ref"
		return 1
	}

	# The property, from plan.md: granted ∖ floor = {the project} ∪ the substrate
	# ∪ the registry. Every term is derived from the artefact this repository
	# publishes rather than restated here, so adding a tool to the session or an
	# entry to the registry moves both sides at once, and only reach nobody
	# declared can fail this. Both sides come from the reference, so a term
	# taken from the working tree cannot make the comparison agree.
	#
	# The substrate term is what M4c turned from a prefix into a set. Until then
	# the store was granted whole and this comparison could not tell a session
	# that runs 128 paths from one that can read all 67,000: a single granted
	# ancestor satisfied a diff either way. Enumerated, the same diff now fails
	# on one path too many.
	if ! diff -u \
		<({
			printf '%s\n' "$project"
			cat "$substrate/store-paths"
			jq -r '.[].path' <<<"$registry"
		} | sort -u) \
		<(jq -r '.tracked_paths[]' "${sessions[0]}" | sort -u) \
		>"$outside/reach.diff" 2>&1; then
		found=1
		fail "$(printf 'the session reaches more or less than the project, its substrate and the leak registry:\n%s' \
			"$(sed '1,2d' "$outside/reach.diff")")"
	fi

	[ "$found" -eq 0 ]
}

# Rep1 — entering the environment twice changes nothing.
#
# The two things the scenario names fail separately, so they are observed
# separately.
#
# The project's tracked files are compared as content rather than through `git
# status`, because .gitignore is what makes "unchanged" survivable at all: the
# environment writes .tmp, .cache, .config, .local and .agents on entry and
# every one of them is ignored. A status-based assertion would therefore be
# weakened in silence by an entry added to .gitignore later, and tracked
# content cannot be. What git cannot see is covered by the residue arm instead,
# against the roots the environment declares.
#
# The reach is read from the session's own audit record, for the reasons
# check_j1_1 gives: the banner collapses the confinement floor to a count, and a
# manifest is only the resolution rather than the grant.
#
# An equality assertion is the shape most easily satisfied by nothing having
# happened at all, which is the same problem D9 solves for the refusal checks
# from the other side. So the control here is about the content of what is
# compared: the reach is non-empty and holds the workdir, the tracked manifest
# is non-empty, and the residue manifest is shown to cover the repository's own
# files. Two empty sets are byte-identical too.
check_rep1() {
	local agent=claude-code binary=claude
	local outside copy home session missing out rc found=0 i name
	local -a sessions=()

	# Outside the project, because nono refuses to start when a granted path
	# overlaps its own state root, and clean, because nono derives that root
	# from the environment a stranger arrives with rather than this one.
	outside=$(outside_root rep1) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	copy="$outside/checkout"
	home="$outside/home"

	if ! stranger_checkout "$copy"; then
		fail "the working tree could not be checked out as a stranger receives it"
		return 1
	fi
	# Resolved before the environment is entered: the entered shell reports a
	# physical $PWD, and the roots below are derived by matching variable
	# values against it.
	copy=$(cd "$copy" && pwd -P)

	# The same home for both entries, because it is the same stranger entering
	# again; a state root of its own for each, because the audit records are
	# how the second entry is confirmed to have happened rather than been
	# skipped, and one shared root would leave the two indistinguishable.
	for i in 1 2; do
		mkdir -p "$outside/$i"
		stranger_env "$home" "$outside/$i/state" "$copy"

		# `env -0` from inside the entered shell, so the roots come from the
		# environment as entered rather than from a reading of the file that
		# declares it. A credential, because the wrapper's supervised mode is
		# the path a stranger takes; its value is never used.
		# shellcheck disable=SC2016 # the entered shell expands these, not this one
		out=$(cd "$copy" && env -i "${STRANGER_ENV[@]}" \
			ANTHROPIC_API_KEY=rep1-probe-key \
			nix develop --accept-flake-config "$copy" --command bash -c \
			'env -0 >"$1" && exec "$2" --version' _ "$outside/$i/env0" "$binary" 2>&1) && rc=0 || rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "$(printf 'entry %s did not reach a started agent: exit %s\n%s' "$i" "$rc" "$out")"
			return 1
		fi

		# The wrapper's pre-flight runs confined sessions of its own, so the
		# agent's is selected by what it executed rather than by being the only
		# one. Exactly one, per entry, is also the confirmation that the second
		# entry ran.
		sessions=()
		while IFS= read -r session; do
			if jq -e --arg b "/bin/$binary" '.command[0] | endswith($b)' "$session" >/dev/null 2>&1; then
				sessions+=("$session")
			fi
		done < <(find "$outside/$i/state/nono/audit" -mindepth 2 -maxdepth 2 -name session.json)
		if [ "${#sessions[@]}" -ne 1 ]; then
			fail "$(printf 'entry %s produced %s confined %s sessions rather than one, so it cannot be told from an entry that did not happen' \
				"$i" "${#sessions[@]}" "$binary")"
			return 1
		fi
		jq -r '.tracked_paths[]' "${sessions[0]}" | sort -u >"$outside/$i/reach"

		if ! tracked_manifest "$copy" >"$outside/$i/tracked"; then
			fail "$(printf 'the tracked files of the project could not be read after entry %s' "$i")"
			return 1
		fi
		if [ "$i" -eq 1 ]; then
			if ! declared_roots "$copy" "$outside/1/env0" "$agent" >"$outside/roots"; then
				fail "the state roots the environment declares could not be derived"
				return 1
			fi
		fi
		tree_outside_roots "$copy" "$outside/roots" >"$outside/$i/tree"
	done

	# Control — the reach compared is a reach, and it is the project's.
	if [ ! -s "$outside/1/reach" ]; then
		fail 'the session granted no reach at all, so comparing two entries compares nothing'
		return 1
	fi
	if ! grep -qxF "$copy" "$outside/1/reach"; then
		fail "$(printf 'the reach granted does not hold the project directory %s, so it is not the reach this scenario is about:\n%s' \
			"$copy" "$(head -5 "$outside/1/reach")")"
		return 1
	fi

	# Control — the manifests compared hold the repository.
	if [ ! -s "$outside/1/tracked" ]; then
		fail 'the tracked file manifest is empty, so comparing two entries compares nothing'
		return 1
	fi
	missing=$(tracked_paths_missing_from "$copy" "$outside/1/tree")
	if [ -n "$missing" ]; then
		fail "$(printf 'the residue manifest does not cover the repository, so a state root has grown until it hides it:\n%s' "$missing")"
		return 1
	fi

	for name in tracked tree reach; do
		if ! diff -u "$outside/1/$name" "$outside/2/$name" >"$outside/$name.diff" 2>&1; then
			found=1
			case $name in
			tracked) fail "$(printf 'entering a second time changed the tracked files of the project:\n%s' "$(sed '1,2d' "$outside/$name.diff")")" ;;
			tree) fail "$(printf 'entering a second time left residue outside the state roots the environment declares (%s):\n%s' \
				"$(paste -sd' ' "$outside/roots")" "$(sed '1,2d' "$outside/$name.diff")")" ;;
			reach) fail "$(printf 'the second entry granted a different reach:\n%s' "$(sed '1,2d' "$outside/$name.diff")")" ;;
			esac
		fi
	done

	[ "$found" -eq 0 ]
}

# Rep2 — verifying twice changes nothing, and a third time still finds the
# repository it was given.
#
# Three runs rather than two: "no residue a third run would trip over" is a
# claim about the run after the one that repeats, and SC-7 is a property of the
# suite rather than of a single pair.
#
# One layer of the suite, not all of it. The whole suite contains this check, so
# a run of it here would recurse; what a run can contain is the layers below.
# `component` is the one of those that builds artefacts, and a verification run
# that writes into the checkout does it while building rather than while
# evaluating, so it is the layer where residue is most likely to appear.
#
# The residue arm is the one that matters here, and the one .gitignore would
# hide: `*.log` is ignored anywhere in the tree, so a suite that wrote its log
# into the checkout would leave `git status` with nothing to say. Measured
# against the roots the environment declares instead, a log at the root of the
# checkout is residue whether git can see it or not.
check_rep2() {
	local outside copy home missing passed out rc found=0 i name
	local -a runs=(1 2 3)

	outside=$(outside_root rep2) || return 1
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN
	copy="$outside/checkout"
	home="$outside/home"

	if ! stranger_checkout "$copy"; then
		fail "the working tree could not be checked out as a stranger receives it"
		return 1
	fi
	copy=$(cd "$copy" && pwd -P)
	stranger_env "$home" "$outside/state" "$copy"

	# One entry of its own for the roots, so that the three runs compared below
	# are the same command three times rather than one that also reports on
	# itself.
	# shellcheck disable=SC2016 # the entered shell expands this, not this one
	out=$(cd "$copy" && env -i "${STRANGER_ENV[@]}" \
		nix develop --accept-flake-config "$copy" --command bash -c \
		'env -0 >"$1"' _ "$outside/env0" 2>&1) && rc=0 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$(printf 'the environment could not be entered from the checkout: exit %s\n%s' "$rc" "$out")"
		return 1
	fi
	# No agent runs here, so no agent's description is consulted: a run of the
	# verification suite has no business writing under .agents, and if it does,
	# the residue arm should say so.
	if ! declared_roots "$copy" "$outside/env0" >"$outside/roots"; then
		fail "the state roots the environment declares could not be derived"
		return 1
	fi

	for i in "${runs[@]}"; do
		mkdir -p "$outside/$i"
		(cd "$copy" && env -i "${STRANGER_ENV[@]}" \
			nix develop --accept-flake-config "$copy" \
			--command ./scripts/validate.sh --layer component) \
			>"$outside/$i/out" 2>"$outside/$i/err" && rc=0 || rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "$(printf 'verification run %s of 3 did not pass: exit %s\n%s\n%s' \
				"$i" "$rc" "$(cat "$outside/$i/out")" "$(cat "$outside/$i/err")")"
			return 1
		fi
		if ! tracked_manifest "$copy" >"$outside/$i/tracked"; then
			fail "$(printf 'the tracked files of the project could not be read after run %s' "$i")"
			return 1
		fi
		tree_outside_roots "$copy" "$outside/roots" >"$outside/$i/tree"
	done

	# Control — the runs compared ran checks. Two runs that found nothing to do
	# report the same nothing, and the suite's own verdict is where that shows.
	passed=$(sed -n 's/^\([0-9][0-9]*\) checks passed.*$/\1/p' "$outside/1/out")
	if [ -z "$passed" ] || [ "$passed" -eq 0 ]; then
		fail "$(printf 'the verification run reported no checks passed, so repeating it repeats nothing:\n%s' "$(cat "$outside/1/out")")"
		return 1
	fi

	# Control — the manifests compared hold the repository.
	missing=$(tracked_paths_missing_from "$copy" "$outside/1/tree")
	if [ -n "$missing" ]; then
		fail "$(printf 'the residue manifest does not cover the repository, so a state root has grown until it hides it:\n%s' "$missing")"
		return 1
	fi

	for i in 2 3; do
		for name in out tracked tree; do
			if ! diff -u "$outside/1/$name" "$outside/$i/$name" >"$outside/$i.$name.diff" 2>&1; then
				found=1
				case $name in
				out) fail "$(printf 'verification run %s reported a different result from the first:\n%s' "$i" "$(sed '1,2d' "$outside/$i.$name.diff")")" ;;
				tracked) fail "$(printf 'verification run %s changed the tracked files of the project:\n%s' "$i" "$(sed '1,2d' "$outside/$i.$name.diff")")" ;;
				tree) fail "$(printf 'verification run %s left residue outside the state roots the environment declares (%s):\n%s' \
					"$i" "$(paste -sd' ' "$outside/roots")" "$(sed '1,2d' "$outside/$i.$name.diff")")" ;;
				esac
			fi
		done
	done

	[ "$found" -eq 0 ]
}

# Journey 7.1 — the claims are checked on clean machines, for every platform.
#
# Two halves, and only the second observes behaviour.
#
# The first is about the workflow, and can only be about the workflow: nothing
# running on this machine can run a macOS job. So what is checkable here is that
# the description says the right thing and that what it says is not vacuous, and
# every term it is measured against is derived rather than restated — the
# platform set from the flake's own outputs, the substituter and its key from
# the flake's nixConfig, the layer flag from validate.sh's own argument
# handling. An added system, a moved substituter or a renamed flag fails this
# without anyone editing it.
#
# The second half is the discriminator, and the reason the scenario is checkable
# at all. Exit 0 is also what a suite that ran nothing produces, so the arm that
# carries the weight plants an entry in the leak registry and observes the
# expected reach change. Both terms of that expectation come out of the flake —
# the substrate from a built closure, the registry from an evaluation — so an
# expectation written into this file would not have moved.
#
# Control — the reach the comparison job compares is a reach. The workflow's own
# step is extracted and run here, so the artefact that job diffs is known to be
# non-empty and to cover every agent. Two empty files are equal on both
# platforms too, and a comparison of them would be green forever.
check_j7_1() {
	local agent=claude-code
	local wf outside copy matrixjob cmpjob suitecmd digest
	local sys runner want token gained name found=0
	local -a mjobs=() cjobs=() keys=()

	wf="$REPO_ROOT/.github/workflows/verify.yml"
	if [ ! -f "$wf" ]; then
		fail "$(printf 'there is no verification workflow at %s, so nothing runs the suite on a clean machine (FR-13)' "${wf#"$REPO_ROOT"/}")"
		return 1
	fi
	if ! yq -e '.' "$wf" >/dev/null 2>&1; then
		fail "$(printf 'the verification workflow does not parse:\n%s' "$(yq -e '.' "$wf" 2>&1)")"
		return 1
	fi

	# Inside the project, unlike every other scratch directory in this layer:
	# this check reads a file and starts no session, so it fabricates no host
	# home and needs no location outside a session's reach.
	outside=$(mktemp -d "$REPO_ROOT/.tmp/j7_1.XXXXXX")
	# shellcheck disable=SC2064
	trap "rm -rf '$outside'" RETURN

	# Every string the workflow actually says, as opposed to every string that
	# appears in the file. The arms below are about what the runner is told, and
	# the comments explaining them name the very tokens they forbid — grepped
	# against the text, the first two of them failed on this file's own prose.
	yq -r '[.. | select(tag == "!!str")] | .[]' "$wf" >"$outside/strings"

	# One matrixed job, because the platform set is read off it and because a
	# second one would mean two commands rather than the same command twice.
	mapfile -t mjobs < <(yq -r '.jobs | to_entries[] | select(.value.strategy.matrix != null) | .key' "$wf")
	if [ "${#mjobs[@]}" -ne 1 ]; then
		fail "$(printf 'expected exactly one matrixed job, found %s; SC-8 is about one command run per platform, not several' "${#mjobs[@]}")"
		return 1
	fi
	matrixjob=${mjobs[0]}

	# FR-13 — every platform this repository supports, taken from the flake.
	if ! diff -u \
		<(nix eval --json --accept-flake-config "$REPO_ROOT#agentBinaries" \
			--apply builtins.attrNames | jq -r '.[]' | sort) \
		<(yq -r ".jobs.\"$matrixjob\".strategy.matrix.include[].system" "$wf" | sort -u) \
		>"$outside/systems.diff" 2>&1; then
		found=1
		fail "$(printf 'the platforms verified are not the platforms this repository supports:\n%s' \
			"$(sed '1,2d' "$outside/systems.diff")")"
	fi

	# Control — the two jobs are two platforms. Both matrix rows pointed at the
	# same runner image would satisfy every arm above and make the comparison
	# below a diff of a file with itself.
	while read -r sys runner; do
		case ${sys##*-} in
		linux) want=ubuntu ;;
		darwin) want=macos ;;
		*) want='' ;;
		esac
		if [ -z "$want" ]; then
			fail "$(printf 'the matrix names %s, whose operating system this check cannot map to a runner image' "$sys")"
			found=1
		elif [ "${runner%%-*}" != "$want" ]; then
			fail "$(printf '%s is verified on %s rather than a %s image, so the two jobs are not two platforms' "$sys" "$runner" "$want")"
			found=1
		fi
	done < <(yq -r ".jobs.\"$matrixjob\".strategy.matrix.include[] | .system + \" \" + .runner" "$wf")

	if ! yq -r ".jobs.\"$matrixjob\".\"runs-on\"" "$wf" | grep -q 'matrix\.runner'; then
		fail 'the matrixed job does not run on the runner its own matrix names, so the platform column is decorative'
		found=1
	fi
	# FR-13 — no prior agent state. A hosted image is new for every run; a
	# self-hosted one carries whatever the last run left behind.
	if grep -q 'self-hosted' "$outside/strings"; then
		fail 'the suite runs on a self-hosted runner, which carries the prior agent state FR-13 requires to be absent'
		found=1
	fi

	# FR-13 — on every change, rather than when someone remembers.
	mapfile -t keys < <(yq -r '.["on"] | keys | .[]' "$wf")
	for want in push pull_request; do
		if ! printf '%s\n' "${keys[@]}" | grep -qx "$want"; then
			fail "$(printf 'the workflow does not run on %s, so a change can land without the suite having run' "$want")"
			found=1
		fi
	done

	# SC-4 — the exit status is the whole report. A deployment environment waits
	# for a human to approve, and continue-on-error keeps a red step out of the
	# job's status, so either one turns the exit status into a summary of the
	# steps somebody chose to count.
	if [ "$(yq -r '[.jobs[] | select(has("environment"))] | length' "$wf")" -ne 0 ]; then
		fail 'a job waits on a deployment environment, so the run is neither unattended nor decided by its exit status'
		found=1
	fi
	if [ "$(yq -r '[.. | select(tag == "!!map") | select(has("continue-on-error"))] | length' "$wf")" -ne 0 ]; then
		fail 'a step may fail without failing the run, so the exit status no longer separates a passing commit from a failing one (SC-4)'
		found=1
	fi

	suitecmd=$(workflow_step_run "$wf" "$matrixjob" suite)
	if [ -z "$suitecmd" ]; then
		fail "$(printf 'job %s has no step with id "suite", so nothing there runs the verification entry point' "$matrixjob")"
		return 1
	fi
	if ! grep -q 'scripts/validate\.sh' <<<"$suitecmd"; then
		fail "$(printf 'the suite step does not run the verification entry point (FR-12):\n%s' "$suitecmd")"
		found=1
	fi
	# The layer flag is what the plant recorded in plan.md uses, so the arm
	# first establishes that restricting the run is something the entry point
	# still allows. An assertion that an impossible thing is absent is one that
	# can never fail.
	if ! grep -q -- '--layer' "$SCRIPT_DIR/validate.sh"; then
		fail 'the verification entry point no longer takes a layer flag, so the arm below forbids something that cannot happen'
		found=1
	elif grep -q -- '--layer' <<<"$suitecmd"; then
		fail "$(printf 'the workflow runs one layer rather than the suite, so a green commit says nothing about the layers it skipped:\n%s' "$suitecmd")"
		found=1
	fi
	# SC-8 — the same command asserting the same properties. A conditional step
	# or one that reads the matrix is two commands wearing one name.
	if grep -qE 'matrix\.|runner\.os' <<<"$suitecmd"; then
		fail "$(printf 'the suite step branches on the platform, so the two runners do not assert the same properties:\n%s' "$suitecmd")"
		found=1
	fi
	if [ "$(yq -r ".jobs.\"$matrixjob\".steps[] | select(.id == \"suite\") | has(\"if\")" "$wf")" != false ]; then
		fail 'the suite step is conditional, so it does not necessarily run on both platforms (SC-8)'
		found=1
	fi
	# SC-4 again, from the command's side rather than the workflow's: a status
	# swallowed by the shell never reaches the job.
	if grep -qE '\|\||; *true' <<<"$suitecmd"; then
		fail "$(printf 'the suite step discards the entry point'\''s status, so the run reports success whatever the suite found:\n%s' "$suitecmd")"
		found=1
	fi

	# The substituter and its key, read out of the flake rather than written
	# here. nix ignores a flake's nixConfig for anyone who is not a trusted
	# user, and a CI user is not one, so without these on the runner every agent
	# is built from source.
	while read -r token; do
		if ! grep -qF "$token" "$outside/strings"; then
			fail "$(printf 'the flake declares %s and the runner is not given it, so a CI user builds every agent from source' "$token")"
			found=1
		fi
	done < <(nix eval --file "$REPO_ROOT/flake.nix" nixConfig --json |
		jq -r '.["extra-substituters"][], .["extra-trusted-public-keys"][]')

	# FR-20 — the comparison no single machine can make. One job downstream of
	# the matrix, holding the only assertion in this suite that needs both
	# platforms to have run.
	mapfile -t cjobs < <(yq -r ".jobs | to_entries[] | select([.value.needs] | flatten | contains([\"$matrixjob\"])) | .key" "$wf")
	if [ "${#cjobs[@]}" -ne 1 ]; then
		fail "$(printf 'expected exactly one job downstream of %s to compare the platforms, found %s' "$matrixjob" "${#cjobs[@]}")"
		return 1
	fi
	cmpjob=${cjobs[0]}
	if ! yq -r ".jobs.\"$cmpjob\".steps[].run // \"\"" "$wf" | grep -q diff; then
		fail "$(printf 'job %s does not diff what the platforms reported, so nothing compares their reach' "$cmpjob")"
		found=1
	fi
	if ! yq -r ".jobs.\"$matrixjob\".steps[] | select(.uses // \"\" | test(\"upload-artifact\")) | .with.name" \
		"$wf" | grep -q 'matrix\.system'; then
		fail "$(printf 'job %s does not publish one reach artefact per platform, so job %s has nothing to compare' "$matrixjob" "$cmpjob")"
		found=1
	fi

	# Control — the reach that comparison compares. The workflow's own step is
	# run here, against the working tree as a stranger receives it, because a
	# step that produced an empty document would make the comparison agree on
	# every commit forever.
	copy="$outside/checkout"
	if ! stranger_checkout "$copy"; then
		fail 'the working tree could not be checked out as a stranger receives it'
		return 1
	fi
	copy=$(cd "$copy" && pwd -P)
	if ! workflow_step "$wf" "$matrixjob" reach "$copy" "$outside" \
		>"$outside/reach.log" 2>&1; then
		fail "$(printf 'the step that resolves this platform'\''s reach does not run:\n%s' "$(cat "$outside/reach.log")")"
		return 1
	fi
	# Where it writes is read off the step that uploads it, so the document the
	# comparison receives and the document examined here are the same one.
	digest="$copy/$(yq -r ".jobs.\"$matrixjob\".steps[] | select(.uses // \"\" | test(\"upload-artifact\")) | .with.path" "$wf")"
	if [ ! -s "$digest" ]; then
		fail "$(printf 'the reach step produced nothing at %s, so the cross-platform comparison compares two empty documents' "${digest#"$copy"/}")"
		return 1
	fi
	while read -r name; do
		if ! jq -e --arg a "$name" 'has($a)' "$digest" >/dev/null 2>&1; then
			fail "$(printf 'the reach reported for this platform says nothing about %s, so the comparison would not notice that agent diverging' "$name")"
			found=1
		fi
	done < <(nix eval --json --accept-flake-config "$copy#agents" \
		--apply builtins.attrNames | jq -r '.[]')

	# The third `Then` — the expectation is derived, and planting an entry moves
	# it without this file changing.
	if ! expected_reach "$copy" "$agent" "$copy" >"$outside/before"; then
		fail 'the expected reach could not be derived from the checkout'
		return 1
	fi
	# Control — both derived terms are actually in it. A set holding only the
	# project would move when an entry was planted too, and would say nothing
	# about where the rest of it came from.
	if ! grep -q '^/nix/store/' "$outside/before"; then
		fail "$(printf 'the expected reach carries no store path, so the execution substrate is not one of its terms:\n%s' "$(head -5 "$outside/before")")"
		return 1
	fi
	if ! grep -qxF "$copy" "$outside/before"; then
		fail 'the expected reach does not hold the project directory, so it is not the reach this scenario is about'
		return 1
	fi

	if ! plant_registry_entry "$copy/lib/leak-registry.nix" \
		/etc/agent-sandbox-planted "$agent" "$outside/planted"; then
		fail 'the registry entry could not be planted, so this arm would compare a tree with itself'
		return 1
	fi
	if ! expected_reach "$copy" "$agent" "$copy" >"$outside/after"; then
		fail 'the expected reach could not be derived once an entry was planted'
		return 1
	fi
	gained=$(comm -13 "$outside/before" "$outside/after")
	if [ "$gained" != /etc/agent-sandbox-planted ]; then
		fail "$(printf 'planting a registry entry did not move the expected reach by exactly that entry; it moved by:\n%s' "${gained:-nothing}")"
		found=1
	fi

	[ "$found" -eq 0 ]
}
