# Technical Specification: `agent-sandbox.nix`

This document defines the complete architecture, file layout, Nix option schema, and execution contracts for `agent-sandbox.nix`—a reusable Flake-based sandboxing framework for AI coding agents (`opencode`, `claude`, `pi`) on NixOS and Linux hosts.

---

## 1. Architectural Overview & Goals

- **Kernel-Level Sandboxing (`nono` / Landlock):** Uses Linux Landlock LSM via `nono` to enforce file access controls at zero startup cost, bypassing Docker dependency overhead while supporting native host user ownership (no UID/GID issues).
- **Per-Project & Per-Agent State Persistence:** Scopes SQLite databases, session transcripts, and memory banks strictly to `${XDG_STATE_HOME}/ai-sandboxes/<project_name>/<agent_name>`, persisting sessions across reboots and isolating instances across projects.
- **Neovim Host Socket Routing:** Binds Neovim's remote server IPC socket into the sandbox, allowing agents to request host file editing (`nvim --server ... --remote`) without exposing host editor state or undo trees.
- **Granular Credential Sharing & Plugin Auto-Wiring:** Exposes shared API authentication files (e.g., `~/.claude/.credentials.json`) as precise single-file grants paired with automatic agent plugin configuration.

---

## 2. Repository File Hierarchy

```text
agent-sandbox.nix/
├── flake.nix                  # Flake outputs (devenvModules, flakeModules, lib)
├── modules/
│   ├── devenv.nix            # Integration module for devenv-based projects
│   └── flake-module.nix      # Integration module for flake-parts / pure flake shells
├── lib/
│   ├── mkSandboxWrapper.nix  # Generates nono/env wrapper binaries for agents
│   ├── profileBuilder.nix    # Generates nono JSON profiles per project/agent
│   └── nvimSocket.nix        # Resolves host Neovim socket paths
└── templates/
    ├── devenv/               # Starter template using devenv
    │   ├── devenv.yaml
    │   ├── devenv.nix
    │   └── .envrc
    └── flake/                # Starter template using standard flake.nix
        ├── flake.nix
        └── .envrc

```

---

## 3. Module Option Schema

The module exposes identical option structures for both `devenv` (`devenvModules.default`) and standard Flake shells (`flakeModules.default`).

| Option Path                           | Type                            | Default                        | Description                                                                                              |
| ------------------------------------- | ------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `ai-sandbox.enable`                   | `bool`                          | `false`                        | Enables sandboxed agent environment for the project.                                                     |
| `ai-sandbox.projectName`              | `str`                           | `""`                           | Name used for scoping state under `~/.local/state/ai-sandboxes/<name>/`. Defaults to directory basename. |
| `ai-sandbox.backend`                  | `enum ["nono", "devcontainer"]` | `"nono"`                       | Sandboxing backend mechanism.                                                                            |
| `ai-sandbox.agents`                   | `listOf str`                    | `["opencode", "claude", "pi"]` | Enabled agent tools.                                                                                     |
| `ai-sandbox.sharedCredentials.claude` | `bool`                          | `true`                         | Exposes `$HOME/.claude/.credentials.json` and enables Claude auth plugins.                               |
| `ai-sandbox.editor.neovimSocket`      | `bool`                          | `true`                         | Routes `$EDITOR` to host Neovim IPC socket inside `$XDG_RUNTIME_DIR`.                                    |
| `ai-sandbox.extraAllowPaths`          | `listOf str`                    | `[]`                           | Additional host filesystem paths granted read-write access inside the sandbox.                           |

---

## 4. Component Implementation Details

### 4.1 Flake Interface (`flake.nix`)

```nix
{
  description = "Pluggable, isolated AI agent sandbox for Nix projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, llm-agents, ... }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      devenvModules.default = import ./modules/devenv.nix { inherit inputs; };
      flakeModules.default = import ./modules/flake-module.nix { inherit inputs; };

      lib = {
        mkSandboxWrapper = import ./lib/mkSandboxWrapper.nix { inherit inputs; };
        profileBuilder = import ./lib/profileBuilder.nix { inherit nixpkgs; };
      };

      templates = {
        devenv = {
          path = ./templates/devenv;
          description = "devenv project integrated with agent-sandbox.nix";
        };
        flake = {
          path = ./templates/flake;
          description = "Pure flake project integrated with agent-sandbox.nix";
        };
      };
    };
}

```

---

### 4.2 Sandbox Profile & Wrapper Builder (`lib/mkSandboxWrapper.nix`)

