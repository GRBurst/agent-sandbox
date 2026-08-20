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
  runtimeInputs = [
    agentPkgs.nono
    pkgs.git
  ];

  text = ''
    # nono reads its own configuration from $XDG_CONFIG_HOME, and M1e watched it
    # fall back to the host's $HOME/.config when the directory named did not
    # exist — host configuration deciding what a confined session may reach.
    # Creating it here rather than defaulting it, because a default hidden in a
    # wrapper would be a second place P1's variables are decided.
    mkdir -p "''${XDG_CONFIG_HOME:?not set; enter the environment (nix develop / direnv) rather than running this from the store}"

    # The profile cannot carry this: nono reserves the NONO_ prefix and its
    # validator rejects a set_vars entry using it. An agent session is not the
    # place to discover that the mechanism updated itself mid-run (P8).
    export NONO_NO_UPDATE_CHECK=1

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
      -- ${agent}/bin/${binary} "$@"
  '';

  meta = {
    inherit (agent.meta) mainProgram;
    description = "${name}, confined to the project by nono";
  };
}
