# The confinement description, generated per agent and built into the store.
#
# Nothing here is generated per project. `$WORKDIR` is a placeholder the
# confinement mechanism expands at run time, so one description in the store
# serves every project that uses this environment — which is what makes the
# description reviewable and FR-19's single canonical artefact possible.
#
# The description names no parent (D10). M1e observed that a description naming
# `default` and one naming nothing resolve byte-identically, so naming it would
# document an inheritance that does not happen.
{
  lib,
  pkgs,
  agents,
  registry,
  substrate,
  substrateVars,
}:
name:
let
  a =
    agents.${name}
      or (throw "agent-sandbox: unknown agent '${name}'. Known: ${lib.concatStringsSep ", " (lib.attrNames agents)}");

  # The literal string, never expanded by Nix or by a shell.
  w = "$WORKDIR";

  # FR-3: reach beyond the project comes from the registry and from nowhere
  # else. The registry is empty today, so both lists are empty — but the path
  # from registry to description exists, because an entry added to the registry
  # has to take effect without anyone remembering to edit this file.
  mine = builtins.filter (e: builtins.elem name e.agents) registry.entries;
  pathsWith = mode: map (e: e.path) (builtins.filter (e: e.mode == mode) mine);

  closure = substrate name;

  # Everything the description says that can be decided by evaluating this file.
  # The substrate cannot: it is the content of a derivation's output, and reading
  # that during evaluation would mean building the closure before the flake can
  # be evaluated at all. So the substrate is merged in by the build below, and
  # this is the part a reader can reason about without one.
  declared = {
    "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";

    # M1e: omitting meta.name is a parse error rather than a default.
    meta = {
      inherit name;
      version = "1";
      description = "agent-sandbox confinement for ${name}";
    };

    # M1g: the working directory is granted read-only unless the description
    # says otherwise, and a read-only project makes every agent useless.
    workdir.access = "readwrite";

    groups.include = a.groups;

    # What is granted is the project, and whatever the registry justifies.
    #
    # What is NOT granted, and why (P5):
    #
    #   the mechanism's own state root — it refuses to start when any grant
    #   overlaps it, so an entry claiming to grant it would be false. M1c
    #   observed the refusal. It is an accepted leak, recorded in the handbook.
    #
    #   $XDG_RUNTIME_DIR — the keyring's secrets, the ssh agent's socket and the
    #   session bus all live there. Granting it would hand over every credential
    #   this feature exists to keep out, through a path that looks like a
    #   temporary directory.
    #
    #   any host git configuration — see the group comment in lib/agents.nix.
    #   The danger is the directive rather than the bytes, so read-only access
    #   is not a weaker grant but an equally dangerous one.
    #
    #   the home directory — FR-2. It is not denied either: D13 leaves HOME
    #   pointing at the host precisely so a tool that ignores its relocation
    #   variable fails outright at a path the pre-flight already proves is
    #   refused, rather than quietly writing somewhere this environment chose.
    filesystem = {
      allow = pathsWith "readwrite";
      read = pathsWith "read";
    };

    environment = {
      # Default-deny (D6). An unfiltered session inherits 233 variables, and a
      # list of the dangerous ones would be a list someone has to maintain
      # against every tool that ever invents a new way to carry a secret.
      #
      # No XDG_* variable is allowed through. Leaving them pointing at host
      # paths would make a tool fail at a path this environment never chose;
      # dropping them makes it fall back under HOME and fail there instead,
      # which is the one refusal the pre-flight already demonstrates.
      allow_vars = [
        "HOME"
        "USER"
        "LOGNAME"
        "TERM"
        "LANG"
        "LC_*"
        "PWD"
        "SHELL"
        "TZ"
        "COLORTERM"
      ];

      set_vars =
        (a.stateVars w)
        // substrateVars
        // {
          # FR-23. The toolchain is pointed at configuration this environment
          # wrote rather than merely denied the host's, so its effective
          # configuration is the same on every machine instead of depending on
          # what the developer happens to have in their home directory.
          GIT_CONFIG_GLOBAL = "${w}/.agents/git/config";
          GIT_CONFIG_SYSTEM = "/dev/null";
        };
    };
  };
in
# M4c. The substrate is the closure of what the session executes, so it is read
# out of a built derivation and merged here rather than named in this file.
#
# A `runCommand` rather than `builtins.readFile (closure + "/store-paths")`: the
# latter is import-from-derivation, which would build the whole closure during
# evaluation of `nix flake show` and of every check that only wants to read the
# agent table. This way the closure is built when the description is built, which
# is when it is needed.
pkgs.runCommand "nono-profile-${name}.json"
  {
    nativeBuildInputs = [ pkgs.jq ];
    passAsFile = [ "declared" ];
    declared = builtins.toJSON declared;
    inherit closure;
  }
  ''
    # One path per line, and the file ends with a newline, so the empty trailing
    # element is dropped rather than granted as "".
    jq --rawfile substrate "$closure/store-paths" \
      '.filesystem.read += ($substrate | split("\n") | map(select(length > 0)))' \
      "$declaredPath" > "$out"
  ''