```nix
{ inputs }:

{ pkgs
, agentName
, projectName
, sharedClaude ? true
, enableNvim ? true
, extraPaths ? []
}:

let
  llmPkgs = inputs.llm-agents.packages.${pkgs.stdenv.system};
  agentPkg = llmPkgs.${agentName} or (throw "Unknown agent package: ${agentName}");
  nonoPkg = inputs.llm-agents.packages.${pkgs.stdenv.system}.nono or pkgs.nono;

  # Path Definitions
  stateBase = "$HOME/.local/state/ai-sandboxes/${projectName}/${agentName}";
  cacheBase = "$HOME/.cache/ai-sandboxes/${projectName}/${agentName}";
  nvimSocketPath = "$XDG_RUNTIME_DIR/nvim.sock";

  # Dynamic Nono Profile Configuration
  nonoProfile = pkgs.writeText "${agentName}-${projectName}-profile.json" (builtins.toJSON {
    "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";
    extends = [ "nolabs-ai/${agentName}" ];
    meta = { name = "${projectName}-${agentName}"; };
    filesystem = {
      allow = [
        stateBase
        cacheBase
      ] ++ extraPaths;
      allow_file = pkgs.lib.optionals sharedClaude [
        "$HOME/.claude/.credentials.json"
      ];
      deny = [
        "$HOME/.zsh_history.local"
        "$XDG_CONFIG_HOME/zsh"
      ];
    };
  });

in pkgs.writeShellScriptBin agentName ''
  set -euo pipefail

  STATE_DIR="${stateBase}"
  CACHE_DIR="${cacheBase}"

  # Lazily bootstrap project-agent state directories
  mkdir -p -m 0700 "$STATE_DIR" "$CACHE_DIR"

  # Environment Exports
  export XDG_STATE_HOME="$STATE_DIR"
  export TMPDIR="$CACHE_DIR"

  ${pkgs.lib.optionalString enableNvim ''
    if [ -S "${nvimSocketPath}" ]; then
      export EDITOR="${pkgs.neovim}/bin/nvim --server ${nvimSocketPath} --remote"
      export VISUAL="$EDITOR"
    fi
  ''}

  ${pkgs.lib.optionalString (agentName == "opencode" && sharedClaude) ''
    export OPENCODE_ENABLE_CLAUDE_AUTH="true"
  ''}

  # Execute Sandboxed Binary
  exec ${nonoPkg}/bin/nono run \
    --profile "${nonoProfile}" \
    --allow-cwd \
    -- ${agentPkg}/bin/${agentName} "$@"
''

```

---

### 4.3 `devenv` Module (`modules/devenv.nix`)

```nix
{ inputs }:

{ config, lib, pkgs, ... }:

let
  cfg = config.ai-sandbox;

  # Derive project name from config or directory name
  pName = if cfg.projectName != ""
          then cfg.projectName
          else builtins.baseNameOf (builtins.toString config.devenv.root);

  mkWrapper = agentName: inputs.self.lib.mkSandboxWrapper {
    inherit pkgs agentName;
    projectName = pName;
    sharedClaude = cfg.sharedCredentials.claude;
    enableNvim = cfg.editor.neovimSocket;
    extraPaths = cfg.extraAllowPaths;
  };

in {
  options.ai-sandbox = {
    enable = lib.mkEnableOption "AI Agent Sandbox";

    projectName = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Unique project identifier for scoping storage under ~/.local/state/ai-sandboxes/";
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "nono" "devcontainer" ];
      default = "nono";
      description = "Sandboxing runtime backend";
    };

    agents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "opencode" "claude" "pi" ];
      description = "List of agent CLIs to wrap and expose in environment";
    };

    sharedCredentials.claude = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Expose ~/.claude/.credentials.json and set auto-authentication flags";
    };

    editor.neovimSocket = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Connect container/sandbox $EDITOR to host Neovim IPC socket";
    };

    extraAllowPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional filesystem paths to grant to the sandbox profile";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = map mkWrapper cfg.agents;

    enterShell = ''
      echo "🤖 Isolated AI Sandbox active for project [${pName}]"
      echo "State Directory: $HOME/.local/state/ai-sandboxes/${pName}/"
    '';
  };
}

```

---

## 5. Consumption Examples

### 5.1 Usage via `devenv.nix`

`devenv.yaml`:

```yaml
inputs:
  nixpkgs:
    url: github:NixOS/nixpkgs/nixpkgs-unstable
  ai-sandbox:
    url: github:your-org/agent-sandbox.nix
```

`devenv.nix`:

```nix
{ pkgs, inputs, ... }:

{
  imports = [
    inputs.ai-sandbox.devenvModules.default
  ];

  ai-sandbox = {
    enable = true;
    projectName = "client-alpha";
    agents = [ "opencode" "claude" ];
    sharedCredentials.claude = true;
    editor.neovimSocket = true;
  };
}

```

---

### 5.2 Usage via Pure Flake (`flake.nix`)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    ai-sandbox.url = "github:your-org/agent-sandbox.nix";
  };

  outputs = { self, nixpkgs, ai-sandbox }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          (ai-sandbox.lib.mkSandboxWrapper {
            inherit pkgs;
            agentName = "opencode";
            projectName = "backend-service";
            sharedClaude = true;
            enableNvim = true;
          })
          (ai-sandbox.lib.mkSandboxWrapper {
            inherit pkgs;
            agentName = "claude";
            projectName = "backend-service";
            sharedClaude = true;
            enableNvim = true;
          })
        ];
      };
    };
}

```

---

## 6. Verification and Security Assertions

When implemented, the sandbox MUST satisfy the following runtime assertions:

1. **State Isolation Check:**
   Running `opencode` in Project A writes history strictly into `~/.local/state/ai-sandboxes/ProjectA/opencode/`. Running `opencode` in Project B must return an empty/clean state history.
2. **Cross-Agent Isolation Check:**
   `claude` cannot access `~/.local/state/ai-sandboxes/ProjectA/opencode/` and vice versa.
3. **Host History Non-Exfiltration:**
   Agents cannot read `$HOME/.zsh_history`, `$HOME/.bash_history`, or `$XDG_CONFIG_HOME/zsh/` even if executed within `$HOME`.
4. **Editor Socket Delegation:**
   Executing `$EDITOR main.py` inside the sandboxed agent environment opens `main.py` in the active host Neovim instance without transferring Neovim's process permissions or plugin state to the sandbox.
