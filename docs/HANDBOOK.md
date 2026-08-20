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

That path is **untested**.
The flake declares `x86_64-linux` and `aarch64-darwin`, which are the two systems for which the agents exist upstream, but only the first has been entered.
See [Known drift](#known-drift).

There is no devenv path.
`devenv.nix` and `devenv.yaml` generated a devcontainer whose bind mounts were the leak the first spec exists to remove, and both are deleted.
Confinement now happens on the host, so the flake is the only way in.

### Where the agents come from

`nono`, `claude-code`, `opencode` and `pi` all come from [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix), pinned to a revision.
Nothing about them is packaged here, and nothing about them is taken from `nixpkgs`.

Those binaries are published to `https://cache.numtide.com`, which `flake.nix` names in a `nixConfig` block.
**Nix ignores that block unless you are a trusted user**, and prints this on every command instead:

```text
warning: ignoring untrusted flake configuration setting 'extra-substituters'.
Pass '--accept-flake-config' to trust it
```

The warning is not fatal, and it is not cosmetic either.
Ignored, the substituter is unreachable, so `nono` and the agents are **built from source** rather than copied — minutes of compilation instead of the seven seconds the copy takes.
The `nixConfig` block is therefore a *record* of where the binaries come from, which travels with the flake and is readable by whoever has to decide whether to trust it.
Three ways to actually reach the cache, strongest first:

```sh
# 1. Once per machine, in /etc/nix/nix.conf — then every flake you consume is trusted by you.
#    trusted-users = root <your-user>
# 2. Per command, having read the block and decided it is fine.
nix develop --accept-flake-config
# 3. Per machine, naming this one substituter rather than trusting the flake wholesale, in /etc/nix/nix.conf.
#    extra-substituters = https://cache.numtide.com
#    extra-trusted-public-keys = niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=
```

A flake that declares `nixConfig` also makes `XDG_DATA_HOME` load-bearing: before evaluating one, nix reads `$XDG_DATA_HOME/nix/trusted-settings.json` to recall what you last answered.
Where `$HOME` is denied — which is the whole point of the sandbox this repository is developed in — that read fails and **every** `nix` command dies with `Permission denied`.
That is why `XDG_DATA_HOME` is in the bootstrap and not only in the `shellHook`.

### Starting an agent

Inside the environment, the agent is on `PATH` under its own name and is already confined:

```sh
claude --version             # runs under nono, confined to this project
type claude                 # a wrapper in the store, not the upstream binary
```

The wrapper is the only entry point; the unconfined binary is reachable only by store path.
If the host cannot enforce confinement the wrapper refuses to start the agent and exits 77, rather than running it unconfined.

## What the environment guarantees

Every tool that would otherwise write into `$HOME` is pointed inside the checkout.
`flake.nix`'s `shellHook` is the single source of these, and the values below are what it exports.

| Variable | Resolves to | Would otherwise write to |
| --- | --- | --- |
| `TMPDIR` | `$PWD/.tmp` | `/tmp` |
| `TMPPREFIX` | `$PWD/.tmp/zsh` | `/tmp/zsh*`, where zsh puts heredoc bodies |
| `XDG_CACHE_HOME` | `$PWD/.cache` | `~/.cache` |
| `XDG_DATA_HOME` | `$PWD/.local/share` | `~/.local/share` |
| `XDG_CONFIG_HOME` | `$PWD/.config` | `~/.config` |
| `npm_config_cache` | `$PWD/.cache/npm` | `~/.npm` |
| `NPM_CONFIG_USERCONFIG` | `$PWD/.npmrc` | `~/.npmrc` |
| `DOCKER_CONFIG` | `$PWD/.docker` | `~/.docker` |
| `CURL_HOME` | `$PWD/.config` | `~/.curlrc` |

`TMPPREFIX` is not redundant.
zsh writes heredoc bodies to `$TMPPREFIX*` rather than to `$TMPDIR`, so a stale value fails every heredoc with `can't create temp file for here document` while `$TMPDIR` still looks correct.

`XDG_CONFIG_HOME` has to **exist**, not merely be set.
`nono` falls back to the host's `~/.config` when the directory it names is absent, silently, so the `shellHook` and the agent wrapper both create it before anything reads it.

**The bootstrap is the one exception.**
`.envrc` exports `TMPDIR`, `XDG_CACHE_HOME` and `XDG_DATA_HOME` *before* `use flake`, because nix needs all three to read the flake at all.
Those three values are duplicated on purpose, and the two files have to resolve them to the same paths.
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
nix flake check                      # evaluates the devShell for this system
nix flake check --all-systems        # and for the other one, which needs a remote builder to go further
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

- `aarch64-darwin` is declared and evaluates, but has never been entered, and macOS confinement is enforced by a different mechanism from Landlock. Nothing here has measured how strong it is.
- Consuming from a ref is not exercised by any check yet, so the environment is only known to work from a checkout. The e2e layer is empty.

**Isolation.**

- Confinement is now observed rather than asserted: `check_r6` proves the pre-flight refuses a host that cannot enforce it, and `check_j1_1` compares a real session's granted reach against the leak registry. The remaining claims — credentials, history, cross-project state — have no check yet.
- The leak registry still grants all of `/nix/store`. Narrowing it to the closure the agent actually needs is its own task.

**Orphans and small things.**

- There is no `README.md` at the repository root, which [AGENTS.md](../AGENTS.md#6-docs-and-diagrams) requires of any directory a user can consume on its own.
- There is no `justfile`, so the commands above are typed rather than named.
- `statix` and `deadnix` are absent entirely.
