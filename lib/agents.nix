# The agent table. One entry per agent this environment knows how to confine.
#
# FR-1 names three agents, so the set is closed: a name that is not here is an
# error rather than a default, and callers look an agent up as
# `agents.${name} or (throw …)`. P9 forbids a lookup miss producing something
# that merely looks like a confined session.
#
# All three of FR-1's agents are here, each landing beside the check that
# observes it: an entry whose behaviour nothing exercises would assert nothing
# about an agent while appearing to support it.
#
# Each entry carries only what some check already exercises. `credential`
# arrives with M7, which asserts the credential's shape. The alternative is a
# table whose fields nothing reads, which is how a table starts lying.
#
# There is no `binary` field. plan.md sketched one, but the package already
# states its command name in `meta.mainProgram` — `claude`, `nono`, `opencode`,
# `pi` — and a second copy here would be a thing to keep true for no assertion's
# sake. lib/confined-agent.nix reads it from the package it is about to run, so
# the name the entry point shadows cannot disagree with the binary it execs.
{ lib }:
let
  inherit (lib) types mkOption;

  entryType = types.submodule {
    options = {
      package = mkOption {
        type = types.functionTo types.package;
        description = ''
          The agent, as a function of llm-agents.nix's package set for the
          system being built. A function rather than a value because this table
          is system-independent and that set is not; taken from that one input
          because FR-1's agents and the mechanism that confines them come from
          the same pin, so an upgrade moves them together.
        '';
      };
      groups = mkOption {
        type = types.listOf types.str;
        description = ''
          Confinement groups to include by name. Empty unless a group grants
          strictly less than writing its paths out would: M3c measured
          `filesystem.read` granting read alone, so the reason a group was
          preferred does not hold, and a group's extra paths are reach nobody
          here asked for.
        '';
      };
      credentialServices = mkOption {
        type = types.listOf types.str;
        description = ''
          Credential routes to enable by name, mediated by the supervisor.
          Names, not definitions: M7a measured the mechanism shipping a policy
          for six providers, so the upstream, the injected header and the
          endpoint policy come from it rather than from here, and a name it
          does not know is refused before a session starts with the list of the
          ones it does. What reaches the session is a per-session substitute;
          the real value stays with the supervisor, which is FR-6.
        '';
      };
      stateVars = mkOption {
        type = types.functionTo (types.attrsOf types.str);
        description = ''
          The agent's state relocation, as a function of the working directory
          placeholder. No value may name a location outside it: a value that
          carries a path lies under the placeholder, and a value that carries a
          setting rather than a path carries no path separator at all. That is
          FR-4, and `check_state_vars` asserts it over every entry in this
          table rather than over a named one.
        '';
      };
      skillSurface = mkOption {
        type = types.submodule {
          options = {
            kind = mkOption {
              type = types.enum [
                "json-array"
                "symlink-children"
              ];
              description = ''
                How this agent is told where to look. `M8e` measured all three
                and found no mechanism they share: two take a list of extra
                roots in a configuration file they read, and one has no
                additive mechanism at all, so the only way to point it is a
                symlink per skill under the root its own variable already
                moved. FR-25 asks that the surface arrive for every agent, so
                the difference lives here rather than in a special case.
              '';
            };
            path = mkOption {
              type = types.functionTo types.str;
              description = ''
                Where this environment writes the pointing, as a function of
                the working directory placeholder — the configuration file for
                `json-array`, the directory the symlinks go in for
                `symlink-children`. It lies under the placeholder for the same
                reason `stateVars` does: the pointing is a project artefact, so
                a consumer can read what their session was told.
              '';
            };
            key = mkOption {
              type = types.str;
              default = "";
              description = ''
                For `json-array`, the jq path of the array the roots are merged
                into, as `.skills.paths`. Merged rather than written, because
                the file also carries settings this environment did not put
                there. Empty for `symlink-children`, which has no file.
              '';
            };
          };
        };
        description = ''
          FR-25's half of the table: what this environment does with the
          authoring surface a consumer declared, once the grant has been made.
          It points, and never copies — a copy would go stale silently, and P8
          asks that running the wrapper twice change nothing.
        '';
      };
    };
  };

  checkAgent =
    agent:
    (lib.evalModules {
      modules = [
        { options.agent = mkOption { type = entryType; }; }
        { inherit agent; }
      ];
    }).config.agent;
