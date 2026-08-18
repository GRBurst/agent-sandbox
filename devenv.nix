{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: {
  packages = with pkgs; [
    git
  ];

  # https://devenv.sh/processes/
  # processes.dev.exec = "${lib.getExe pkgs.watchexec} -n -- ls -la";

  # 2. Automatically generate the DevContainer configuration
  devcontainer = {
    enable = true;

    settings = {
      name = "Isolated AI Sandbox";
      image = "mcr.microsoft.com/devcontainers/base:debian";
      remoteUser = "vscode";

      # 3. Add official DevContainer features
      features = {
        # Installs the Nix package manager natively inside the container
        "ghcr.io/devcontainers/features/nix:1" = {};

        # Securely bridges your host's Docker socket into the container
        # Works on Linux (NixOS) and Apple Silicon (Docker Desktop/OrbStack)
        "ghcr.io/devcontainers/features/docker-outside-of-docker:1" = {};
      };
      # 4. Strict Granular Mounts for Skills & Credentials
      # We do NOT mount the state directories (e.g., ~/.local/state/claude-code)
      # to ensure project memories never leak across environments.
      mounts = [
        "source=\${localEnv:HOME}/.config/opencode,target=/home/vscode/.config/opencode,type=bind,consistency=cached"
        "source=\${localEnv:HOME}/.config/claude-code,target=/home/vscode/.config/claude-code,type=bind,consistency=cached"
        "source=\${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind,consistency=cached"
        "source=\${localEnv:HOME}/.pi/agent,target=/home/vscode/.pi/agent,type=bind,consistency=cached"
      ];

      # Activate direnv when the container starts
      postCreateCommand = "direnv allow";
    };
  };

  enterShell = ''
    echo "🤖 Isolated AI Workspace Initialized"
    echo "Available Agents: claude, opencode, pi"^
  '';
}
