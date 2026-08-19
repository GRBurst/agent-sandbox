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
# Each entry carries only what some check already exercises. `package` and
# `binary` arrive with M4, which builds the entry point that runs them, and
# `credential` with M7, which asserts the credential's shape. The alternative is
# a table whose fields nothing reads, which is how a table starts lying.
{ lib }:
let
  inherit (lib) types mkOption;

  entryType = types.submodule {
    options = {
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
