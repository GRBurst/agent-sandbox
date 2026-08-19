# Handbook

This is how to use the repository **today**.
If this file and the code disagree, the code wins, so fix the handbook.

For the source-of-truth order, the workflow and the conventions, see [AGENTS.md](../AGENTS.md).
For the principles every change is measured against, see [CONSTITUTION.md](CONSTITUTION.md).

## What this repository is

A **consumable development environment**.
A project points at it from a flake, a devenv configuration or a devcontainer — from GitHub or from a local checkout — and gets a shell with agents already configured and confined to that project.

**Project isolation is the product.**
Credentials, caches, history and agent state belong to one project and are not visible from another.
Every guarantee below exists to serve that, and every one of them is meant to be checkable rather than asserted.

The repository is early.
The consumable surface — what a downstream flake actually imports, and what it gets — is not specified yet; that is the job of the first spec.
What exists today is the isolation mechanism and the process around it, and [Known drift](#known-drift) is the honest list of what does not yet hold.

## Entering the environment

```sh
direnv allow                 # once per checkout; every later cd loads the environment
nix develop                  # the same environment, without direnv
nix develop -c <cmd>         # run one command in it, the reliable escape hatch
direnv reload                # after editing flake.nix or .envrc
```

From a ref rather than a checkout, which is how a consumer will use it:

```sh
nix develop github:HivemindTechnologies/sandbox-examples
```

That path is **untested and currently limited to `x86_64-linux`**, because the flake hardcodes a single system.
See [Known drift](#known-drift).

There is no devenv path.
`devenv.nix` and `devenv.yaml` generated a devcontainer whose bind mounts were the leak the first spec exists to remove, and both are deleted.
Confinement now happens on the host, so the flake is the only way in.

## What the environment guarantees

Every tool that would otherwise write into `$HOME` is pointed inside the checkout.
`flake.nix`'s `shellHook` is the single source of these, and the values below are what it exports.

| Variable | Resolves to | Would otherwise write to |
| --- | --- | --- |
| `TMPDIR` | `$PWD/.tmp` | `/tmp` |
| `TMPPREFIX` | `$PWD/.tmp/zsh` | `/tmp/zsh*`, where zsh puts heredoc bodies |
| `XDG_CACHE_HOME` | `$PWD/.cache` | `~/.cache` |
| `npm_config_cache` | `$PWD/.cache/npm` | `~/.npm` |
| `NPM_CONFIG_USERCONFIG` | `$PWD/.npmrc` | `~/.npmrc` |
| `DOCKER_CONFIG` | `$PWD/.docker` | `~/.docker` |
| `CURL_HOME` | `$PWD/.config` | `~/.curlrc` |

`TMPPREFIX` is not redundant.
zsh writes heredoc bodies to `$TMPPREFIX*` rather than to `$TMPDIR`, so a stale value fails every heredoc with `can't create temp file for here document` while `$TMPDIR` still looks correct.

**The bootstrap is the one exception.**
`.envrc` exports `TMPDIR` and `XDG_CACHE_HOME` *before* `use flake`, because nix needs them to read the flake at all.
Those two values are duplicated on purpose, and the two files have to resolve them to the same paths.
Byte-identical source text is the wrong criterion, because nix's indented strings escape where a shell does not; `check_bootstrap_mirror` evaluates both and compares the resolved values.

**There is one accepted leak.**
`.envrc` calls `source_up_if_exists`, which reads a parent `.envrc` above the checkout.
It is kept because that is a personal, machine-level concern, and direnv carries on when the read is denied.

### Checking it by hand

The bootstrap mirror is now automated as `check_bootstrap_mirror` in the unit layer, so it needs no hand-run.
What is still unautomated is the property below.
It derives the variable list from `flake.nix` rather than repeating it, so a newly added variable is covered without editing it.

```sh
# Every filesystem path any project-scoped variable names lies under the checkout.
# Silence is a pass.
sed -n 's/^ *export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' flake.nix | sort -u | while read -r v; do
  for path in $(printf '%s\n' "${!v}" | grep -oE '/[^ ]+'); do
    case "$path" in "$PWD"/*) ;; *) echo "LEAK  $v -> $path" ;; esac
  done
done
```

Run it with `bash`, not `zsh` — `${!v}` is bash's indirect expansion.

## Verifying the repository

```sh
bash scripts/validate.sh             # the single entry point; every check, every layer
bash scripts/validate.sh --list      # name the checks without running them
bash scripts/validate.sh --layer unit  # one layer only
nix flake check                      # evaluates the devShell
nixfmt flake.nix lib/*.nix           # format the nix
mdformat AGENTS.md docs specs        # format the markdown
shellcheck scripts/validate.sh scripts/checks/*.sh   # lint the shell
```

`scripts/validate.sh` is what [AGENTS.md](../AGENTS.md#4-verify-every-change) names as the single entry point.
It **exits non-zero today, by design**: `check_sc3` asserts a scenario-to-check bijection and is the feature's progress bar, so it fails until the last scenario in the spec has a check.
A task is judged by whether its own check passes and whether the set `check_sc3` names shrinks by exactly the scenarios that task covers.

## Known drift

This is the honest list of places where the repository does not yet do what it says, kept here rather than in a spec so it cannot be mistaken for backlog that someone else owns.
It is the natural input to the first spec.

**Portability.**

- `flake.nix` hardcodes `system = "x86_64-linux"`, so consuming it from a ref fails on anything else.

**Isolation.**

- No check enforces any isolation claim, so under Constitution **P2** none of them is yet believable.
  `check_r7`, `check_bootstrap_mirror` and `check_registry` assert the environment's shape, not its boundary; the first check that observes confinement arrives with the integration layer.

**Orphans and small things.**

- There is no `README.md` at the repository root, which [AGENTS.md](../AGENTS.md#6-docs-and-diagrams) requires of any directory a user can consume on its own.
- There is no `justfile`, so the commands above are typed rather than named.
- `statix` and `deadnix` are absent entirely.
