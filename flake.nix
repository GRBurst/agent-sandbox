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
    {
      nixpkgs,
      llm-agents,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # The two systems this environment is verified on. M4b read the input's own
      # outputs and found the agents available for three — x86_64-linux,
      # aarch64-linux and aarch64-darwin, with no x86_64-darwin — so aarch64-linux
      # is left out for want of a runner rather than for want of a package, and
      # declaring a system nothing has ever entered would claim more than is known.
      # genAttrs rather than flake-utils (D7) — a new input is not worth six lines.
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
          inherit (pkgs.stdenv.hostPlatform) isLinux;

          # M4c criterion 1. One list, used both as the devShell's packages and
          # as the closure roots the session is granted, so the PATH a session
          # runs with and the substrate it may read are the same expression and
          # cannot drift. Roots are package attributes rather than restated
          # outputs: PATH carries jq's `bin` output while `jq^out` is a different
          # store path, and naming the wrong one denies a tool the session can
          # see.
          #
          # strace is here because the integration layer observes denials with
          # it, and AGENTS.md §3 means a check may not depend on the host having
          # it. Linux only, so devShells.aarch64-darwin.default keeps evaluating.
          sessionTools =
            (with pkgs; [
              # The justfile is where AGENTS.md §4's format-and-lint table is
              # runnable rather than remembered. It wraps no assertion of its
              # own: scripts/validate.sh stays the verification entry point.
              just
              jq
              yq-go
              yamlfmt
              yamllint
              mdformat
              nixfmt
              bash
              # AGENTS.md's format-and-lint table names both, and until now they
              # resolved only from a user profile, which under §3 means the lint
              # step was not reproducible for anyone else.
              shellcheck
              shfmt
              # The agent's Bash tool reaches for git before anything else, and
              # until M4c it resolved from the host user profile or not at all.
              git
              # The workflow pins every action to a commit SHA, and `just pins`
              # is what proves a pin still matches the tag its comment claims —
              # `pinact run -fix=false --verify-comment`, since -fix=false on
              # its own only asks whether the pin is a SHA at all. Under
              # AGENTS.md §3 that proof may not depend on the maintainer having
              # pinact in a user profile.
              pinact
            ])
            ++ lib.optionals isLinux [ pkgs.strace ];

          # M4c criterion 3. glibc's compiled-in default archive lives at
          # /run/current-system/sw/lib/locale/locale-archive, outside the store
          # and outside every grant, and M3c watched a session fail on it after
          # the closure grant was otherwise complete. Setting the variable
          # without granting what it names only moves the denial, so the archive
          # is a closure root as well as a value. glibcLocalesUtf8 (2 MiB) rather
          # than glibcLocales (222 MiB): the session needs UTF-8, not every
          # locale on earth.
          localeRoots = lib.optionals isLinux [ pkgs.glibcLocalesUtf8 ];
          substrateVars = lib.optionalAttrs isLinux {
            LOCALE_ARCHIVE = "${pkgs.glibcLocalesUtf8}/lib/locale/locale-archive";
          };

          # The reach a session needs in order to execute at all, derived rather
          # than declared. Exposed as its own output so a check reads the closure
          # from a built path instead of importing a derivation during
          # evaluation.
          #
          # nono is deliberately not a root. The supervisor runs outside the
          # sandbox it builds, so a session that cannot read it is a session that
          # cannot re-enter the mechanism, which is R4 reinforced by absence
          # rather than argued. The entry points are absent for the same reason:
          # M4c measured a confined agent unable to start a second one.
          substrateFor =
            name:
            pkgs.closureInfo {
              rootPaths = sessionTools ++ localeRoots ++ [ (agents.${name}.package agentPkgs) ];
            };

          mkConfinement = import ./lib/confinement.nix {
            inherit
              lib
              pkgs
              agents
              substrateVars
              ;
            registry = leakRegistry;
            substrate = substrateFor;
          };
          mkEntryPoint = import ./lib/confined-agent.nix {
            inherit
              lib
              pkgs
              agentPkgs
              agents
              ;
            confinement = mkConfinement;
          };
        in
        {
          inherit
            pkgs
            agentPkgs
            mkConfinement
            sessionTools
            substrateFor
            ;

          # Keyed by the derivation's own name, which writeShellApplication took
          # from the agent's `meta.mainProgram`. `nix build .#claude` and the
          # name a stranger types are then the same string by construction (D3),
          # rather than by a second list saying so.
          entryPoints = lib.listToAttrs (
            map (e: lib.nameValuePair e.name e) (map mkEntryPoint (lib.attrNames agents))
          );

          # The same mapping the other way round: which command each agent
          # answers to. Read back off the entry point rather than written down,
          # so a check that iterates the table can name the command it must run
          # without a second list to drift from D3.
          entryPointNames = lib.mapAttrs (name: _: (mkEntryPoint name).name) agents;
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

      # FR-1 again, from the command's side. `agents` says which agents exist;
      # this says what a human types to start each one. A check asserting a
      # property over every agent needs both, and deriving the second from the
      # entry point the flake builds is what keeps the two from disagreeing.
      agentBinaries = forSystems (system: (forSystem system).entryPointNames);

      packages = forSystems (
        system:
        let
          s = forSystem system;
        in
        # One built description per agent. It is a package because it is an
        # artefact a human is meant to be able to read: `nix build .#confinement-…`
        # then `jq . result` is the whole review, with no session involved.
        lib.mapAttrs' (name: _: lib.nameValuePair "confinement-${name}" (s.mkConfinement name)) agents
        # One substrate per agent, for the same reason: `nix build
        # .#substrate-claude-code` then `cat result/store-paths` is how a human
        # reads what a session may execute, and how a check reads it without
        # importing a derivation during evaluation.
        // lib.mapAttrs' (name: _: lib.nameValuePair "substrate-${name}" (s.substrateFor name)) agents
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
              # The same list the substrate is derived from (M4c), so every tool
              # this environment puts on a session's PATH is one the session was
              # granted. Two things below are on PATH and deliberately not
              # granted: the mechanism and the entry points. A session that
              # could read either could try to re-enter the mechanism, and R4
              # says it must not.
              #
              # This says what *this environment* grants, and not the whole of
              # what a session may read — the sentence used to claim the second
              # and it was not true. nono applies its own default group
              # `system_read_linux_core` (and `system_read_macos`) whatever the
              # description says, and that group grants read over /bin, /sbin,
              # /usr/bin, /lib, /lib64, /etc/ssl and two dozen further host
              # paths, for every one of them that exists on the host. Measured:
              # the shipped description declares `groups.include: []` and names
              # no /usr anywhere, yet `nono why --path /usr/bin --op read`
              # answers `granted_path`. So on a host carrying /usr/bin/gpg a
              # session can read a host binary nobody here declared.
              #
              # Opting out is possible and was measured rather than assumed:
              # `groups.exclude` removes the reach and the profile still
              # validates strict, but a session under it loses git and cannot
              # complete an HTTPS handshake, because nono manages PATH itself
              # and /etc/ssl goes with the group. So it is a piece of work
              # rather than a one-line correction, and M10a chose to state the
              # reach instead. docs/HANDBOOK.md carries it as known drift.
              s.sessionTools
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
