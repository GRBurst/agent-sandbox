{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.my.hm.features.ai;
  homeDir = config.home.homeDirectory;

  # nvim runs as NVIM_APPNAME=nvf (set by the mnw wrapper), so all of its XDG
  # dirs are ~/.../nvf -- a rule naming "nvim" is a silent no-op. Lazy-loaded
  # plugins spread writes across state (shada, undo, blink-cmp frecency) and
  # cache (fzf-lua, fidget, snacks), so grant those two dirs rather than
  # chasing individual files. Both are read back, so --write (write-only)
  # would trade loud errors for silent data loss.
  # `or false`: checks/eval-assertions.nix imports this module standalone.
  editorEnabled = cfg.sandbox.enable && (config.my.hm.features.nvf.enable or false);

  # The real $XDG_RUNTIME_DIR holds gnome-keyring's secrets+ssh sockets and the
  # D-Bus session bus (desktop/i3.nix, hyprland.nix start the daemon with
  # --components=pkcs11,secrets,ssh), so granting it would undo the profile's
  # own deny_credentials. Redirect instead: nvim's server socket and fzf-lua's
  # serverstart() only need *a* writable dir.
  #
  # It lives under nvim's own state dir, which the grant below already covers,
  # so the redirect costs no extra capability. Do NOT move it under
  # ~/.local/state/nono: nono refuses to grant any path overlapping its own
  # protected state root and the sandbox then fails to initialise.
  sandboxRuntimeDir = "${homeDir}/.local/state/nvf/run";

  editorArgs = lib.optionals editorEnabled [
    "--allow"
    "${homeDir}/.local/state/nvf"
    "--allow"
    "${homeDir}/.cache/nvf"
    # darkman mode; read-only, single file. Silently falls back to light today.
    "--read-file"
    "${homeDir}/.local/state/my-theme/mode"
  ];
  # ~/.local/share/nvf is deliberately absent: mnw is declarative and nothing
  # writes there. Add it only if a real failure names it.

  # nono has no general --env flag; it inherits the parent environment. This
  # must stay alias-scoped -- home.sessionVariables would break the real
  # desktop session, where $XDG_RUNTIME_DIR must stay /run/user/$UID.
  envPrefix = lib.optional editorEnabled "XDG_RUNTIME_DIR=${sandboxRuntimeDir}";

  # "claude" -> "XDG_RUNTIME_DIR=~/.local/state/nono/run nono run \
  #              --profile nolabs-ai/claude --allow-cwd <editor grants> -- claude"
  mkSandboxAlias = command: profile:
    lib.concatStringsSep " "
    (envPrefix
      ++ ["nono" "run" "--profile" profile]
      ++ cfg.sandbox.args
      ++ ["--" command]);

  sandboxAliases = lib.mapAttrs mkSandboxAlias cfg.sandbox.profiles;
in {
  options.my.hm.features.ai = {
    enable =
      lib.mkEnableOption "AI tooling (agent CLIs and the nono sandbox)"
      // {default = true;};

    packages = lib.mkOption {
      type = with lib.types; listOf package;
      default = with pkgs; [
        aichat
        antigravity-ide
        claude-code
        claude-monitor
        codex
        gemini-cli-bin
        lmstudio
        opencode
        opencode-claude-auth
        pi-coding-agent
        # openai-whisper  # disabled: drags torch + piper-tts + faster-whisper (all uncached)
      ];
      description = "AI tool packages installed into the user profile.";
    };

    sandbox = {
      enable =
        lib.mkEnableOption "run AI agents through the nono sandbox"
        // {default = true;};

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.nono;
        description = "Package providing the nono sandbox CLI.";
      };

      profiles = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = {
          claude = "nolabs-ai/claude";
          opencode = "opencode-claude"; # local profile written below
          pi = "pi-claude"; # local profile written below
        };
        description = ''
          Command name mapped to its nono profile. Each entry generates the alias
          `<command> = nono run --profile <profile> <sandbox.args> -- <command>`.
          Add a sandboxed tool by adding one attribute here.
        '';
      };

      args = lib.mkOption {
        type = with lib.types; listOf str;
        default = ["--allow-cwd"] ++ editorArgs;
        description = ''
          Extra `nono run` flags applied to every generated sandbox alias.
          `--allow-cwd` grants the working directory at the level the profile
          declares; without it nono prompts for it on every run.

          When `my.hm.features.nvf` is enabled this also grants nvim's own state
          and cache dirs (NVIM_APPNAME=nvf), without which an editor opened
          inside an agent errors on every keystroke and every write. `/run/user/*`
          and the X11 socket are deliberately never granted -- see the comments
          on sandboxRuntimeDir and editorArgs.
        '';
      };

      autoInstallPacks = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Set NONO_AUTO_MIGRATE so nono installs missing registry packs
          non-interactively. nono no longer ships built-in profiles, so without
          this the first sandboxed run prompts before fetching from
          registry.nono.sh.
        '';
      };
    };

    aliases = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = {};
      description = ''
        Additional AI aliases. Overrides a generated sandbox alias of the same
        name, which is how a single tool gets extra `nono run` flags.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = cfg.packages ++ lib.optional cfg.sandbox.enable cfg.sandbox.package;

    # mkDefault so shell-specific modules (features/zsh.nix) can still override
    # individual aliases -- same reasoning as features/shellAliases.nix.
    home.shellAliases =
      lib.mapAttrs (_: lib.mkDefault)
      ((lib.optionalAttrs cfg.sandbox.enable sandboxAliases) // cfg.aliases);

    home.sessionVariables =
      lib.optionalAttrs (cfg.sandbox.enable && cfg.sandbox.autoInstallPacks)
      {NONO_AUTO_MIGRATE = "1";};

    # pi reads ~/.pi, not XDG. Unlike opencode-claude-auth there is no store
    # path to point at: pi-claude-auth is npm-only, fetched into
    # ~/.pi/agent/npm on first run. The unscoped `pi-claude-auth` on npm is
    # deprecated in favour of the scoped name.
    # ponytail: runtime npm fetch, unpinned. Package it with buildNpmPackage and
    # switch to `extensions = ["<store path>"]` if reproducibility bites.
    home.file.".pi/agent/settings.json".text = builtins.toJSON {
      packages = ["npm:@pankajudhas81/pi-claude-auth"];
    };

    # nvim will not mkdir $XDG_RUNTIME_DIR, and nothing else creates this path.
    home.activation = lib.optionalAttrs editorEnabled {
      nonoSandboxRuntimeDir =
        lib.hm.dag.entryAfter ["writeBoundary"]
        ''run mkdir -p -m 0700 "${sandboxRuntimeDir}"'';
    };

    xdg.configFile =
      {
        # opencode scans ~/.config/opencode/{plugin,plugins}/*.{ts,js} at startup
        # (symlinks followed), so no opencode.jsonc entry is needed. Export only
        # ClaudeAuthPlugin: the legacy loader path invokes *every* export as a
        # plugin, and dist/index.js also exports ten non-plugin helpers.
        "opencode/plugin/claude-auth.js".text = ''
          export { ClaudeAuthPlugin } from "${pkgs.opencode-claude-auth}/lib/node_modules/opencode-claude-auth/dist/index.js";
        '';
      }
      // lib.optionalAttrs cfg.sandbox.enable {
        "nono/profiles/opencode-claude.json".text = builtins.toJSON {
          "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";
          # Union of both packs: opencode-claude-auth refreshes an expired token by
          # shelling out to `claude -p`, so the nested claude needs its pack's
          # grants (~/.claude rw, ~/.cache/claude, /tmp/claude-$UID) too.
          extends = ["nolabs-ai/opencode" "nolabs-ai/claude"];
          meta = {
            name = "opencode-claude";
            description = "opencode with Claude Code credential access for opencode-claude-auth";
          };
          # open_urls is replace-on-override rather than append, so without this
          # the claude pack (last base) drops opencode's openai/github origins.
          open_urls = {
            allow_origins = [
              "https://auth.openai.com"
              "https://github.com"
              "https://claude.ai"
              "https://claude.com"
              "https://api.anthropic.com"
              "https://platform.claude.com"
            ];
            allow_localhost = true;
          };
        };

        "nono/profiles/pi-claude.json".text = builtins.toJSON {
          "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";
          # Same reasoning as opencode-claude above: pi-claude-auth reads Claude
          # Code's OAuth credentials from ~/.claude/.credentials.json, so pi
          # needs the claude pack's ~/.claude rw, ~/.cache/claude and
          # /tmp/claude-$UID grants.
          extends = ["nolabs-ai/pi" "nolabs-ai/claude"];
          meta = {
            name = "pi-claude";
            description = "pi with Claude Code credential access for pi-claude-auth";
          };
          # pi installs npm packages into ~/.pi/agent/npm at runtime and keeps
          # settings, trust.json and sessions under ~/.pi. Stated explicitly
          # rather than assumed from the pi pack; filesystem.allow appends
          # across bases, unlike open_urls.
          filesystem.allow = ["$HOME/.pi"];
          # Replace-on-override, so the claude pack (last base) would otherwise
          # drop whatever origins the pi pack declares. npm registry access does
          # not belong here -- the packs leave network.block false and open_urls
          # governs browser opening, not sockets.
          open_urls = {
            allow_origins = [
              "https://claude.ai"
              "https://claude.com"
              "https://api.anthropic.com"
              "https://platform.claude.com"
            ];
            allow_localhost = true;
          };
        };
      };
  };
}
