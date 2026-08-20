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
  runtimeInputs = [ agentPkgs.nono ];

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
