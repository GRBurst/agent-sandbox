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

devenv is configured but has never been evaluated in this checkout, and it generates a devcontainer rather than being entered directly:

```sh
devenv shell                 # unverified
devenv container build       # unverified; emits the devcontainer devenv.nix declares
```

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

A further six variables — `KCAT_CONFIG`, `KAFKA_CTL_CONFIG`, `PSQLRC`, `PSQL_HISTORY`, `MAVEN_ARGS`, `MAVEN_OPTS` — are exported for tools the previous project needed and this one does not.
They are listed under [Known drift](#known-drift).

**The bootstrap is the one exception.**
`.envrc` exports `TMPDIR` and `XDG_CACHE_HOME` *before* `use flake`, because nix needs them to read the flake at all.
Those two values are duplicated on purpose, and the duplication has to be kept byte-identical.

**There is one accepted leak.**
`.envrc` calls `source_up_if_exists`, which reads a parent `.envrc` above the checkout.
It is kept because that is a personal, machine-level concern, and direnv carries on when the read is denied.

### Checking it by hand

Nothing checks this automatically yet, so these are the two properties to run when you touch the environment.
Both derive the variable list from `flake.nix` rather than repeating it, so a newly added variable is covered without editing the check.

```sh
# 1. Every filesystem path any project-scoped variable names lies under the checkout.
#    Silence is a pass.
sed -n 's/^ *export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' flake.nix | sort -u | while read -r v; do
  for path in $(printf '%s\n' "${!v}" | grep -oE '/[^ ]+'); do
    case "$path" in "$PWD"/*) ;; *) echo "LEAK  $v -> $path" ;; esac
  done
done

# 2. The two bootstrap variables are identical in .envrc and flake.nix.
#    The two lines printed must match.
for f in .envrc flake.nix; do
  grep -oE 'export (TMPDIR|XDG_CACHE_HOME)="[^"]+"' "$f" | sort | tr '\n' ' '; echo
done
```

Run them with `bash`, not `zsh` — `${!v}` is bash's indirect expansion.

## Verifying the repository

```sh
nixfmt flake.nix ai.nix devenv.nix   # format
nix flake check                      # evaluates the devShell; passes today
mdformat AGENTS.md docs specs        # format the markdown
```

`scripts/validate.sh`, which [AGENTS.md](../AGENTS.md#4-verify-every-change) names as the single entry point, **does not exist yet**.
Until it does, every check in this document is one a human runs, and the coverage gap is total.

## Known drift

This is the honest list of places where the repository does not yet do what it says, kept here rather than in a spec so it cannot be mistaken for backlog that someone else owns.
It is the natural input to the first spec.

**The environment still belongs to the previous project.**

- `flake.nix` is described as `"Hivemind Kafka Playground"` and its devShell carries `kcat`, `kafkactl`, `postgresql`, `lazysql`, `zellij`, `openjdk25`, `maven` and `nodejs`, none of which this repository uses.
- Six exported variables exist only for those tools.
  Two of them, `KCAT_CONFIG` and `PSQLRC`, point into a `.config/` directory that does not exist.
- `.gitignore` still ignores `materialize/.config/`, `current-context.yml` and `.env`, which refer to stacks that are not here.
- `flake.nix`'s comments reference `.claude/settings.json` and `scripts/validate.sh`.
  Neither exists, so the mirror that Constitution **P1** requires is currently unenforced rather than merely unwritten.

**Portability.**

- `flake.nix` hardcodes `system = "x86_64-linux"`, so consuming it from a ref fails on anything else.
  `devenv.nix` explicitly claims Apple Silicon support, so the two disagree.

**Isolation.**

- `devenv.nix` bind-mounts `~/.config/opencode`, `~/.config/claude-code`, `~/.claude` and `~/.pi/agent` from the host into the container, read-write.
  Its comment says state directories are deliberately not mounted so that project memories cannot leak, but `~/.claude` holds credentials *and* per-project session state, so as written the container shares both with every other consumer of the host home.
  Whether that is the intended trade or a leak is the first question the first spec has to answer.
- No check enforces any isolation claim, so under Constitution **P2** none of them is yet believable.

**Orphans and small things.**

- `ai.nix` is a home-manager module that nothing in this repository imports.
  It is either the substance of what the repository ships or reference material, and it is currently neither.
- `devenv.nix`'s `enterShell` ends a line with a stray `^`, which prints as part of the message.
- There is no `README.md` at the repository root, which [AGENTS.md](../AGENTS.md#6-docs-and-diagrams) requires of any directory a user can consume on its own.
- There is no `justfile`, so the commands above are typed rather than named.
- `shellcheck` and `shfmt` are named in AGENTS.md's format-and-lint table but are absent from the devShell; they resolve today only from a user profile, which under [AGENTS.md §3](../AGENTS.md#3-environment-and-tooling) means they are not available.
- `statix` and `deadnix` are absent entirely.
