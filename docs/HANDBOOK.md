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
nix develop --accept-flake-config github:GRBurst/agent-sandbox
```

`github:GRBurst/agent-sandbox` is the canonical published reference, and it is the same name everywhere — in this document, in `scripts/checks/e2e.sh` and in the remote `origin` points at.
Earlier revisions of this document named a different owner and a different repository; both were wrong.

`--accept-flake-config` is part of the command rather than an optimisation, because a stranger is not a trusted user and the declared substituter is otherwise ignored.
See [Where the agents come from](#where-the-agents-come-from) for what that costs and for the two alternatives.

That path is **checked and green**.
`check_j1_1` enters from that reference into a clean `$HOME`, and it passes now that the reference carries this environment.
The flake declares `x86_64-linux` and `aarch64-darwin`, which are the two systems for which the agents exist upstream, and both have been entered: the suite runs unattended on each, `x86_64-linux` asserting every check and `aarch64-darwin` skipping two it has no instrument for.
See [Where the two platforms differ](#where-the-two-platforms-differ).

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

Inside the environment, each agent is on `PATH` under its own name and is already confined:

```sh
claude --version            # runs under nono, confined to this project
opencode --version          # the same, in its own confinement
pi --version                # and the same again
type claude                 # a wrapper in the store, not the upstream binary
```

All three of the agents this repository names are on `PATH`.

**`type claude` is the check that matters, and a shell alias defeats all of this silently.**
An alias is resolved before `PATH` is consulted, so if your own shell configuration wraps an agent — `alias opencode='nono run --profile opencode-claude --allow-cwd -- opencode'` is a real example — then typing the name inside this environment never reaches the wrapper at all.
What you get instead is your host's arrangement pointed at a checkout it knows nothing about, and its most likely first words are `nono: Profile not found: opencode-claude`, because the blanket `XDG_CONFIG_HOME` means your own confinement descriptions are not on the search path here.
That message is your alias failing, not this repository refusing.
Run `type claude`, `type opencode` and `type pi` on entering: each must report a path under `/nix/store`, and anything else — an alias, a function, a user profile — is what will actually run.
Reach the wrapper past an alias with a leading backslash, as `\opencode --version`.

The wrapper is the only entry point; the unconfined binary is reachable only by store path.
If the host cannot enforce confinement the wrapper refuses to start the agent and exits 77, rather than running it unconfined.

**Running an agent unconfined, since concealing it would be worse.**
No flag, variable or configuration makes the wrapper proceed unconfined — that is deliberate, and it is what the `77` protects.
What remains possible is not invoking the wrapper at all, and this is how, because a route you can find in ten minutes is better described than hidden:

```sh
grep -o '/nix/store/[^ ]*/bin/claude' "$(command -v claude)"   # what the wrapper execs
"$(grep -o '/nix/store/[^ ]*/bin/claude' "$(command -v claude)")"   # run it yourself, unconfined
```

Nothing stops you, and nothing pretends to.
It is a deliberate and visible act rather than a fallback, which is the whole distinction: a session that runs unconfined because you typed a store path is a decision, while one that runs unconfined because a check quietly failed would be a defect.

Understand what you are switching off. All of it, at once:

- The project boundary. That agent reads and writes your whole home directory, every other checkout included.
- The credential substitution. It receives your **real** `ANTHROPIC_API_KEY`, not a per-session substitute, so a value it leaks is a value that matters.
- Every relocation. Its state, cache, history and configuration resolve under `$HOME` again, and this project's `.agents/` is not involved.
- The git identity. `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` are the wrapper's doing, so your host git configuration — `core.hooksPath` and `credential.helper` with it — is back in force.

There is no partial version of this. The confinement is one boundary, established once before the agent starts, so stepping outside the wrapper steps outside all of it.

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

### Extending an agent

An agent that extends itself by fetching code at run time does not do it here.
`pi` is the one that would: a package named in its settings is installed on startup, with a real `npm install`.
Inside a session that startup does nothing, and two separate things stop it.
`PI_OFFLINE=1` is set, so the agent lists what is declared and installs none of it; and if that were removed, the attempt would still die on `EACCES: permission denied, posix_spawn 'npm'`, because the enumerated execution substrate carries no `npm` to run.

So an extension is **vendored into the project and declared as a local path**, which needs no network and works from inside a session:

```sh
mkdir -p vendor/my-ext/skills/demo                  # or let nix put it there
pi install ./vendor/my-ext                          # records the path, fetches nothing
pi list                                             # ../../vendor/my-ext -> <checkout>/vendor/my-ext
cat .agents/pi/settings.json                        # the declaration, relative to itself
```

The recorded path is relative to the settings file, so a checkout moved or cloned elsewhere still resolves it.
`pi install npm:<pkg>` and `pi install git:<repo>` are the other two sources, and both need the registry.
Typed by hand they reach it — `PI_OFFLINE` governs the startup install, not the command — but what arrives is then unpinned and outside nix, which is what FR-22 exists to prevent.
Vendor it and declare the path instead.

`claude` and `opencode` have no equivalent startup install, so nothing here applies to them.

**Why vendoring is the route, and not a variable like the one skills get.**
An executable extension is code the session runs, so it inherits everything the session can reach — the project readwrite, the network through the mediated proxy, and the credential substitute the session was minted.
A skill is bytes the agent reads. It can *tell* the agent to run something, which is why even that is declared once for the machine and granted read-only, but it cannot act on its own.
So the two are not the same size of grant, and giving executables the same one-variable convenience would quietly hand every project you own a code-execution channel you configured months ago.
That is the reason the declaration covers skills and stops there, and the reason this environment provisions its own extensions into the project instead of granting the host location an agent would otherwise load them from.

**If you want your own host extension anyway, the route exists and it is louder on purpose.**
Widen the session at the invocation, from your shell or your home-manager configuration — never from a project:

```sh
export NONO_ALLOW="$HOME/my-extension"   # additive to the description the entry point pinned
claude                                   # the session now reaches that directory too
```

Two things to know before you do.
The grant is **read-write**, measured — the session's capability set differs from an ordinary one by exactly `r+w <dir> (dir)` — where a declared skill directory is read-only and individually granted.
So a session can rewrite the extension that every later session will run, which is the property the skills route is deliberately built to deny.
And the mechanism cannot tell a variable exported above your checkouts from one exported by a checkout's own `.envrc`, so what keeps a cloned project from asking for this is your `direnv allow` and not an enforcement.

### Bringing your own skills in

A session reads nothing from your home directory by default, which includes the skills you wrote for yourself.
`AGENT_SANDBOX_SKILLS` is the one exception, and it is the only widening this repository ships.

Set it in the environment you start the agent from — your shell profile, your home-manager configuration, a parent `.envrc` — as a colon-separated list of absolute directories, each holding skill directories:

```sh
export AGENT_SANDBOX_SKILLS="$HOME/skills:$HOME/work/skills"   # once, for the machine
claude                                                          # every agent honours it
```

Nothing inside a project can set it.
A checkout you cloned from a stranger cannot ask for your home directory, because the declaration is not a file the project carries.

Each directory you name is granted **read-only**, individually, with no parent of it granted.
A session can read what you wrote there and cannot change it: the surface is lent, not handed over.
Unset the variable and the next session has none of it, with the agents' own configuration left exactly as you had it.

The three agents are pointed at the granted directories by three different mechanisms, because they have no common one:

| Agent | How it is pointed | What the environment writes |
| --- | --- | --- |
| `claude` | one symlink per skill, since it has no additive setting at all | `.agents/claude/skills/<name>` |
| `opencode` | its `skills.paths` setting, in a file of its own reached by `OPENCODE_CONFIG` | `.agents/opencode/config.json` |
| `pi` | its `skills` setting | `.agents/pi/settings.json` |

`.agents/pi/settings.json` is merged, never replaced, so anything else you keep in it survives.
The `claude` case only ever creates symlinks in that directory, so a real skill directory you put there is yours and is left alone.

`.agents/opencode/config.json` is the one file here this environment writes whole on every start, and it is the only one that is nobody else's.
`opencode` reads it in addition to your own `opencode.json`, not instead of it, so your settings still apply and your file is never read, written or fingerprinted by this environment.
The one exception is `skills.paths` itself: this file wins over your global one for that setting, and a project-scope `./opencode.json` in turn wins over this file, so a project that sets `skills.paths` gets what it asked for and none of `AGENT_SANDBOX_SKILLS`.
It is written whole rather than merged because `opencode` also writes to it — it adds its own `$schema` to every configuration file it loads, through an editor that emits a trailing comma when the file was empty, which is not JSON any more.
Anything you put in `.agents/opencode/config.json` yourself is lost on the next start; put it in `.config/opencode/opencode.json`, which is where it belongs and which is left alone.

**Skills are the whole of it, and here is every location that is not.**
The tables below name each place these agents read an extension from, so you never have to find out by experiment which of your own came with you.
They are the enumeration that was measured per agent, not a summary of it.

`claude` — its whole configuration root is moved to `.agents/claude`, so nothing under `~/.claude` is read at all:

| Location | Does your copy arrive? |
| --- | --- |
| `skills/` | **Yes**, one symlink per directory you declared |
| `agents/`, `commands/`, `output-styles/`, `rules/`, `themes/`, `workflows/` | No. The root moved, and nothing puts these back |
| `plugins/` | No, and deliberately — executable |
| every ancestor directory's `CLAUDE.md`, `.claude/rules` and `.mcp.json`, walked up to `/` | No. The walk leaves the project, and everything above it is denied |
| `/etc/claude-code/**` — managed settings, MCP and rules | No. Absolute, moved by no variable, and denied |
| `.claude/…` inside the project | Yes. It is in the project, so it was never outside |

`opencode` — its root is moved by `XDG_CONFIG_HOME`, and its own configuration file by `OPENCODE_CONFIG`:

| Location | Does your copy arrive? |
| --- | --- |
| `skills/` | **Yes**, through the `skills.paths` setting |
| `agent/`, `command/`, `prompts/`, `modes/`, `themes/` | No |
| `plugin/`, and `.opencode/plugin/*.ts` | No, and deliberately — executable |
| `~/.agents/skills` and `~/.claude/skills` | No. These are read `$HOME`-relative and **no variable moves them**; a session is denied `$HOME`, which is what stops them |
| `.opencode/…` inside the project | Yes |

`pi` — its root is moved to `.agents/pi` by `PI_CODING_AGENT_DIR`:

| Location | Does your copy arrive? |
| --- | --- |
| `skills/` | **Yes**, through the `skills` setting |
| `prompts/`, `themes/` | No |
| `extensions/`, and `.pi/extensions` | No, and deliberately — executable |
| `~/.agents/skills` | No, for the same `$HOME`-relative reason as `opencode`'s |
| `.pi/…` inside the project | Yes |

Two kinds of "no" in those tables are worth telling apart.
Most are a *relocation*: the agent looks in its new root, your host copy is still where you left it, and neither can see the other.
The `$HOME`-relative rows and `claude`'s ancestor walk are the other kind — locations no variable moves, where the agent genuinely still looks outside the project and is **denied**.
Those are the rows along which an extension could otherwise arrive in a session that declared nothing, so the suite asserts the undeclared case as a set equality rather than trusting that nothing was granted.

Nothing executable arrives by this route for any agent — a plugin, a hook or a `.ts` extension gets nowhere near it.
That is not an oversight in the declaration's reach; it is [what makes the declaration safe to inherit](#extending-an-agent). Such code runs with everything the session can reach, where a skill only tells the agent what to do, so widening for it is a decision to make deliberately rather than one to inherit from a variable set months ago.

### The API key inside a session is not your API key

Put your provider credential in the environment you start the agent from, as `ANTHROPIC_API_KEY`.
The session does not receive it.
What it receives under that name is 64 hex characters minted for that session alone, and requests carrying it are given the real credential on the way out by the supervisor, which never hands the real one down.

```sh
echo "$ANTHROPIC_API_KEY"     # outside: your key
claude                        # inside: a per-session substitute, and a different one next time
opencode                      # a substitute of its own, not the one claude was given
```

One credential in your environment serves every project and every agent.
There is no per-agent login: each agent declares the service it needs and is minted its own substitute, so no agent reads another's credential store, and starting a session in a second checkout needs no further login.

Two things follow that are easy to be surprised by.
Copying that value out of a session buys you nothing — it is not a credential the provider has ever seen, and it stops working when the session ends.
And granting `ANTHROPIC_API_KEY` through explicitly does not change this: the route overrides the grant, so there is no widening that gets your real key inside.

If the variable is unset outside, the session still starts and says so, in a `Credential not found for route 'anthropic'` warning naming the variable it looked for.
Its suggestion to store the key in a keychain is macOS advice and does not apply here.

### Migrating a setup you already have

If you already configure these agents for your whole machine, you adopt this environment for **one project** without changing the rest.
Nothing here reads, rewrites or fingerprints your host configuration, and your other projects go on working exactly as they did.
What follows is the line between what comes with you and what does not, stated rather than left to be discovered — which is the point, because a consumer whose skill loaded but whose stored session did not would reasonably conclude the boundary is arbitrary.

**What comes with you.**

- **Your skills**, at every location each agent reads them from, by declaring `AGENT_SANDBOX_SKILLS` once for the machine — see [Bringing your own skills in](#bringing-your-own-skills-in). Read-only, individually granted, and gone the moment you unset it.
- **Your provider credential**, in the sense that it still works: one value in your environment serves every project and every agent, and there is no per-agent login to redo.

**What does not, and is not meant to.**

| | Why |
| --- | --- |
| Every other authoring surface — `agents/`, `commands/`, `output-styles/`, `rules/`, `workflows/`, `themes/`, `prompts/`, and `opencode`'s agents, commands and modes | Named individually in [Bringing your own skills in](#bringing-your-own-skills-in). These are decisions to make deliberately, not to inherit from a variable set months ago |
| Anything executable — a plugin, a hook, a `.ts` extension | Such code runs with everything the session can reach, where a skill only tells the agent what to do. See [Extending an agent](#extending-an-agent) for the route if you want one anyway |
| Your conversation history and stored sessions | They are under your home directory, and a session reaches nothing there. Each project accumulates its own under `.agents/` |
| Your credential store on disk | The session is handed a per-session substitute instead, and never the real value |
| Your host confinement descriptions | These decide nothing about a session's reach. If configuration outside the boundary could define the boundary, there would be no boundary |

**What you give up, and what you get back.** This is the one place the trade is real rather than nominal.

The arrangement this replaces shared one credential between agents *by file*: one agent shelled out to another or read its credential file directly, which meant granting the authenticating agent's credential directory **read-write** inside the boundary.
That is what is gone. A session can no longer reach any agent's credential store, its own included.

What replaces it is capture on the supervisor's side: the token flow is intercepted outside the session, and what every process inside gets is an environment variable holding a substitute plus a mediated base URL.
So you keep the thing the old arrangement was *for* — authenticate once, and every agent in every project works — and you stop paying for it with a writable grant on a credential directory.
Two things you gain outright: no agent reads another's credential store, and a value copied out of a session is worth nothing to anyone, because the provider has never seen it.

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
Skills you authored yourself come with you by the separate route above, declared once for the machine rather than by widening this; the other authoring surfaces do not, and that is the gap that section names.

**`XDG_DATA_HOME` is a blanket too, and it splits direnv's own trust store in two.**
direnv records which `.envrc` files you have approved under `$XDG_DATA_HOME/direnv/allow`, and `.envrc` moves that root inside the checkout before `use flake` runs — it has to, because nix reads `trusted-settings.json` from there before it will evaluate a flake that declares `nixConfig`.
So from the moment the environment loads there are two trust stores: the host's, and this checkout's.
Approving a directory from inside the project writes the token into `<project>/.local/share/direnv/allow`, where nothing outside can see it, and the reverse holds as well.
The visible symptom is that `cd`-ing *out* of the checkout re-prompts you to `direnv allow` a directory you approved long ago: the shell hook evaluates the new directory while this project's `XDG_DATA_HOME` is still exported, so direnv looks for the token in the wrong store.
Approve it and you have written a duplicate token that only exists while you are in this project.
Nothing leaks and nothing breaks, but expect it, and prefer leaving the checkout in a shell that never entered it — start a session from outside if you intend to move around.

**A confined session gets its own set, and none of the table above reaches it.**
The variables in that table are the *shell's*, and the boundary passes almost nothing through: measured, a session inherits `HOME` and a handful of locale and terminal variables, and not one `XDG_*` root nor `TMPDIR`.
So the session's redirection is declared in its confinement description instead, and is a superset of the shell's:

| Variable | Resolves to |
| --- | --- |
| `TMPDIR` | `<project>/.tmp` |
| `XDG_CACHE_HOME` | `<project>/.cache` |
| `XDG_CONFIG_HOME` | `<project>/.config` |
| `XDG_DATA_HOME` | `<project>/.local/share` |
| `XDG_STATE_HOME` | `<project>/.agents/state` |

Expect those directories to appear in your project the first time you start an agent, alongside `.agents/`, and add them to your `.gitignore`.
`XDG_STATE_HOME` is on this list and not on the shell's, and the asymmetry is deliberate: the mechanism anchors its own supervisory state at whatever the *ambient* value names and refuses to grant any path overlapping it, so moving the shell's would make your checkout ungrantable while moving the session's does not.
Without the redirection a tool honouring one of these roots resolves it under `$HOME` and is denied, which is visible and survivable — except for `TMPDIR`, which falls back to `/tmp`, and `/tmp` is writable inside a session.
That one is the reason the list is five variables rather than one: a write outside your project that nothing reports, at a path every project shares.

**There are two accepted leaks.**

- `.envrc` calls `source_up_if_exists`, which reads a parent `.envrc` above the checkout.
  It is kept because that is a personal, machine-level concern, and direnv carries on when the read is denied.
- `$XDG_STATE_HOME/nono` stays on the host, because the mechanism anchors its own supervisory state there and refuses to start when any granted path overlaps it.
  It is not a leak-registry entry for that reason: an entry claiming to grant it would be false.
  A confined session's audit record — what it was actually granted — is written under it, which is how `check_j1_1` observes a real session rather than trusting a resolved policy.

**Egress is mediated, not restricted.**
Everything above is about the filesystem, and it would be easy to read the strictness of that boundary as applying to the network too.
It does not.
Raw TCP out of a session is denied, but arbitrary HTTPS through the injected proxy **succeeds** — measured, with `git ls-remote` against a public host from inside a session that was granted nothing outside its project.

So a session can reach any host it likes over HTTPS.
Asking an agent to fetch a package reaches the registry, and a compromised session can talk to whatever it wants.
The proxy is in that path in order to inject credentials and to keep the real one outside the boundary, which is a confidentiality property; it is **not** an allow-list, and no requirement here asks it to be one.
Restricting which hosts a session may contact is explicitly out of this feature's scope.

What this means in practice is that the thing stopping an agent from exfiltrating your other projects is that it cannot **read** them, not that it cannot **send**.
That is the guarantee, and it is worth knowing which half is doing the work.

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

It **exits zero**: `35 checks passed` on `x86_64-linux`, and `33 passed, 2 skipped` on `aarch64-darwin`.
`check_sc3` asserts a scenario-to-check bijection and was the feature's progress bar while it failed; it passes now, so every scenario in the spec has a check.
An exit status of zero is the whole report, and a skip is not a pass — the two the darwin arm reports are named under [Where the two platforms differ](#where-the-two-platforms-differ).

**No check can see an interactive prompt.**
`validate.sh` runs every check with `stdin` on `/dev/null`, which it must — an agent started in print mode reads stdin and will otherwise drain the loop feeding it the list of checks to run.
The cost is that a green suite says nothing about what happens on a terminal.
This was not hypothetical: the agent entry points shipped for a while unable to start at all, hanging on a consent question the mechanism asked on `stdin` while the wrapper sent its text to `/dev/null`, and every check passed throughout.
Where interactive behaviour is the criterion, assert on the arguments a command is invoked with instead — `check_r6`'s fourth arm logs the entry point's own `nono run` argv and requires the consent flag on every one — and enter the shell and type an agent's name by hand as well.

### What the automated run does not reach

A green suite is the whole report for what it covers, and this is what it does not cover.
Every item is a claim the repository makes that no unattended run can settle, so each carries the procedure a human runs — or says plainly that there is none and it is accepted as unreproducible.
None of them restates an assertion; where a check exists for a *narrower* version of the claim, the narrowing is what the entry names, and the check's own text stays the only place the assertion lives.

**Things that need a real account.**

- **A provider refusing a substitute.** The suite asserts the substitute's *shape*, that the real key is nowhere in the session, and that two sessions get different substitutes. That a provider rejects one copied out of a session needs a real account and a real key. The argument for it is strong — the substitute is minted per session and stops working when the session ends — but an argument is not an observation.
  *By hand:* inside a session, `echo "$ANTHROPIC_API_KEY"`. Leave the session, and present that value to the provider from outside it. Expect an authentication failure.
- **A provider request that succeeds.** Any request carrying a session's own substitute leaves the machine, so it cannot be part of an unattended check. `check_r8` shows only that the port does not answer `401` to everything.
  *By hand:* with your real key exported, start an agent and ask it anything. A completion arriving is the observation; there is nothing else to run.
- **Logging in through the browser.** Needs a browser and possibly a second factor. What the suite does cover is the half that is a value in the calling environment.
  *By hand:* run the agent's own login flow inside a session, complete it in the browser, and confirm a later session in a second checkout needs no further login.
- **Streamed responses through the interception proxy.** The proxy is in the path of every request, and a streamed response is the case where being in the path could show.
  *By hand:* inside a session, ask for something long enough to stream, and watch it arrive incrementally rather than in one block or not at all.
- **A credential evicted after long disuse.** The check invalidates a substitute artificially; the retention-driven case takes months.
  *No procedure.* Verified once and then trusted. Revisiting it means waiting, not running something.

**Things that need the other machine.**

- **How strong macOS enforcement is.** The suite asserts that both platforms grant the same reach. It cannot assert that Seatbelt's guarantee equals Landlock's, and it does not try.
  *No procedure.* This is a difference between two operating systems, not a behaviour to observe. It is described under [Where the two platforms differ](#where-the-two-platforms-differ), and that description is the whole of what is claimed.
- **The substrate denial set on macOS.** A syscall trace of a confined session is Linux-only, so `check_substrate_denials` reports `SKIP` there.
  *No procedure today.* `dtruss` needs SIP disabled and `fs_usage` needs root, neither of which is reasonable to ask. Closing it means writing the same differential against a macOS tracer, on a macOS machine.
- **The effective reach of the two platforms compared.** The automated comparison reads the description, not the kernel.
  *By hand:* start the same agent on each platform and read the capability banner it prints to stderr — the `r`, `w` and `r+w` lines. Compare the two by eye. Differences in store paths are expected and are the substrate; anything else is not.
- **A host genuinely unable to enforce confinement.** Every runner has the primitive, so the check plants the violation rather than reproducing the condition.
  *By hand:* run an entry point on a kernel too old to provide it, and expect nothing to start, a message naming the missing primitive, and exit status `77`. Accepted as unreproducible if no such machine is available — the plant is what stands in for it.
- **A machine with no warm store.** Consuming from the published reference is covered, but both the runner and any developer checkout have a populated store already.
  *By hand:* on a machine that has never built this, or after `nix store gc`, run the one command under [Entering the environment](#entering-the-environment) and let it finish.

**Things that are a human's decision rather than a behaviour.**

- **Your own trust settings for the substituter.** The declared substituter is ignored for anyone who is not a trusted `nix` user, and whether you are one is a property of your machine. The workflow restates the two settings rather than inheriting them for exactly this reason.
  *By hand:* `nix config show trusted-users`. If your user is not there, the three ways to decide it for yourself are under [Entering the environment](#entering-the-environment) — and a run that prints `ignoring untrusted flake configuration setting` is telling you which one applies.
- **A registry entry that names a host path.** The leak registry is this repository's reviewed content, pinned by the reference you name. An entry granting something outside a project would fail no check, because the registry sits on both sides of every reach comparison by design.
  *By hand:* `cat lib/leak-registry.nix` and read the entries, of which there are none today. This is a review gate, and it is written down as one.
- **Where a widening came from.** A widening supplied at the invocation is asserted to add exactly what it names. That it came from *you* and not from a checkout's own `.envrc` is your `direnv allow`, not an enforcement.
  *By hand:* `direnv status` in the checkout, and read which files you have allowed.
- **That no description pack was fetched.** Naming a description by name would fetch one and write executable hooks inside the project.
  *By hand:* `ls .config/nono/packages`. It should not exist. Nothing shipped here names a description by name, so anything there arrived from something you ran.

**Things that only a push settles.**

- **A runner accepting the workflow.** The suite asserts that `.github/workflows/verify.yml` *describes* the run this repository requires. That GitHub parses it, that nix installs on both images, and that the macOS job completes at all are settled by pushing.
  *By hand:* push, then `gh run list --workflow verify.yml` and read both jobs. A green pair is the observation; the suite cannot make it.

**One gap in a check's reach rather than in the product's.**

- **The pre-flight outside the devShell.** `lib/preflight.sh` execs its probe by bare name, so it depends on `PATH` resolving that name inside the granted substrate. On a host carrying its own copy outside the substrate the probe is denied and the pre-flight reports the wrong cause — fail-closed, but misleading.
  *By hand:* invoke an entry point by store path from a shell that never entered the environment, and read what it says. This is why the integration layer runs under `nix develop`, and why you enter through the devShell.
- **Four of nono's six configuration channels.** Two are asserted against a session; `--extends` and `--bypass-protection` are flags the entry point does not pass, and their absence is asserted by reading the entry point's text rather than by running one.
  *By hand:* `cat $(command -v claude)` and read the `nono run` line for yourself. Four flags being absent from a command line is a thing you can see; it is only the *reading* of it that is unautomated.

## Where the two platforms differ

Both supported platforms are verified by the same command. They are not equally strong, and they do not report the same things.

| | `x86_64-linux` | `aarch64-darwin` |
| --- | --- | --- |
| enforcement | Landlock | Seatbelt |
| tier | enforced, and observable from outside the sandbox | enforced, and **experimental** — the guarantee, not whether the platform is verified |
| how a refusal reads | `Permission denied` | `Operation not permitted` |
| syscall tracer | `strace`, in the devShell | none. `dtruss` needs SIP disabled, `fs_usage` needs root |
| supervisor trailer | absent — `No path denials were observed during this session.` | present — `N paths blocked` and a line per path |
| a protected path | a grant on `$HOME/.ssh` wins | marked `[permanently restricted]`, overridable only via `filesystem.bypass_protection` |
| suite result | `35 checks passed` | `33 passed, 2 skipped` |

**The two enforcements differ in what they report, not only in what they permit.** That is the practical difference: the trailer and the tracer are the same code in one binary, and Landlock starves the reporting path while Seatbelt feeds it. So a denial is *observable* on darwin without a tracer, and a permitted read is observable only on Linux. Every check that needs one of the two carries the split in one place.

Two checks therefore report `SKIP` on darwin rather than passing, which is deliberate — asserting something weaker under the same name would be worse:

- **`check_substrate_denials`** needs a syscall trace of a confined session. What darwin keeps is the component-layer equality in `check_sc1`, which reads the description rather than the kernel.
- **`check_j8_1`** needs to observe a *permitted* read, for which darwin has no instrument. What is lost there is the arrival of the declared authoring surface for `claude-code` and `pi`, and the arm asserting that the surface's undeclared neighbours are unreadable, for all three agents. What survives on darwin is the whole grant arm, read off the capability banner: each declared directory readable in its own right, none writable, and neither the parent nor the undeclared neighbour granted anything. Arrival for `opencode` is covered there by `check_opencode`, which asks the agent to enumerate what it loaded — the instrument the scenario itself names — and passes on both platforms.

**The cross-platform comparison is narrower than it looks.** The `platforms` job diffs each runner's confinement description with every `/nix/store/` path stripped out, and since the substrate is the whole of `filesystem.read` and the leak registry is empty, what it compares is one platform-independent expression of `$WORKDIR` placeholders and the state redirection. It proves nobody has made the description platform-dependent. It does **not** observe the effective reach on either platform, and the resolved floor — where nono's own `system_read_macos` and `system_read_linux_core` groups differ — is subtracted on both sides of every per-platform equality. Comparing effective reach across platforms is verified by hand, by reading the capability banner of the same agent on each.

## Known drift

This is the honest list of places where the repository does not yet do what it says, kept here rather than in a spec so it cannot be mistaken for backlog that someone else owns.
It is the natural input to the first spec.

**Portability.**

- Both declared systems are now entered and verified unattended, and how they differ is described under [Where the two platforms differ](#where-the-two-platforms-differ). What remains drift is that macOS enforcement is still labelled experimental, and that comparing the *effective* reach of the two platforms is done by hand rather than by the suite.
- Consuming from a ref passes — `check_j1_1` is the e2e layer, and it enters from the published reference into a clean `$HOME`. What it does not cover is a machine with no warm store, since the runner and this checkout both have one.

**Isolation.**

- **A project that *is* your home directory cannot start an agent.** The pre-flight proves confinement is enforced by reading a path outside the project and requiring the refusal; where the project is the whole home there is no such path left, so it refuses with `cannot verify confinement` rather than starting. That is the honest answer — confining a session whose project is the entire home would grant it everything — and per **P9** it is a refusal that says so rather than a session that runs unverified.
- Confinement is now observed rather than asserted, on both sides. `check_r6` proves the pre-flight refuses a host that cannot enforce it and `check_j1_1` compares a real session's granted reach against the project, the execution substrate and the leak registry; the refusal side is now checked too — `check_r1` reads a planted SSH key from inside a session and watches it fail, `check_r2` writes outside the project and watches the file not appear, `check_r3` puts an API-key canary in the host environment and proves it does not cross, `check_r4` has a session rewrite the source of its own confinement and proves nothing widens until a human re-enters, `check_r5` commits a confinement description to the checkout and proves the entry point does not read it, `check_r10` plants a host git configuration that runs a program and proves it neither crosses nor runs, `check_r8` presents a substitute that is no longer valid and proves the answer names an authentication failure rather than a denial, `check_r11` puts a demand for a signature in a checkout's own configuration and proves the commit is refused with no object created and no key read, and `check_j8_2` plants a whole host-global agent installation and compares the session's granted reach to the project, the substrate and the registry as a set. Each of them reads, writes or runs something it *is* allowed in the same session, so a session that failed to start cannot pass — and `check_controls` reads the suite's own text to keep it that way, because a refusal check whose control has been deleted goes on passing while proving nothing.
- A session is granted the closure of what it runs, and each agent has a substrate of its own: 128 store paths for `claude-code` and 128 for `opencode`, rather than the 67,000 the store holds. The leak registry is now **empty**. `check_j4_1` asserts the substitute's form, that the real value is nowhere in the session's environment or at rest in the project, and that two sessions get different substitutes; `check_j5_1` asserts that one credential in your environment serves every project and every agent, each minted a substitute of its own; and `check_r8` presents a substitute that is no longer valid and proves the answer is an authentication failure rather than a denial. What still has no check is a real provider refusing a substitute copied out of a session, which needs a real account and is verified by hand.
- **Two projects at once are checked concurrently, not one after the other.** `check_j3_1` runs two sessions in sibling checkouts at the same time and asserts that each reaches exactly one of them, that the two differ, and that neither can write into the other — confirmed from outside the sandbox, since a denial reported from inside is the sandbox's own account of itself. The two halves are separate on purpose: a *read-only* grant on a sibling checkout is a leak that no write attempt would ever observe.
- **A grant on an exact path beats a `deny` the mechanism carries for it.** The five `required` deny groups, `deny_credentials` among them, are not a backstop behind the leak registry — a registry entry naming `$HOME/.ssh` would read the key, with the deny sitting beside the grant in the resolved manifest. A grant on an *ancestor* of denied paths is refused and the session does not start, but do not expect the message to say so: granting `$HOME` is refused first for overlapping nono's own protected state root, at a path that need not even exist, and the deny rules are never mentioned. So the registry's strictness is the whole of the guarantee.
- **A confinement description written inside the project is one the mechanism will find, and what refuses it is a single command-line argument.** The blanket `XDG_CONFIG_HOME` puts nono's user profile directory inside the checkout, so a profile committed to a repository is listed by `nono profile list` and grants what it asks for the moment anything resolves it by name. The entry point passes `--profile <store path>` as an argument, and an argument beats `NONO_PROFILE`, which is why an untrusted checkout cannot grant itself paths. Nothing refuses the file itself.
- **The calling environment can widen a session, and that is deliberate.** `NONO_ALLOW` adds to a description the entry point pinned, and `--extends` adds a whole profile. That is the intended route for a consumer to lend a session something of their own. It is worth knowing that the mechanism cannot tell a variable exported above your checkouts from one exported by a checkout's own `.envrc`, so the trust boundary there is your `direnv allow`, not an enforcement.
- Two checks report `SKIP` on macOS rather than passing, because the platform has no instrument for what they assert. Both are described under [Where the two platforms differ](#where-the-two-platforms-differ).
- A confined session inherits `PATH` **whole**, host user profile included, and nono offers no way to narrow it: `set_vars.PATH` is rejected as reserved and `deny_vars` has no effect on it. Now that the store is no longer granted wholesale, this is literal: a tool the session can still *name* from the host profile is a tool it can no longer *run*.

**State that still resolves into `$HOME`.**

- **Inside a confined session, nothing does any more.** The session's description now names `TMPDIR` and four `XDG_*` roots including `XDG_STATE_HOME`, and each is observed resolving under the project and being writable there. What remains is the *shell's* `XDG_STATE_HOME`, which stays on the host and must: the mechanism resolves its own protected state root from that value and refuses to grant any path overlapping it, so redirecting it would make your checkout ungrantable. That the shell's and the session's resolutions are independent is measured, not assumed.
- A tool that ignores its relocation variable is still unaccounted for, and that is by design rather than by omission: it resolves a path under `$HOME`, which the session denies, and it fails visibly. What no check covers is a tool that neither honours the variable nor writes under `$HOME` — one that hardcodes `/tmp`, say, which is writable inside a session because it is in the floor the mechanism grants every process.
- **`claude --bg` does not work, and will not.** The background service listens on a socket under `/tmp`, at a path the payload hardcodes and derives from a digest of the configuration root, so no relocation variable moves it. The session is denied the `bind` and the `connect`, waits out its own 45-second timeout and exits 1 saying `Couldn't reach the background service`. Nothing escapes: the home directory is untouched and everything the attempt does write stays under the project. Allowing it would mean granting a recursively writable directory outside the project — nono's socket-bind flag implies a grant on the parent, and today's Linux fallback is recursive — to a daemon that outlives the session, so it stays refused. Interactive sessions and `claude agents --json` are unaffected.

**Tools the environment does not provide.**

- `git` is now in the devShell, and so is `strace` on Linux. `node` is not: it resolves from the host user profile, which by [AGENTS.md](../AGENTS.md#3-environment-and-tooling) §3 means it is *not available*, and a confined session cannot run it because it is outside the substrate.
- **`findutils` is not declared, and two checks depend on a GNU-only flag.** `check_opencode` and `check_pi` build their home manifests with `find -printf`, which BSD `find` does not have. It resolves on both runners today only because `nix develop`'s own stdenv supplies it. Where it does not, both manifests come out empty and the comparison passes having compared nothing — a silent pass, which is the failure mode **P9** forbids. `outside_root` in the same suite already avoids GNU-only `mktemp -p` for BSD's sake, so the suite is inconsistent with itself here.

**Orphans and small things.**

- There is no `justfile`, so the commands above are typed rather than named. `just` itself is in the devShell, so what is missing is the file and not the tool.
- `statix` and `deadnix` are absent entirely.
