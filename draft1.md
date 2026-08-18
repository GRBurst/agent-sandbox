## Technical Specification: `ai-sandbox.nix`

### 1. Repository Layout

```text
ai-sandbox.nix/
├── flake.nix                  # Flake outputs (modules, packages, lib)
├── modules/
│   ├── devenv.nix            # devenv module integration
│   └── flake-module.nix      # Pure flake devShell / module integration
├── lib/
│   ├── mkSandboxWrapper.nix  # Nix function generating nono/devcontainer CLI wrappers
│   └── profileBuilder.nix    # Generates nono JSON profiles per project/agent
└── templates/
    ├── devenv/               # Starter template for devenv users
    └── flake/                # Starter template for pure Flake users

```

---

### 2. Module Schema (`ai-sandbox` Options)

The Flake exports module options compatible with both `devenv` and custom `flake.nix` setups.

| Option Path                           | Type                            | Default            | Purpose                                                                             |
| ------------------------------------- | ------------------------------- | ------------------ | ----------------------------------------------------------------------------------- |
| `ai-sandbox.enable`                   | `bool`                          | `false`            | Enables the sandboxed workspace.                                                    |
| `ai-sandbox.projectName`              | `str`                           | `$(basename $PWD)` | Name used to scope host storage.                                                    |
| `ai-sandbox.backend`                  | `enum ["nono", "devcontainer"]` | `"nono"`           | Choose kernel Landlock (`nono`) or Docker container.                                |
| `ai-sandbox.agents.<name>.enable`     | `bool`                          | `true`             | Toggles individual agents (`opencode`, `claude`, `pi`).                             |
| `ai-sandbox.sharedCredentials.claude` | `bool`                          | `true`             | Allows single-file grant to `~/.claude/.credentials.json` & activates auth plugins. |
| `ai-sandbox.editor.neovimSocket`      | `bool`                          | `true`             | Maps host Neovim RPC socket to sandbox `$XDG_RUNTIME_DIR/nvim.sock`.                |

---

### 3. Core Implementation Specification

#### `flake.nix`

```nix
{
  description = "Pluggable, isolated AI agent workspace for Nix projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
    devenv.url = "github:cachix/devenv";
  };

  outputs = { self, nixpkgs, llm-agents, devenv, ... }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      # Custom devenv module export
      devenvModules.default = import ./modules/devenv.nix { inherit inputs; };

      # Flake module for standard flake setups
      flakeModules.default = import ./modules/flake-module.nix { inherit inputs; };

      # Standalone helper functions
      lib = {
        mkSandboxWrapper = import ./lib/mkSandboxWrapper.nix { inherit inputs; };
      };
    };
}

```

#### `modules/devenv.nix` (Core Logic)

```nix
{ inputs }:

{ config, lib, pkgs, ... }:

let
  cfg = config.ai-sandbox;
  llmPkgs = inputs.llm-agents.packages.${pkgs.stdenv.system};

  # Paths & Identifiers
  pName = if cfg.projectName != "" then cfg.projectName else "${builtins.baseNameOf config.devenv.root}";
  hostHome = "$HOME";
  stateRoot = "${hostHome}/.local/state/ai-sandboxes/${pName}";
  cacheRoot = "${hostHome}/.cache/ai-sandboxes/${pName}";

  # Neovim Socket Routing
  nvimSocketPath = "$XDG_RUNTIME_DIR/nvim.sock";

  # Helper to generate nono wrapped binaries
  mkAgentWrapper = agentName: agentPkg: pkgs.writeShellScriptBin agentName ''
    set -euo pipefail

    STATE_DIR="${stateRoot}/${agentName}"
    CACHE_DIR="${cacheRoot}/${agentName}"

    mkdir -p -m 0700 "$STATE_DIR" "$CACHE_DIR"

    export XDG_STATE_HOME="$STATE_DIR"
    export TMPDIR="$CACHE_DIR"

    ${lib.optionalString cfg.editor.neovimSocket ''
      export EDITOR="nvim --server ${nvimSocketPath} --remote"
      export VISUAL="$EDITOR"
    ''}

    ${lib.optionalString (agentName == "opencode" && cfg.sharedCredentials.claude) ''
      export OPENCODE_ENABLE_CLAUDE_AUTH="true"
    ''}

    exec ${pkgs.llm-agents.nono}/bin/nono run \
      --profile ${agentName}-local \
      --allow-cwd \
      --allow "$STATE_DIR" \
      --allow "$CACHE_DIR" \
      ${lib.optionalString cfg.sharedCredentials.claude "--allow-file $HOME/.claude/.credentials.json"} \
      -- ${agentPkg}/bin/${agentName} "$@"
  '';

in {
  options.ai-sandbox = {
    enable = lib.mkEnableOption "AI Agent Sandbox";
    projectName = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Directory key used under ~/.local/state/ai-sandboxes/";
    };
    sharedCredentials.claude = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Expose ~/.claude/.credentials.json and auto-enable auth plugins.";
    };
    editor.neovimSocket = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Connect container/sandbox $EDITOR to host Neovim socket.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [
      (mkAgentWrapper "opencode" llmPkgs.opencode)
      (mkAgentWrapper "claude" llmPkgs.claude-code)
      (mkAgentWrapper "pi" llmPkgs.pi)
    ];

    enterShell = ''
      echo "🤖 Isolated AI Sandbox active for project [${pName}]"
      echo "State stored at: ${stateRoot}/<agent>"
    '';
  };
}

```

---

### 4. Downstream Project Consumption Examples

#### Example A: Usage in `devenv.nix`

Add the Flake input to `devenv.yaml` or `flake.nix`, then configure `devenv.nix`:

```nix
{ pkgs, inputs, ... }:

{
  imports = [
    inputs.ai-sandbox.devenvModules.default
  ];

  ai-sandbox = {
    enable = true;
    projectName = "my-client-app";
    sharedCredentials.claude = true;
    editor.neovimSocket = true;
  };
}

```

#### Example B: Usage in Pure `flake.nix` (Without `devenv`)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    ai-sandbox.url = "github:your-org/ai-sandbox.nix";
  };

  outputs = { self, nixpkgs, ai-sandbox }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          (ai-sandbox.lib.mkSandboxWrapper {
            inherit pkgs system;
            agent = "opencode";
            projectName = "my-flake-project";
            allowClaudeCredentials = true;
          })
        ];
      };
    };
}

```

---

### 5. Execution & Lifecycle Flow

1. **Activation:** User enters directory (`cd my-project`). `direnv` evaluates Nix code.
2. **Directory Bootstrapping:** Wrapper scripts lazily instantiate `~/.local/state/ai-sandboxes/<project>/<agent>` with `0700` permissions.
3. **Process Execution:** Launching `opencode` invokes `nono run`, restricting kernel syscalls via Landlock.
4. **Editor Delegation:** Running `$EDITOR file.ts` inside agent tools sends an RPC call over Neovim's host IPC socket without sharing Neovim internal state.
5. **Session Continuation:** Re-entering the directory days later rebinds the exact same state path, restoring SQLite DBs and session transcripts seamlessly.
