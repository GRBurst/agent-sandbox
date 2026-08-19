# FR-3. The single file. Every path outside the project directory that a session
# may still reach is named here, or it is not reachable at all.
#
# An entry is admissible only where the tool structurally cannot be directed
# elsewhere. That is why each one justifies itself twice: `why` says what breaks
# without the path, and `whyNotNarrower` says why no tighter grant does the job.
# A path that could have been redirected is a configuration bug, not an entry.
#
# The list is expected to be empty, and is. D1 resolved credential delivery to
# injection by the supervisor, so no agent needs a credential file granted, and
# D14 closed the one route that would have added one. M1g then observed that
# claude-code's whole configuration root relocates into the project, leaving
# nothing behind under $HOME.
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
  ];
}
