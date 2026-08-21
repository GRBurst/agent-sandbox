# The agent table. One entry per agent this environment knows how to confine.
#
# FR-1 names three agents, so the set is closed: a name that is not here is an
# error rather than a default, and callers look an agent up as
# `agents.${name} or (throw …)`. P9 forbids a lookup miss producing something
# that merely looks like a confined session.
#
# Only `claude-code` is here today. `opencode` and `pi` arrive with M8, which is
# where the checks that observe them live; adding them now would be asserting
# nothing about two agents while appearing to support them.
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
          placeholder. Every value must lie under it, which is FR-4 and what
          `check_state_vars` asserts.
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
    # not behaviour. The other candidate variables belong to M8b, which is where
    # the subagent and lock fallbacks are observed.
    stateVars = w: {
      CLAUDE_CONFIG_DIR = "${w}/.agents/claude";
      CLAUDE_CODE_TMPDIR = "${w}/.agents/claude/tmp";
      CLAUDE_CODE_REMOTE_MEMORY_DIR = "${w}/.agents/claude/memory";

      # P8: the developing host had this set already, so without it the
      # environment would be idempotent only there. An agent that updates itself
      # is not the agent this description was written against.
      DISABLE_AUTOUPDATER = "1";
    };
  };

}