in
lib.mapAttrs (_: checkAgent) {

  claude-code = {
    # M4b checked the license gate before scoping `allowUnfree` to this package
    # as planned, and there is no gate: the input's claude-code carries
    # `meta.license.fullName = "Unfree"` with `free = true`, so `nix build`
    # succeeds in pure evaluation with allowUnfree set nowhere. Instantiating a
    # second nixpkgs to grant that permission would grant it for nothing and
    # lose cache.numtide.com along with it, which is the `follows` argument
    # again.
    package = agentPkgs: agentPkgs.claude-code;

    # No group at all, per D15. The store is absent from the confinement floor
    # and a session without it cannot execute the agent — M1g observed the child
    # exit 127 with nono reporting the binary readable but unexecutable — but
    # `nix_runtime` pays for the store with six further paths, two of them under
    # the home directory. M3c measured a path grant on the store conferring read
    # alone, so the substrate is granted from the leak registry instead, where
    # its justification is written down and `check_sc1` keeps it in view.
    #
    # git_config is deliberately not here. It grants read on the host's git
    # configuration, and read-only is no protection when the danger is that a
    # directive in that file runs a program inside the boundary — M1c observed a
    # session pick up the host's `credential.helper = cache` and try to start a
    # daemon. FR-23 wants the toolchain pointed at configuration this
    # environment wrote, which the confinement does with GIT_CONFIG_GLOBAL.
    groups = [ ];

    # M7a measured this one line doing the whole of Journey 4.1: the real value
    # is read by the supervisor out of its own environment, and the session sees
    # 64 hex characters that are not it. `credential_providers` was the shape D1
    # first chose, and it is withdrawn — its phantom exists only once a live
    # token exchange has been captured, so nothing unattended can exercise it.
    credentialServices = [ "anthropic" ];

    # M1g set these by observation, not by documentation. Thirteen variables
    # were candidates and ten received nothing; these three carry the whole of
    # what the agent otherwise writes under the home directory.
    #
    # No XDG_* variable appears, because M1g found the agent ignores all four
    # despite XDG_CONFIG_HOME occurring 26 times in the binary. Occurrence is
    # not behaviour. M8b drove the subagent and lock paths that a one-turn
    # session never reaches and found the other ten still receive nothing, so
    # they stay unset: setting one is not free. CLAUDE_JOB_DIR is an output the
    # agent sets on itself and derives a job identity from, and
    # CLAUDE_SECURESTORAGE_CONFIG_DIR falls back to the home directory when it
    # is set empty while using the relocated root when it is unset.
    stateVars = w: {
      CLAUDE_CONFIG_DIR = "${w}/.agents/claude";
      CLAUDE_CODE_TMPDIR = "${w}/.agents/claude/tmp";
      CLAUDE_CODE_REMOTE_MEMORY_DIR = "${w}/.agents/claude/memory";

      # P8: the developing host had this set already, so without it the
      # environment would be idempotent only there. An agent that updates itself
      # is not the agent this description was written against.
      DISABLE_AUTOUPDATER = "1";
    };

    # The awkward one. M8e found this agent has no additive mechanism at all:
    # CLAUDE_CONFIG_DIR moves the whole global surface rather than adding to it,
    # and there is no settings key naming an extra skill root. So the pointing
    # is a symlink per skill inside the root that variable already moved.
    #
    # Per skill, never the `skills` directory itself. M8e measured the agent
    # writing manifest.json and a `synced` marker inside `skills/`, so a symlink
    # at that level would aim its own writes at a read-only host directory. M8f
    # then measured the child form working: the agent reads through the link
    # into a directory mode 0555 and keeps its bookkeeping in the writable level
    # above.
    skillSurface = {
      kind = "symlink-children";
      path = w: "${w}/.agents/claude/skills";
    };
  };

  opencode = {
    package = agentPkgs: agentPkgs.opencode;

    # Nothing a group grants is wanted here either, for D15's reason.
    groups = [ ];

    # The same service name as claude-code, and deliberately no more: M8c
    # measured this agent reading ANTHROPIC_API_KEY and ANTHROPIC_BASE_URL
    # straight out of its environment, which is exactly the pair the mediated
    # route injects. Declaring the name here mints this agent a substitute of
    # its own — check_j5_1 asserts the substitutes are distinct across the
    # table — so nothing about it reads claude-code's state, and check_r3's
    # list of routed names does not grow because no new service is named.
    credentialServices = [ "anthropic" ];

    # Almost empty, and that is the finding. M8c measured `opencode debug
    # paths` reporting nine roots: eight are derived from the four XDG_* roots
    # and TMPDIR, which the confinement already places under the working
    # directory for every agent, and the ninth *is* $HOME, which no variable
    # can move. So there is no opencode-specific relocation variable to set —
    # of the 84 OPENCODE_* names in the binary, not one moves a root.
    #
    # OPENCODE_DISABLE_MODELS_FETCH and OPENCODE_DISABLE_LSP_DOWNLOAD are
    # deliberately absent. They gate downloads that land in the project's own
    # cache and bin roots, so they are not confinement's business, and setting
    # a variable that changes nothing here is the fallacy M8b corrected.
    stateVars = _w: {
      # P8, for claude-code's reason: nix owns the version, and an agent that
      # updates itself is not the agent this description was written against.
      OPENCODE_DISABLE_AUTOUPDATE = "1";
    };

    # `skills.paths`, which M8e found covers skills and only skills —
    # OPENCODE_CONFIG_DIR moves agents, commands, modes and plugins but not
    # these. The file is the global configuration under the relocated config
    # root, and the roots are merged into it rather than written over it,
    # because the agent rejects an unknown top-level key outright and a
    # consumer's own settings may already be there.
    skillSurface = {
      kind = "json-array";
      path = w: "${w}/.config/opencode/opencode.json";
      key = ".skills.paths";
    };
  };

  pi = {
    package = agentPkgs: agentPkgs.pi;

    # Nothing a group grants is wanted here either, for D15's reason.
    groups = [ ];

    # The same one service as the other two, but reached differently. D14
    # expected this agent to need a provider base URL written into a
    # configuration file; it does not, and this environment writes none. M8d
    # then read the bundled Anthropic SDK's constructor defaults and concluded
    # the agent picks ANTHROPIC_BASE_URL up from the environment as the other
    # two do. M8e measured the running agent and found otherwise: pi passes an
    # explicit baseUrl from its own provider registry, which overrides that
    # default, so only ANTHROPIC_API_KEY crosses and the mediation is nono's
    # intercepting proxy in front of the real host. Nothing here changes as a
    # result; the reason it works does.
    credentialServices = [ "anthropic" ];

    stateVars = w: {
      # One variable carries the whole relocation. M1d measured it and M8d
      # confirmed it occurs exactly once in the binary, as the sole override of
      # a `$HOME/.pi/agent` default, so everything the agent persists — its
      # credential store, its model store, its session transcripts — follows it.
      #
      # PI_CODING_AGENT_SESSION_DIR is documented and absent from the binary, so
      # it is not set: a variable nothing reads is a claim nothing keeps true.
      #
      # PI_PACKAGE_DIR is documented as "useful for Nix/Guix store paths", which
      # reads like the mechanism FR-22 wants. M8d found it names the agent's own
      # installation — themes and assets, derived from `dirname(execPath)` — and
      # not its extensions, so setting it would point the agent away from the
      # files nix already gave it.
      PI_CODING_AGENT_DIR = "${w}/.agents/pi";

      # FR-22. This is the variable that stops the agent extending itself: a
      # package declared in the settings it reads is installed on startup, and
      # M8d measured the difference directly — set, the agent lists the
      # declaration and fetches nothing; unset, startup runs
      # `npm install <pkg> --prefix <root>/npm --legacy-peer-deps` and the tree
      # appears. M1d's "startup operations only" is why it does not constrain
      # `pi install` typed by hand, which reaches the registry either way.
      #
      # It is not the only guard, and the other one is the boundary rather than
      # a setting: with this unset, a confined session's attempt dies on
      # `EACCES: permission denied, posix_spawn 'npm'`, because the enumerated
      # execution substrate carries no npm to run. Two guards, because a
      # settings file is a request and the substrate is an answer.
      PI_OFFLINE = "1";
    };

    # The `skills` array in the settings file, which M8e found is the mechanism
    # this agent's own documentation points at another harness's skill root
    # with. The file is the one PI_CODING_AGENT_DIR moved, and it is the same
    # file the FR-22 `packages` key lives in, so the roots are merged in rather
    # than written over.
    skillSurface = {
      kind = "json-array";
      path = w: "${w}/.agents/pi/settings.json";
      key = ".skills";
    };
  };

}
