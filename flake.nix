{
  description = "Per-project confined agent sessions";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      leakRegistry = import ./lib/leak-registry.nix { inherit (nixpkgs) lib; };
      agents = import ./lib/agents.nix { inherit (nixpkgs) lib; };
      mkConfinement = import ./lib/confinement.nix {
        inherit (nixpkgs) lib;
        inherit pkgs agents;
        registry = leakRegistry;
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

      # One built description per agent. It is a package because it is an
      # artefact a human is meant to be able to read: `nix build .#confinement-…`
      # then `jq . result` is the whole review, with no session involved.
      packages.${system} = nixpkgs.lib.mapAttrs' (
        name: _: nixpkgs.lib.nameValuePair "confinement-${name}" (mkConfinement name)
      ) agents;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
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
        ];

        # Everything local, so every tool's config, cache and temp path resolves
        # inside the project. This is the single source of truth; .envrc repeats
        # TMPDIR and XDG_CACHE_HOME only because nix needs them before it can
        # read this file, and check_bootstrap_mirror fails if the two drift.
        # Paths are relative to the shell's cwd, which direnv and `nix develop`
        # set to the repo root.
        shellHook = ''
          export TMPDIR="$PWD/.tmp"
          # zsh writes heredoc bodies here rather than to $TMPDIR
          export TMPPREFIX="$PWD/.tmp/zsh"
          export XDG_CACHE_HOME="$PWD/.cache"
          export npm_config_cache="$PWD/.cache/npm"
          export NPM_CONFIG_USERCONFIG="$PWD/.npmrc" # need not exist
          export DOCKER_CONFIG="$PWD/.docker"
          export CURL_HOME="$PWD/.config" # curl reads $CURL_HOME/.curlrc first
          mkdir -p "$TMPDIR" "$XDG_CACHE_HOME"
        '';
      };
    };
}
