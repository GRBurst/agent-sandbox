# FR-2 / D3. The entry point a stranger types.
#
# The wrapper takes the agent's own command name, so `claude` inside the
# environment *is* the confined session and the raw binary is reachable only by
# store path. The alternative considered in plan.md was a `confined-` prefix,
# which leaves the unconfined name working and makes confinement the thing you
# have to remember; a shell alias was rejected outright because an alias does
# not survive `nix develop -c`, which is how every check and every CI job runs.
#
# mkEntryPoint ∷ name → derivation exposing /bin/<the agent's mainProgram>
{
  lib,
  pkgs,
  agentPkgs,
  agents,
  confinement,
}:
name:
let
  # P9: a name that is not in the table is an error, not a session that merely
  # looks confined.
  a = agents.${name} or (throw "agent-sandbox: no such agent: ${name}");
  agent = a.package agentPkgs;
  profile = confinement name;

  # Read from the package rather than restated, so the name this shadows and the
  # binary it execs cannot come apart.
  binary =
    agent.meta.mainProgram
      or (throw "agent-sandbox: ${name} declares no meta.mainProgram, so there is no name to shadow");
in
pkgs.writeShellApplication {
  name = binary;

  # The pinned mechanism, ahead of whatever the host has. On the developing
  # machine `nono` resolves from a user profile at a different minor version, and
  # AGENTS.md §3 is explicit that a tool resolving only from a user profile is
  # not available at all.
  #
  # git is here for FR-23's copy below, and is the same derivation the session's
  # own substrate is rooted at, so it adds nothing to the closure.
  #
  # jq, coreutils and findutils are FR-25's, and they widen nothing the session
  # can see: this script is the supervisor, running outside the boundary before
  # `nono run` is reached, so its closure is not the enumerated substrate. Named
  # rather than left to the host's PATH, because AGENTS.md §3 counts a tool that
  # resolves only from a user profile as absent.
  runtimeInputs = [
    agentPkgs.nono
    pkgs.git
    pkgs.jq
    pkgs.coreutils
    pkgs.findutils
  ];

  text = ''
    # nono reads its own configuration from $XDG_CONFIG_HOME, and M1e watched it
    # fall back to the host's $HOME/.config when the directory named did not
    # exist — host configuration deciding what a confined session may reach.
    # Creating it here rather than defaulting it, because a default hidden in a
    # wrapper would be a second place P1's variables are decided.
    mkdir -p "''${XDG_CONFIG_HOME:?not set; enter the environment (nix develop / direnv) rather than running this from the store}"

    # The profile cannot carry either of these: nono reserves the NONO_ prefix
    # and its validator rejects a set_vars entry using it. An agent session is
    # not the place to discover that the mechanism updated itself mid-run (P8).
    export NONO_NO_UPDATE_CHECK=1

    # A denial is the environment working. On a terminal nono follows it with a
    # review offering to save the denied path as a grant in a user profile, and
    # here that offer can only mislead: $XDG_CONFIG_HOME is inside the project,
    # so the file lands in the checkout, and the description below is named on
    # the command line, which R5 measured beats a discovered profile. It would
    # write something that reads as a widening of the confinement and can never
    # take effect. Suppressing the offer withholds no information: the
    # denial is still reported, and a path an agent genuinely needs belongs in
    # the description or the leak registry, where it has to justify itself.
    export NONO_NO_SAVE_PROMPT=1

    # FR-10 / R6. Refuse rather than start unconfined. Embedded rather than
    # sourced so the entry point depends on nothing outside its own closure.
    PREFLIGHT_PROFILE=${profile}
    ${builtins.readFile ./preflight.sh}
    preflight_or_die

    # FR-23 / D11 / R10. The session's GIT_CONFIG_GLOBAL names a file in the
    # project, so the toolchain never searches the home directory for one and a
    # host directive — `credential.helper`, `core.hooksPath` — cannot direct it.
    # That direction on its own would leave the session with no commit identity,
    # so the author's name and address are copied out of the host here. Only
    # those two keys: they are not credential material, and the copy is visible
    # in the file it produces rather than hidden in a variable.
    #
    # Written by the entry point and not by the shell hook, because a stranger
    # running `nix run <ref>#${binary}` never enters a shell. Create-if-absent,
    # because that is what makes entering twice change nothing and is also the
    # override FR-23 asks for: whatever the file already says wins over the host,
    # and nothing here ever rewrites it.
    agent_sandbox_git_config="$PWD/.agents/git/config"
    if [ ! -e "$agent_sandbox_git_config" ]; then
      # --get exits 1 on an unset key, and this script runs under `set -e`.
      agent_sandbox_git_name="$(git config --global --get user.name || true)"
      agent_sandbox_git_email="$(git config --global --get user.email || true)"

      # A host with no identity of its own leaves no file at all, so a commit
      # fails with git's own "Please tell me who you are" (P9) rather than being
      # attributed to a placeholder this environment invented — and a host that
      # gains one later is still picked up.
      if [ -n "$agent_sandbox_git_name" ] || [ -n "$agent_sandbox_git_email" ]; then
        mkdir -p "$PWD/.agents/git"
        {
          printf '# Written by agent-sandbox: the identity a confined session commits under.\n'
          printf '# Copied from the host once. Edit freely — an existing file is never rewritten.\n'
          printf '[user]\n'
          if [ -n "$agent_sandbox_git_name" ]; then
            printf '\tname = %s\n' "$agent_sandbox_git_name"
          fi
          if [ -n "$agent_sandbox_git_email" ]; then
            printf '\temail = %s\n' "$agent_sandbox_git_email"
          fi
        } >"$agent_sandbox_git_config"
      fi
    fi

    # FR-25. The one host location a session reads on purpose. The declaration
    # arrives in a variable from the calling environment — the same channel the
    # parent `.envrc` uses — and never from a file inside a project, which is
    # what keeps R5 true by construction rather than by a check: a project that
    # cannot name the surface cannot widen its own reach.
    #
    # Colon-separated, like PATH, and so a directory whose name contains a colon
    # cannot be declared. That is the same limitation PATH has had for fifty
    # years and it needs no mechanism of its own.
    agent_sandbox_surfaces=()
    agent_sandbox_reads=()
    if [ -n "''${AGENT_SANDBOX_SKILLS:-}" ]; then
      IFS=: read -r -a agent_sandbox_declared <<<"''${AGENT_SANDBOX_SKILLS}"
      for agent_sandbox_dir in "''${agent_sandbox_declared[@]}"; do
        [ -n "$agent_sandbox_dir" ] || continue

        # Refuse rather than guess. A relative entry would resolve against
        # whatever directory the agent was started in, so the same declaration
        # would grant different things in different projects (P9).
        case "$agent_sandbox_dir" in
          /*) ;;
          *)
            printf 'agent-sandbox: AGENT_SANDBOX_SKILLS names a relative path: %s\n' "$agent_sandbox_dir" >&2
            printf 'agent-sandbox: every entry must be an absolute directory.\n' >&2
            exit 78
            ;;
        esac
        if [ ! -d "$agent_sandbox_dir" ]; then
          printf 'agent-sandbox: AGENT_SANDBOX_SKILLS names something that is not a directory: %s\n' "$agent_sandbox_dir" >&2
          exit 78
        fi

        # Resolved here, because the grant and the pointing must name the same
        # path. A symlinked declaration granted by its link name reaches nothing.
        agent_sandbox_dir="$(cd "$agent_sandbox_dir" && pwd -P)"
        agent_sandbox_surfaces+=("$agent_sandbox_dir")

        # --read and not --allow. M8f ran both: read-only refuses the session's
        # write and leaves the surface byte-identical, while --allow lets the
        # session edit the consumer's own skills. FR-25 lends the surface.
        #
        # Each declared directory by name, and no ancestor — M8f confirmed a
        # grant on the directory itself is enough, so there is no reason to
        # widen to a parent that also holds credentials and history (R9).
        agent_sandbox_reads+=(--read "$agent_sandbox_dir")
      done
    fi

    # The pointing, written before the session starts because it has to be there
    # when the agent looks. Every artefact lands inside the project, so a
    # consumer can read what their session was told, and nothing is copied: a
    # copy would answer for the surface as it was at some earlier moment.
    ${
      let
        s = a.skillSurface;
        target = s.path "$PWD";
      in
      if s.kind == "symlink-children" then
        ''
          # One link per skill, for the reason recorded in the table: the agent
          # keeps its own bookkeeping in this directory, so the directory itself
          # must stay writable and local.
          mkdir -p "${target}"
          # Prune first, so a surface the consumer stopped declaring stops
          # arriving. Only symlinks are removed: a real directory here is the
          # consumer's own skill and none of this environment's business.
          find "${target}" -mindepth 1 -maxdepth 1 -type l -delete
          for agent_sandbox_dir in ''${agent_sandbox_surfaces+"''${agent_sandbox_surfaces[@]}"}; do
            for agent_sandbox_skill in "$agent_sandbox_dir"/*; do
              [ -d "$agent_sandbox_skill" ] || continue
              ln -sfn "$agent_sandbox_skill" "${target}"/"$(basename "$agent_sandbox_skill")"
            done
          done
        ''
      else
        ''
          # Merged into whatever is already there. The agent rejects an unknown
          # top-level key outright, and this file also carries settings this
          # environment did not put there — pi keeps its own under the same
          # name — so writing it whole would discard them. The declared roots
          # replace the previous ones rather than accumulating, which is what
          # makes running this twice change nothing.
          mkdir -p "$(dirname "${target}")"
          ${
            if s.owned then
              ''
                # Except where the file is this environment's alone. Then there is
                # nothing in it to preserve and an agent's own edits in it to throw
                # away, so it starts empty every time. `owned`'s description in
                # lib/agents.nix records what opencode leaves behind on the way out
                # and why a merge cannot survive reading it back.
                printf '{}\n' >"${target}"''
            else
              ''[ -f "${target}" ] || printf '{}\n' >"${target}"''
          }
          if [ "''${#agent_sandbox_surfaces[@]}" -gt 0 ]; then
            agent_sandbox_roots="$(jq -n '$ARGS.positional' --args "''${agent_sandbox_surfaces[@]}")"
          else
            agent_sandbox_roots='[]'
          fi
          # An empty declaration removes the key rather than writing an empty
          # array, so a machine that declares nothing leaves a file this
          # environment cannot be told apart from the consumer's own — which is
          # Journey 8's second scenario, and P8's idempotence, in one line.
          #
          # The containers on the way to it go too. Removing `.skills.paths` and
          # leaving `"skills": {}` behind would still be this environment's
          # fingerprint on a file it was asked to stop touching, and an empty
          # container carries no setting a consumer could lose.
          #
          # The failure path is written out because M9a met it. jq reads strict
          # JSON and nothing else, so a file with a comment or a trailing comma
          # in it ends the entry point on `jq: parse error`, which names neither
          # this environment nor the file it could not read, and `set -e` takes
          # the shell down before the `mv`, leaving the half-written temporary
          # behind for the next run to trip over. Both are answered here: the
          # message says who failed, on what, and what to do (P9), and the
          # temporary is removed on the way out (P8). Every file this reaches is
          # one this environment owns, so a parse error is a real defect and not
          # a consumer's formatting choice — which is the other half of M9a, and
          # the reason `skillSurface.path` no longer names a file the agent
          # itself edits.
          if ! jq --argjson roots "$agent_sandbox_roots" \
            --argjson at ${lib.escapeShellArg (builtins.toJSON (lib.splitString "." (lib.removePrefix "." s.key)))} \
            'def prune($p):
               if ($p | length) == 0 then .
               else (if (getpath($p) | . == {} or . == []) then delpaths([$p]) else . end) | prune($p[0:-1])
               end;
             if ($roots | length) > 0
             then setpath($at; $roots)
             else delpaths([$at]) | prune($at[0:-1])
             end' \
            "${target}" >"${target}.agent-sandbox.tmp"; then
            rm -f "${target}.agent-sandbox.tmp"
            printf 'agent-sandbox: cannot point %s at its skills.\n' ${lib.escapeShellArg name} >&2
            printf '  file: %s\n' "${target}" >&2
            printf '  reason: it is not valid JSON, and this environment writes that file.\n' >&2
            printf '  fix: delete it and enter the environment again.\n' >&2
            exit 78
          fi
          mv "${target}.agent-sandbox.tmp" "${target}"
        ''
    }

    # --allow-cwd is not decoration. M4b ran the same profile with and without
    # it: `workdir.access = "readwrite"` sets the *level* of the working
    # directory grant, while the flag is the run-time consent that makes the
    # grant happen at all. Without it a non-interactive session skips the prompt
    # and reaches nothing but the store, and the resolved manifest still claims
    # the project readwrite — so the manifest cannot be used to notice this.
    exec nono run \
      --profile ${profile} \
      --workdir "$PWD" \
      --allow-cwd \
      ''${agent_sandbox_reads+"''${agent_sandbox_reads[@]}"} \
      -- ${agent}/bin/${binary} "$@"
  '';

  meta = {
    inherit (agent.meta) mainProgram;
    description = "${name}, confined to the project by nono";
  };
}
