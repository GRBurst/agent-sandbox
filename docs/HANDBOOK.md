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

**A 77 does not always mean your kernel.**
The mechanism reads `$XDG_CONFIG_HOME/nono/config.toml`, which the blanket puts *inside* the checkout, and it refuses to start when that file will not parse.
So a checkout carrying a broken one produces the same exit status and the same "cannot confine" reading as a host that genuinely cannot.
Look at `.config/nono/` before doubting the machine.
The file cannot widen a session — `[extensions]` and `[overrides]` are parsed and ignored, measured — but it can stop one.

**The first run writes the identity your commits carry.**
The wrapper creates `.agents/git/config` if it is absent, copying `user.name` and `user.email` out of your host's global git configuration and nothing else from it.

```sh
cat .agents/git/config      # what this session commits as
```

Edit it and it is never rewritten, which is how a project gets an identity of its own.
If your host has neither value the file is not written at all, and a commit fails with git's own `Please tell me who you are` rather than being made under a placeholder.
Nothing else from your host git configuration is read: `GIT_CONFIG_GLOBAL` points at that file and `GIT_CONFIG_SYSTEM` at `/dev/null`, so a `core.hooksPath` or `credential.helper` in `~/.gitconfig` cannot direct a session.

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

**`XDG_CONFIG_HOME` is a blanket, and that has a cost worth knowing before you enter the shell.**
It is set for the whole devShell, not only for a confined session, so *every* program you run in the checkout looks for its configuration under `$PWD/.config` — including an agent you installed on the host yourself.
Inside the project, that agent finds none of your `~/.config` settings, subagents or skills.
This is a tracked violation of the constitution's "prefer the tool's own variable" rule, recorded as `C1` in the feature's plan, and it is kept only because `nono` has no variable of its own: pointed at a directory that does not exist it falls back to the host's `~/.config` silently, which would let host confinement descriptions decide what a confined session may reach.
Extensions you authored yourself are meant to come with you, by declaring them once for the machine rather than by widening this; that is not built yet.

**There are two accepted leaks.**

- `.envrc` calls `source_up_if_exists`, which reads a parent `.envrc` above the checkout.
  It is kept because that is a personal, machine-level concern, and direnv carries on when the read is denied.
