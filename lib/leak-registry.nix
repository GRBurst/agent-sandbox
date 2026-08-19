# FR-3. The single file. Every path outside the project directory that a session
# may still reach is named here, or it is not reachable at all.
#
# An entry is admissible only where the tool structurally cannot be directed
# elsewhere. That is why each one justifies itself twice: `why` says what breaks
# without the path, and `whyNotNarrower` says why no tighter grant does the job.
# A path that could have been redirected is a configuration bug, not an entry.
#
# The list holds one entry: the store, which is the substrate a session executes
# from. It holds nothing else, and in particular nothing of the agent's own. D1
# resolved credential delivery to injection by the supervisor, so no agent needs
# a credential file granted, and D14 closed the one route that would have added
# one. M1g then observed that claude-code's whole configuration root relocates
# into the project, leaving nothing behind under $HOME.
#
# The mechanism's own state root, $XDG_STATE_HOME/nono, is deliberately NOT an
# entry. M1c observed that nono refuses to start when any grant overlaps it, so
# it cannot be granted even in principle; an entry claiming to grant it would be
# false. It is an accepted leak, recorded in the handbook instead (D2).
{ lib }:
let
  inherit (lib) mkOption types;

  # P7: a submodule with named options, never `attrsOf str`. The type settles
  # shape — that `mode` is one of two words, that no fifth key sneaks in. It
  # deliberately does not settle content: `why = ""` type-checks, and
  # check_registry is what rejects it, because an empty justification is a
  # judgement about the text rather than about its type.
  entryType = types.submodule {
    options = {
      path = mkOption {
        type = types.str;
        description = "Absolute path outside the project directory.";
      };
      mode = mkOption {
        type = types.enum [
          "read"
          "readwrite"
        ];
        description = "How much of the path the session gets. Read unless writing is unavoidable.";
      };
      agents = mkOption {
        type = types.listOf types.str;
        description = "The agents this exception applies to, by name. Never all of them by default.";
      };
      why = mkOption {
        type = types.str;
        description = "What fails without this path.";
      };
      whyNotNarrower = mkOption {
        type = types.str;
        description = "Why no narrower grant, and no redirection, achieves the same thing.";
      };
    };
  };

  # The gate. Applying it to a candidate either returns the entry or fails
  # evaluation, so the type is what admits an entry rather than convention.
  # `entries` is defined through it, which is why an unchecked entry cannot be
  # added to the list without editing this line.
  checkEntry =
    entry:
    (lib.evalModules {
      modules = [
        { options.entry = mkOption { type = entryType; }; }
        { inherit entry; }
      ];
    }).config.entry;
in
{
  inherit entryType checkEntry;

  entries = map checkEntry [
    {
      # `builtins.storeDir` rather than the literal, because the value is Nix's
      # to state and a store at another prefix would otherwise be granted the
      # wrong path silently.
      path = builtins.storeDir;
      mode = "read";
      agents = [ "claude-code" ];

      why = ''
        Every executable, library and interpreter a session runs is a store
        path: the agent, the shell it spawns, and each tool it shells out to.
        Without the store the session does not start — M1g observed the child
        exit 127 with the binary readable but unexecutable.
      '';

      whyNotNarrower = ''
        A narrower grant is the closure of what the session executes, and that
        closure cannot be computed before the agent is packaged, which is M4b.
        M4c derives it from closureInfo and replaces this entry; the measurement
        that makes it worth doing is that a session opens 55 store paths where
        the closure of the same tool set grants 62.

        No subtractive option exists in the meantime. Landlock rules are
        allow-only, so a deny cannot carve a hole in a granted parent: nono
        refuses to start rather than pretend, reporting that a deny-overlap is
        not enforceable on Linux (D15).

        Read, never readwrite. A store path is immutable and the daemon owns
        writes to it, so a session that could write here would be corrupting
        every other consumer of the same path.
      '';
    }
  ];
}
