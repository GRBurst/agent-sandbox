{
  description = "Per-project confined agent sessions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The sole source of the confinement mechanism and of every agent, pinned to
    # a revision rather than a branch so that "the agent this description was
    # written against" (P8) names something.
    #
    # Its nixpkgs is deliberately not followed. The input pins 07e1d92cdc0e and
    # this flake pins 0954f7ee2f6b, so a `follows` would rebuild nono and all
    # four agents from source and lose cache.numtide.com entirely; M4b measured
    # the unfollowed build at 6.7s, all of it copying. What a `follows` buys is
    # one nixpkgs in the closure, and nothing here is built against both.
    llm-agents.url = "github:numtide/llm-agents.nix/5aad5f64e621fc35fed0fddcc2b6e17ab662cf78";
  };

  # A record of where the binaries come from, not a mechanism that fetches them.
  # nix ignores this block for anyone who is not a trusted user and says so:
  # "ignoring untrusted flake configuration setting 'extra-substituters'". So a
  # stranger reads it here to know what to trust, and docs/HANDBOOK.md says what
  # to do about it. Removing it would leave no written answer to "where did this
  # nono come from".
  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  outputs =
    { nixpkgs, llm-agents, ... }:
    let
      inherit (nixpkgs) lib;

      # The two systems the agents are actually available for: M4b read the
      # input's own outputs and found x86_64-linux, aarch64-linux and
      # aarch64-darwin, with no x86_64-darwin. genAttrs rather than flake-utils
      # (D7) — a new input is not worth six lines.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forSystems = lib.genAttrs systems;

      leakRegistry = import ./lib/leak-registry.nix { inherit lib; };
      agents = import ./lib/agents.nix { inherit lib; };

      # Everything that needs a system, in one place, so that adding a system
      # adds nothing but a string above.
      forSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          agentPkgs = llm-agents.packages.${system};
          mkConfinement = import ./lib/confinement.nix {
            inherit lib pkgs agents;
            registry = leakRegistry;
          };
          mkEntryPoint = import ./lib/confined-agent.nix {
            inherit pkgs agentPkgs agents;
            confinement = mkConfinement;
          };
        in
        {
          inherit pkgs agentPkgs mkConfinement;

          # Keyed by the derivation's own name, which writeShellApplication took
          # from the agent's `meta.mainProgram`. `nix build .#claude` and the
          # name a stranger types are then the same string by construction (D3),
          # rather than by a second list saying so.
          entryPoints = lib.listToAttrs (
            map (e: lib.nameValuePair e.name e) (map mkEntryPoint (lib.attrNames agents))
          );
        };
    in
    {
      # FR-3. Exposed so the registry is readable without a build, and so
      # check_registry asserts what the flake resolves rather than re-parsing the
      # file. `leakRegistryCheckEntry` is the entry type as a function: applying
      # it to a candidate is how anything, the check included, finds out whether
      # the registry would accept it.
      leakRegistry = leakRegistry.entries;
      leakRegistryCheckEntry = leakRegistry.checkEntry;

      # FR-1. Exposed so a check reads the agent table the flake resolves rather
      # than parsing lib/agents.nix, which is how the description and the
      # assertions about it are kept from drifting apart.
      inherit agents;

      packages = forSystems (
        system:
        let
          s = forSystem system;
        in
        # One built description per agent. It is a package because it is an
        # artefact a human is meant to be able to read: `nix build .#confinement-…`
        # then `jq . result` is the whole review, with no session involved.
        lib.mapAttrs' (name: _: lib.nameValuePair "confinement-${name}" (s.mkConfinement name)) agents
        # One entry point per agent, under the agent's own command name.
        // s.entryPoints
        # The pinned mechanism, so a check can invoke the nono this environment
        # ships rather than whichever one the developing host has on PATH. On
        # this machine those differ by a minor version, and the host's is the
        # one PATH finds first.
        // {
          inherit (s.agentPkgs) nono;
        }
      );

      devShells = forSystems (
        system:
        let
          s = forSystem system;
        in
        {
          default = s.pkgs.mkShell {
            packages =
              (with s.pkgs; [
                just
                jq
                yq-go
                yamlfmt
                yamllint
                mdformat
                nixfmt
                bash
                # AGENTS.md's format-and-lint table names both, and until now they
                # resolved only from a user profile, which under §3 means the lint step
                # was not reproducible for anyone else.
                shellcheck
                shfmt
              ])
              # The mechanism, so `nono profile show` in a review reads the same
              # version the entry points enforce with.
              ++ [ s.agentPkgs.nono ]
              # The agents, each under its own name and each confined (D3). The
              # raw binary stays reachable only by store path.
              ++ lib.attrValues s.entryPoints;

            # Everything local, so every tool's config, cache and temp path resolves
            # inside the project. This is the single source of truth; .envrc repeats
            # TMPDIR, XDG_CACHE_HOME and XDG_DATA_HOME only because nix needs them
            # before it can read this file, and check_bootstrap_mirror fails if the
            # two drift. Paths are relative to the shell's cwd, which direnv and
            # `nix develop` set to the repo root.
            shellHook = ''
              export TMPDIR="$PWD/.tmp"
              # zsh writes heredoc bodies here rather than to $TMPDIR
              export TMPPREFIX="$PWD/.tmp/zsh"
              export XDG_CACHE_HOME="$PWD/.cache"
              export XDG_DATA_HOME="$PWD/.local/share"
              # nono reads its own configuration from here, and M1e watched it
              # fall back to the host's $HOME/.config when the directory named
              # did not exist — so host configuration would decide what a
              # confined session may reach. Created below, not merely named.
              export XDG_CONFIG_HOME="$PWD/.config"
              export npm_config_cache="$PWD/.cache/npm"
              export NPM_CONFIG_USERCONFIG="$PWD/.npmrc" # need not exist
              export DOCKER_CONFIG="$PWD/.docker"
              export CURL_HOME="$PWD/.config" # curl reads $CURL_HOME/.curlrc first
              mkdir -p "$TMPDIR" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
            '';
          };
        }
      );
    };
}