- `$XDG_STATE_HOME/nono` stays on the host, because the mechanism anchors its own supervisory state there and refuses to start when any granted path overlaps it.
  It is not a leak-registry entry for that reason: an entry claiming to grant it would be false.
  A confined session's audit record — what it was actually granted — is written under it, which is how `check_j1_1` observes a real session rather than trusting a resolved policy.

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
nix develop -c bash scripts/validate.sh   # the single entry point; every check, every layer
bash scripts/validate.sh --list           # name the checks without running them
bash scripts/validate.sh --layer unit     # one layer only; unit and component need no devShell
nix flake check                           # evaluates the devShell for this system
nix flake check --all-systems             # and for the other one, which needs a remote builder to go further
nixfmt flake.nix lib/*.nix                # format the nix
mdformat AGENTS.md docs specs             # format the markdown
shellcheck scripts/validate.sh scripts/checks/*.sh   # lint the shell
```

`scripts/validate.sh` is what [AGENTS.md](../AGENTS.md#4-verify-every-change) names as the single entry point.

**The integration layer has to run inside the devShell**, which is why the first line says `nix develop -c`.
`lib/preflight.sh` execs its probe by bare name, so on a host that carries its own `true` outside the granted substrate the probe is denied and `check_r6` fails for a reason that has nothing to do with the check.
The unit and component layers have no such dependency.

It **exits non-zero today, by design**: `check_sc3` asserts a scenario-to-check bijection and is the feature's progress bar, so it fails until the last scenario in the spec has a check.
A task is judged by whether its own check passes and whether the set `check_sc3` names shrinks by exactly the scenarios that task covers.
Today's baseline is `1 of 18 checks failed`, that one being `check_sc3`, and the set it names is 14 scenarios long.

## Known drift

This is the honest list of places where the repository does not yet do what it says, kept here rather than in a spec so it cannot be mistaken for backlog that someone else owns.
It is the natural input to the first spec.

**Portability.**

- `aarch64-darwin` is declared and evaluates, but has never been entered, and macOS confinement is enforced by a different mechanism from Landlock. Nothing here has measured how strong it is.
- Consuming from a ref is not exercised by any check yet, so the environment is only known to work from a checkout. The e2e layer is empty.

**Isolation.**

- Confinement is now observed rather than asserted, on both sides. `check_r6` proves the pre-flight refuses a host that cannot enforce it and `check_j1_1` compares a real session's granted reach against the project, the execution substrate and the leak registry; the refusal side is now checked too — `check_r1` reads a planted SSH key from inside a session and watches it fail, `check_r2` writes outside the project and watches the file not appear, `check_r3` puts an API-key canary in the host environment and proves it does not cross, `check_r4` has a session rewrite the source of its own confinement and proves nothing widens until a human re-enters, `check_r5` commits a confinement description to the checkout and proves the entry point does not read it, `check_r10` plants a host git configuration that runs a program and proves it neither crosses nor runs, and `check_j8_2` plants a whole host-global agent installation and compares the session's granted reach to the project, the substrate and the registry as a set. Each of them reads, writes or runs something it *is* allowed in the same session, so a session that failed to start cannot pass — and `check_controls` reads the suite's own text to keep it that way, because a refusal check whose control has been deleted goes on passing while proving nothing.
- A session is granted the closure of what it runs, 128 store paths rather than the 67,000 the store holds, and the leak registry is now **empty**. What still has no check: history, cross-project state, and credentials beyond the environment channel `check_r3` covers.
- **A grant on an exact path beats a `deny` the mechanism carries for it.** The five `required` deny groups, `deny_credentials` among them, are not a backstop behind the leak registry — a registry entry naming `$HOME/.ssh` would read the key, with the deny sitting beside the grant in the resolved manifest. A grant on an *ancestor* of denied paths is refused and the session does not start, but do not expect the message to say so: granting `$HOME` is refused first for overlapping nono's own protected state root, at a path that need not even exist, and the deny rules are never mentioned. So the registry's strictness is the whole of the guarantee.
- **A confinement description written inside the project is one the mechanism will find, and what refuses it is a single command-line argument.** The blanket `XDG_CONFIG_HOME` puts nono's user profile directory inside the checkout, so a profile committed to a repository is listed by `nono profile list` and grants what it asks for the moment anything resolves it by name. The entry point passes `--profile <store path>` as an argument, and an argument beats `NONO_PROFILE`, which is why an untrusted checkout cannot grant itself paths. Nothing refuses the file itself.
- **The calling environment can widen a session, and that is deliberate.** `NONO_ALLOW` adds to a description the entry point pinned, and `--extends` adds a whole profile. That is the intended route for a consumer to lend a session something of their own. It is worth knowing that the mechanism cannot tell a variable exported above your checkouts from one exported by a checkout's own `.envrc`, so the trust boundary there is your `direnv allow`, not an enforcement.
- The denial-set comparison behind the narrowing uses `strace`, which is Linux-only, so on macOS `check_substrate_denials` reports `SKIP` rather than passing. What macOS keeps is the component-layer equality, which reads the description rather than the kernel.
- A confined session inherits `PATH` **whole**, host user profile included, and nono offers no way to narrow it: `set_vars.PATH` is rejected as reserved and `deny_vars` has no effect on it. Now that the store is no longer granted wholesale, this is literal: a tool the session can still *name* from the host profile is a tool it can no longer *run*.

**State that still resolves into `$HOME`.**

- `XDG_STATE_HOME` is not redirected, so a tool that honours it writes outside the checkout. `opencode` does: `opencode debug paths` reports its `state` root under `~/.local/state`. Inside a confined session the variable is not host-valued but **unset** — nothing in the description passes any `XDG_*` variable through — so such a tool falls back to the specification's own `$HOME/.local/state`, which the session denies, and it fails rather than relocating. The variable cannot simply join the table above, because the mechanism resolves its own protected state root from the ambient value; it has to be redirected for the session rather than for the shell. That the two resolutions are independent is now measured rather than assumed: a session whose description sets `XDG_STATE_HOME` under the project starts, writes there, and leaves the supervisor's audit record where it was.

**Tools the environment does not provide.**

- `git` is now in the devShell, and so is `strace` on Linux. `node` is not: it resolves from the host user profile, which by [AGENTS.md](../AGENTS.md#3-environment-and-tooling) §3 means it is *not available*, and a confined session cannot run it because it is outside the substrate.

**Orphans and small things.**

- There is no `README.md` at the repository root, which [AGENTS.md](../AGENTS.md#6-docs-and-diagrams) requires of any directory a user can consume on its own.
- There is no `justfile`, so the commands above are typed rather than named.
- `statix` and `deadnix` are absent entirely.
