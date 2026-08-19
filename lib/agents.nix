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
          Confinement groups to include by name. A group is included rather
          than its paths granted individually, because a group grants exactly
          the access it was written for where a path grant gives read and
          write.
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
    # /nix/store is absent from the confinement floor, so a session without
    # this group cannot execute the agent at all: M1g observed the child exit
    # 127 with nono reporting the binary readable but unexecutable.
    #
    # git_config is deliberately not here. It grants read on the host's git
    # configuration, and read-only is no protection when the danger is that a
    # directive in that file runs a program inside the boundary — M1c observed a
    # session pick up the host's `credential.helper = cache` and try to start a
    # daemon. FR-23 wants the toolchain pointed at configuration this
    # environment wrote, which the confinement does with GIT_CONFIG_GLOBAL.
    groups = [ "nix_runtime" ];

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
