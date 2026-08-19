# Research — 001-agent-sandbox

Findings from the `M1` spikes.
Each section records what was observed, against which artefact, so a later reader can re-run the observation rather than trust the conclusion.

Versions observed: `nono` 0.73.0, `claude-code` 2.1.233, `opencode` 1.18.18, `pi` 0.84.2, `codex` 0.146.0.
`plan.md`'s Technical context says `nono` 0.71.0; the machine has 0.73.0.

## M1b — Credential substitution per agent

### The question, as `plan.md` framed it, was the wrong question

[D1](plan.md#d1) forks on "whether each agent accepts a substituted API base URL", citing [spec.md](spec.md) line 302.
It does not.

`nono proxy --help` offers `--proxy-ca-cert`, `--proxy-ca-key` and `--proxy-ca-validity <1-365 days, default 1>`, and `nono run --help` carries `--upstream-proxy` alongside them.
nono is a **TLS-terminating intercepting proxy with its own generated CA**, not a loopback endpoint an agent must be pointed at.
`network.tls_intercept.ca_env_vars` is documented as "nono still sets the standard CA variables; profile entries add client-specific names that should point at the same generated trust bundle".

So the agent keeps addressing `https://api.anthropic.com`, and the credential is injected on the way past.
Endpoint substitution (`base_url_env_var`) exists but is **optional**, for clients that cannot be intercepted transparently.
The binding constraint is *CA trust*, not *base-URL configurability*.

This reconciles the two research documents at the repository root, which disagreed on exactly this point: `Deep Research on Nono Sandbox Mechanics…` describes a plain-HTTP loopback base URL, `Agents Sandbox Project Clarifications` describes MITM interception with a root CA.
nono does the latter and offers the former as a fallback.

### The two mechanisms, from `nono profile guide`

| | `network.credentials` + `custom_credentials` | `credential_providers` + `credential_routes` |
| --- | --- | --- |
| For | a credential presented as a key on every request | a credential obtained by an OAuth token exchange |
| Where the real secret sits | the supervisor, outside the boundary | the supervisor, outside the boundary |
| What the sandbox holds | **nothing** — the route is transparent | a phantom `nono_<64 hex>` |
| Endpoint substitution | optional, `base_url_env_var` on `CommandCredentialConfig` | optional, `base_url_env_var` on the route |
| Activation | a route in `custom_credentials` is inert unless its name **also** appears in `credentials` | provider declares `token_endpoints` and `api_hosts` |

Both keep the real secret outside.
`plan.md`'s characterisation of the fallback as "the agent persists a phantom" is right, but the phantom is inert off-loopback either way, so **neither branch is a weaker tier for FR-6**.

### Per agent

Base-URL evidence is from `strings` over each agent's payload; no agent was executed.

| Agent | Base URL configurable | By what | CA bundle honoured | Mechanism |
| --- | --- | --- | --- | --- |
| `claude-code` | **yes** | `ANTHROPIC_BASE_URL`, then `CLAUDE_CODE_API_BASE_URL`; also `env.ANTHROPIC_BASE_URL` in settings | `NODE_EXTRA_CA_CERTS`, with first-class application logic | `credential_providers` (OAuth), or `network.credentials` on an API key |
| `opencode` | **yes**, by config | `provider.<id>.options.baseURL`; `ANTHROPIC_BASE_URL`/`OPENAI_BASE_URL` exist but config precedence looks to shadow them | `NODE_EXTRA_CA_CERTS` | `network.credentials` |
| `pi` | **yes**, by config | `providers.<id>.baseUrl` in `models.json`; documented for exactly this use | `NODE_EXTRA_CA_CERTS` | `network.credentials` |
| `codex` | **yes**, by config | `model_providers.<id>.base_url` in `config.toml` under `$CODEX_HOME`; also `chatgpt_base_url`. No `OPENAI_BASE_URL` — the string is absent from the binary | `CODEX_CA_CERTIFICATE`, and it also reads `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `GIT_SSL_CAINFO`, `CARGO_HTTP_CAINFO`, `BUNDLE_SSL_CA_CERT` | `credential_providers` (OAuth) |

Decisive quotations:

- `claude-code` — `function Tgf(){return process.env.ANTHROPIC_BASE_URL||process.env.CLAUDE_CODE_API_BASE_URL||"https://api.anthropic.com"}`
- `pi` — `docs/models.md`: "Route a built-in provider through a proxy without redefining models … Existing OAuth or API key auth continues to work", confirmed in code by a request URL built from `model.baseUrl` with `/messages` appended
- `opencode` — the config schema's `options` struct carries `baseURL:D.optional(D.String)`, and the runtime does `if(D!==void 0)V.baseURL=D`
- `codex` — built from the pinned nixpkgs and inspected; Rust symbols `config_toml::deserialize_model_providers`, `validate_model_providers`, `merge_configured_model_providers`, `create_oss_provider_with_base_url` and `resolve_runtime_model_provider_base_url`, with the TOML field names `base_url` and `wire_api` adjacent in the serde table. It validates its CA variables — "custom CA env var points at an unreadable file", "custom CA env var does not point at a file"

`claude-code`, `opencode` and `pi` are Bun binaries and honour `NODE_EXTRA_CA_CERTS`; `codex` honours it too, among seven others.
That is the one CA lever proven across all four.
In the three Bun binaries `SSL_CERT_FILE`/`SSL_CERT_DIR` appear only as isolated symbols with no surrounding logic, so they are not established there.

### What the shipped nono packs actually do

`nolabs-ai/opencode` and `nolabs-ai/pi` ship byte-identical `custom_credentials` maps — routes for `openai`, `anthropic`, `gemini`, `github`, `gitlab` — with **`"credentials": []`**.
By nono's own activation rule those routes are inert as shipped.
None declares `base_url_env_var`, which corroborates that transparent interception is the intended path.

`nolabs-ai/claude` declares **no credential configuration at all**.
It instead grants `$HOME/.claude` read **and write**, plus `$HOME/.cache/claude`, `$HOME/.local/state/claude/locks` and `/tmp/claude-$UID`.
That grant is precisely the leak this feature exists to remove, so the shipped pack cannot be extended unmodified.

### Consequence for `M7`

The real secret is read by the supervisor.
On Linux there is no keychain, so `credential_key` must resolve through one of nono's URI schemes — `env://`, `file://`, `cmd://`, `op://`, `bw://` — and `file://` is the only one that would put a host path in play.
Choosing anything other than `file://` keeps the leak registry empty.

`nono run --credential __bogus__ --dry-run true` exits 0 and prints a normal capability summary: nono does **not** validate credential service names.
A typo would therefore produce an unauthenticated session rather than an error, so the wrapper must validate the name itself (P9).

## M1c — Git credentials inside the boundary

Source: nono 0.73.0's embedded security-group definitions (`meta.schema_version` `3.0`), read out of the binary; `git --version` 2.55.0; the host's own `git config --show-origin`.

### What each of the three does under confinement

| Source | Under confinement | Why |
| --- | --- | --- |
| A host credential helper | Not discovered, and its store is denied even if it were | `~/.gitconfig` is readable only through the `git_config` group, which the plan already declines to include because a readable git config lets an agent set `core.hooksPath` and fire host code later. On this machine the helper is `cache`, whose socket lives under `$XDG_CACHE_HOME/git/credential` — which this environment redirects into the project, so it resolves to an empty store rather than the host's |
| `~/.git-credentials` | Denied | Listed in the `deny_credentials` group, which carries `"required": true` and so cannot be dropped by a profile. The same group covers `~/.netrc`, `~/.ssh` and `~/.gnupg` |
| The system keychain | Denied | `deny_keychains_linux` (`~/.local/share/keyrings`, `~/.password-store`, `~/.1password`, `~/.op`) and `deny_keychains_macos` (`~/Library/Keychains`, `/Library/Keychains`, …) are both `"required": true` |

No group grants a git credential. `git_config` grants **read** on `$HOME/.gitconfig`, `$HOME/.gitignore_global` and `$HOME/.config/git/{config,ignore,attributes}` and nothing else.

One trap worth recording: the `codex_macos` group grants `$HOME/Library/Keychains/login.keychain-db` read **and write**. Including it would undo `deny_keychains_macos`, so `M8` must not take it.

### Trust in the inspecting authority does reach `git`

Separate question, and the one Journey 6 actually exists to answer. nono's child environment carries a contiguous run of CA-bundle variables — `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO` — alongside the `tool-sandbox` launch machinery, and the profile guide describes `network.tls_intercept.ca_env_vars` as adding client-specific names beyond these: "nono still sets the standard CA variables".

`GIT_SSL_CAINFO` is the load-bearing one. It is what makes an ordinary `git` HTTPS exchange survive interception, and it is what FR-17 asks for.

### Decision

**Journey 6 narrows to an exchange that needs no credential, and `git` gets no registry entry.**

- A registry entry was rejected: every store it could point at is in a `"required": true` deny group, so the entry would have to fight the mechanism's own floor.
- Routing `git` through substitution was rejected as a shipped default, not as impossible. It works — a `custom_credentials` route with `upstream` `https://github.com`, `inject_mode` `basic_auth` and `credential_key` `env://GITHUB_TOKEN` would authenticate a push without the credential ever entering the boundary. It is not shipped because it names one forge, demands a token no requirement here asks for, and covers only HTTPS remotes. It belongs to the consumer, and Out of scope says so.
- Note that the shipped `github` and `gitlab` routes in the `nolabs-ai/opencode` and `nolabs-ai/pi` packs would not serve a push in any case: their upstreams are `https://api.github.com` and `https://gitlab.com/api`, the REST endpoints, not the hosts `git` pushes to.

`spec.md` is corrected in place: Journey 6's When and Then, its *Independently verifiable by*, a new Out of scope entry, and Risk 2 marked resolved by its own stated fallback.

### Verification gap

`nono run` could not be executed from this session — the outer sandbox denies `$HOME`, and nono fails to create `~/.local/state/nono/audit/…`. So the CA-variable finding is read out of the binary and the guide rather than observed in a live child environment. `check_j6_1` observes it for real at the integration layer.

## M1d — pi's configuration root

Observed against `pi` 0.84.2, `libexec/pi/pi`, the shipped `libexec/pi/docs/` tree, and live runs.

### It relocates, and one variable is enough

`PI_CODING_AGENT_DIR` is the whole configuration root. The binary resolves it in exactly one place:

```js
this.logDirectory = logDirectory ?? process.env.PI_CODING_AGENT_DIR ?? path6.join(os2.homedir(), ".pi", "agent");
```

`docs/environment-variables.md` agrees — "Override the config directory; default is `~/.pi/agent`" — and `docs/quickstart.md` names what that root holds: "Uninstalling pi leaves settings, credentials, sessions, and installed pi packages in `~/.pi/agent/`."
All four, under the one root.

The claim is checked, not inferred. Of the five `homedir()`-rooted path constructions in the binary, only one belongs to `pi`:

| Construction | What it is |
| --- | --- |
| `homedir(), ".pi", "agent")` | the configuration root, the only one |
| `homedir(), ".config", "gcloud", "application_default_credentials.json")` | a credential *read*, for the Vertex provider only; already denied by nono's `deny_credentials` |
| `homedir(), ".bun")` | the embedded Bun runtime's own install directory, not `pi` state |
| `homedir(), N.slice(2)` and `homedir() + resolved.slice(1)` | generic `~/` expansion helpers |

### Observed, both ways round

With the override, `pi install <local path>` and `pi install npm:left-pad@1.3.0` both succeed and write only under it:

```text
$PI_CODING_AGENT_DIR/settings.json
$PI_CODING_AGENT_DIR/npm/{package.json,package-lock.json,.gitignore}
$PI_CODING_AGENT_DIR/npm/node_modules/left-pad
```

Without it, the same command fails on the home directory, which this session's outer sandbox denies:

```text
Error: EACCES: permission denied, mkdir '/home/pallon/.pi/agent/settings.json.lock'
```

That failure is the control. It fixes the default at `~/.pi/agent`, shows `pi` *writes* there rather than merely reading, and shows the override is what moved it.

**`pi` needs no registry entry.** Nothing it persists escapes `PI_CODING_AGENT_DIR`.

### `PI_CODING_AGENT_SESSION_DIR` does not exist

The task named it, and `docs/environment-variables.md` line 82 documents it, but the string does not occur anywhere in the 112 MB binary — where `PI_CODING_AGENT_DIR` occurs exactly once.
Setting it is a no-op, and the shipped documentation is stale against the code it ships with.
Sessions live under the one root, as `quickstart.md` says.
`--session-dir` remains the documented way to move them, and moves them per invocation rather than per environment.

### FR-22 — the run-time fetch

`pi` does extend itself at run time, and `docs/packages.md` is explicit about where it lands:

- user installs → `~/.pi/agent/npm/`, so with the override, inside the project
- project installs (`pi install -l`) → `.pi/npm/`, already inside the project
- git packages → `~/.pi/agent/git/<host>/<path>` or `.pi/git/<host>/<path>`
- "pi installs any missing packages automatically on startup after the project is trusted"

So the *landing site* is inside the project once the root is relocated, and FR-4 is satisfied.
FR-22 is a separate matter and is not satisfied by relocation: that last line is a fetch from inside the session.

Two observations sharpen it.
`pi install` runs a real `npm install` — reached the registry here even with `PI_OFFLINE=1`, because that variable disables *startup* network operations, not explicit commands.
And although `settings.json` records the pinned spec `npm:left-pad@1.3.0`, the `package.json` `pi` generates beside it reads `"left-pad": "^1.3.0"` — a caret range, resolved when the install runs.

**The environment therefore ships no `pi` packages and sets `PI_OFFLINE`.**
With no packages declared there is nothing to install on startup; `PI_OFFLINE` also suppresses the update check and the model-catalogue refresh.
A consumer who wants a package provisions it into the project before the session, which is exactly what FR-22 asks for.

## M1e — Machine-readable resolved policy

Two commands emit structured output, and they answer different questions.
A third does not, and is rejected.

| Command | Output | What it answers |
| --- | --- | --- |
| `nono profile show <name> --format manifest` | pure JSON, `$schema` `https://nono.sh/schemas/capability-manifest.schema.json`, `version` `0.1.0` | the whole resolved grant set, enumerable |
| `nono why --json --path P --op O` | pure JSON, one verdict | whether one specific path or host is reachable |
| `nono run --dry-run` | human text only | nothing a check can assert on |

`--format` accepts exactly `profile` and `manifest`; `profile` is the banner-decorated human rendering, and there is no `json` value.
`--diagnostics-json` does not help, because its help text says it prints "**after the run**", so `--dry-run` never reaches it.

### The manifest is what `check_sc1` and `check_component_merge` will use

`nono profile show <name> --format manifest` resolves `extends`, the security groups and the profile's own rules into one document with four keys — `filesystem`, `network`, `process`, `version` — where `filesystem` carries `deny` and `grants`, and each grant is `{"access": "read"|"readwrite", "path": …, "type": "directory"|"file"}`.

That shape is what makes the property in `SC-1` expressible as a property rather than as a list of paths written down in the check:

```sh
# every granted path resolves under the project, bar the registry's entries
nono profile show "$profile" --format manifest | jq -r '.filesystem.grants[].path'
```

`check_component_merge` uses the same command against a profile and its base, which is the only way to observe merge semantics without starting a session.

**The manifest is the sandbox-capability view, not the whole profile.**
Its `network` key carries only `dns` and `mode`; `credentials`, `custom_credentials`, `credential_providers` and `credential_routes` do not appear.
Credential wiring must therefore be asserted against the profile source, not the manifest.

Run against the shipped `claude-code` profile it states the leak `M1b` found, in a form a check can read:

```json
{"access":"readwrite","path":"/home/pallon/.claude","type":"directory"}
{"access":"readwrite","path":"/home/pallon/.claude.json","type":"file"}
{"access":"readwrite","path":"/home/pallon/.cache/claude","type":"directory"}
{"access":"readwrite","path":"/home/pallon/.local/state/claude/locks","type":"directory"}
{"access":"readwrite","path":"/tmp/claude-1000","type":"directory"}
```

### `nono why --json` answers the refusal scenarios

It needs no session, writes nothing, and reports its verdict as data:

```json
{ "status": "denied", "reason": "filesystem_deny",
  "details": "Path is covered by filesystem.deny rule: /home/pallon/.ssh",
  "policy_source": "filesystem.deny" }
```

An allowed answer carries `"status": "allowed"`, `"reason": "granted_path"`, `"access"`, and a `"source"` of `user` or `profile` — so a check can tell a grant the caller passed in from one the profile brought.
`--host`/`--port` answers the network question in the same shape.

**Its exit status is `0` whether the verdict is `allowed` or `denied`.**
A check must read `.status`; treating exit status as the verdict would pass vacuously on every refusal scenario, which is the exact failure mode **P9** exists to prevent.

### The compiled-in presets do not exist

The criterion asked to confirm that `codex`, `claude-code` and `opencode` are built in.
**They are not.**
On a clean `$HOME`, `nono profile list` reports nine built-in profiles and they are all language runtimes:

```text
bun-dev  default  go-dev  java-dev  linux-host-compat  mise-dev  node-dev  python-dev  rust-dev
```

Every agent profile on the developing machine is **package**-sourced, from `nolabs-ai/claude`, `nolabs-ai/opencode` and `nolabs-ai/pi`, fetched at some earlier time into `$XDG_CONFIG_HOME/nono/packages`.
There is no `codex` profile from any source.

This falsifies `plan.md`'s P8 row as written, and the correction is recorded there.
It also settles a question `M1b` left open in the environment's favour: since the packs must be either fetched or replaced, and since the `nolabs-ai/claude` pack grants `$HOME/.claude` read-write, **the environment authors its own profiles extending `default`** rather than extending a pack. Purity and the boundary want the same thing.

### Two hermeticity findings

**nono checks for an update on almost any invocation.**
A first run in a clean `$HOME` wrote `$XDG_STATE_HOME/nono/update-check.json` containing a `cached_result` with a `release_url` — a real network call, from a command as innocuous as `profile list`.
`NONO_NO_UPDATE_CHECK=1` suppresses it: the same run then wrote **no files at all** and produced identical output.
Every check that invokes `nono`, and the environment itself, sets it.

**nono silently falls back to the host's `$HOME/.config` when `XDG_CONFIG_HOME` does not exist.**
It warns — `Ignoring invalid XDG_CONFIG_HOME='…' (canonicalize failed: No such file or directory)` — and then carries on reading the host's profiles and packages.
The variable being exported is therefore not sufficient; **the directory must exist before `nono` runs**, or the redirection this whole environment depends on is undone by a warning most users will not read.

### `nono profile schema` and `nono profile validate`

`nono profile schema` emits a 102 KB JSON Schema, and it is usable — the skeleton `nono profile init` generates validates clean, and `validate` bites on three separate arms:

| Planted | Reported | Exit |
| --- | --- | --- |
| `groups.include += ["__no_such_group__"]` | `Group '__no_such_group__' not found in policy.json` | 1 |
| unknown top-level key | `unknown field 'totallyBogusKey', expected one of …` | 1 |
| `workdir.access = 99` | `expected a string or object for enum on line 12 column 15` | 1 |
| reverted | `Result: valid` | 0 |

Unlike `nono why`, `validate` **does** report its verdict in the exit status.
The rejection of an unknown top-level key also enumerates the profile's whole surface, which is the authoritative list for `M3`:

`$schema`, `extends`, `meta`, `security`, `groups`, `commands`, `filesystem`, `policy`, `network`, `diagnostics`, `linux`, `env_credentials`, `secrets`, `environment`, `command_policies`, `credential_capture`, `credential_providers`, `credential_routes`, `workdir`, `hooks`, `session_hooks`, `rollback`, `undo`, `open_urls`, `allow_launch_services`, `allow_gpu`, `allow_parent_of_protected`, `interactive`, `skipdirs`, `packs`, `binary`, `brokered_commands`, `command_args`, `unsafe_macos_seatbelt_rules`, `platform_overrides`.

### `environment` — `ai.nix`'s constraint does not hold, and D4 and D6 are confirmed

`ai.nix` records that "nono has no general `--env` flag; it inherits the parent environment".
That is true of the *command line* in 0.73.0 — `nono run` still has no `--env` — and false of the *profile*.
`plan.md`'s D4 and D6 already assume the profile-level key; this spike is what turns that assumption into an observation.
The schema defines:

- `environment.set_vars` — "Static environment variables injected after environment filtering and before credential injection. PATH and NONO\_\* are reserved. Values support variable expansion (`$HOME`, `$WORKDIR`, `$TMPDIR`, `$XDG_*`, `$NONO_CONFIG`, `$NONO_PACKAGES`)."
- `environment.allow_vars` — an allow-list, exact names or a `*` suffix; when empty or absent, everything passes.
- `environment.deny_vars` — stripped even when also allowed.

Precedence, from the schema: hardcoded dangerous variables always stripped, then `deny_vars`, then `allow_vars`.

Two consequences:

1. Each agent's `stateVars` — `CODEX_HOME`, `PI_CODING_AGENT_DIR`, `OPENCODE_CONFIG` and the rest — belong in `environment.set_vars` **inside the profile**, expressed against `$WORKDIR`, rather than being exported by a wrapper script. The confinement description and the relocation then live in one artifact and cannot drift apart. `$WORKDIR` expansion is what makes the same profile text correct in every project, so nothing is generated per checkout.
1. `environment.allow_vars` is the mechanism for the repetition scenarios, as D6 states. An allow-list closed to the variables the environment sets is what makes "the previous project's variables do not reach this session" a property of the profile rather than a hope about the caller's shell.

D4's merge claims — `set_vars` merging as a map with the child winning, `allow_vars`/`deny_vars` additive — are **not** settled here.
The schema describes the fields, not how `extends` combines two of them.
`check_component_merge` in `M3` observes that, and until it does, D4 remains an assertion.

## M1f — Agent packages in the pinned nixpkgs

The pinned input is `github:NixOS/nixpkgs/0954f7ee2f6bb3dc7d4e3d0d8bcb8fd4bde4cfc5`, read from `flake.lock` rather than from the `nixpkgs#` registry alias, which on this machine resolves to a different and newer revision.

### Availability

Evaluated as `legacyPackages.<system>.<attr>.name`, both systems, against the pinned revision and against `github:numtide/llm-agents.nix/3589c0056622cba72e32e456ddd9971b9a60e545`.

| Attribute | Pinned `nixpkgs` | `llm-agents.nix` |
| --- | --- | --- |
| `codex` | `codex-0.145.0`, Apache-2.0 | `codex-0.147.0`, Apache-2.0 |
| `claude-code` | `claude-code-2.1.220`, **unfree** | `claude-code-2.1.235`, labelled unfree but marked free |
| `opencode` | `opencode-1.18.4`, MIT | `opencode-1.18.18`, MIT |
| `pi` | **absent** | `pi-0.84.2`, MIT |
| `nono` | `nono-0.68.0`, Apache-2.0 | `nono-0.73.0`, Apache-2.0 |

Every row is identical on `x86_64-linux` and `aarch64-darwin`; no agent is missing on one platform and present on the other.

### The extra input is genuinely needed, and for two reasons

`pi` does not exist in the pinned `nixpkgs` under any spelling — `pi`, `pi-agent` and every near-miss the evaluator suggested (`piv-agent`, `glpi-agent`, `os-agent`) are other packages.
That alone settles it: **`numtide/llm-agents.nix` is added, because something is genuinely missing**, which is the condition the task set.

The second reason is `nono` itself.
The pinned `nixpkgs` carries `0.68.0`; every finding in `M1b`, `M1c` and `M1e` was observed against `0.73.0`, and `M1e`'s findings are specifically about a surface — `--format manifest`, `nono profile validate`, `environment.set_vars` — whose presence in `0.68.0` has not been checked.
Taking `nono` from the same input as the agents keeps the confinement descriptions and the binary that reads them versioned together, which is what `plan.md`'s **P8** row claims.
`plan.md`'s Technical context said `nono` 0.71.0, which matched neither source; `M1f` corrected that row in place.

### `allowUnfree`

Only `claude-code` raises the question, and the two sources answer it differently.

The pinned `nixpkgs` declares `license.free = false`, so an unmodified `pkgs` refuses to evaluate it.
`llm-agents.nix` declares `{ fullName = "Unfree"; shortName = "unfree"; redistributable = false; free = true; }` — the label says unfree and the flag says free, so `allowUnfree` is never consulted and the package evaluates silently.

**The environment sets `allowUnfree` explicitly for `claude-code` anyway**, scoped to a `pkgs` instantiated for that one package.
Relying on an upstream mislabel to pass a gate is exactly the silent fallback **P9** forbids: the environment would work today and break the day the label is fixed, with nothing in this repository having changed.
Writing it down states the fact — Anthropic's terms are not free — where the current behaviour hides it.

### The binary cache is declared, not left to chance

`llm-agents.nix` declares its own `nixConfig`, read from its `flake.nix` at the revision evaluated here:

```nix
nixConfig = {
  allow-import-from-derivation = false;
  extra-substituters = [ "https://cache.numtide.com" ];
  extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
};
```

The key's label names `niks3.numtide.com`, not the substituter's host; key names are arbitrary labels rather than addresses, so the pair is consistent and the mismatch is upstream's naming, not an error.

**This environment declares the same substituter and key itself, in its own `nixConfig`, and passes both explicitly in CI.**
A `nixConfig` on an input is not inherited: nix applies it only for the flake being evaluated directly, and only for a trusted user — so a consumer of *this* repository would otherwise get no substituter at all and build five agents from source, one of which is a 440 MB Rust binary.
Declaring it here is what makes the cache actually reachable both by a human entering the environment and by the checks, which is the difference between a first-run cost and a first-run failure on a runner with a time limit.
An untrusted user still gets a prompt rather than the cache; that residue is handbook material, since no check can assert against the consumer's own trust settings.

Two further facts from the same block, for `M4b`:

1. `allow-import-from-derivation = false` — the input asserts its own purity, which **P8** wants and which nothing here needs to relax.
1. It pins its own `nixpkgs` (`b47ad65d…`, unstable). Whether it is given `inputs.nixpkgs.follows` — one revision in the closure, at the risk of breaking a package built against another — or left independent, is `M4b`'s decision and is not settled here.

Upstream `HEAD` moved to `c4c6673c4c1ceb69d845fa665a714e1273d0acac` while `M1` was in flight.
Every version in the table above was read at `3589c005…`, so the lock must pin a revision explicitly rather than track the branch, or the numbers recorded here stop describing what is built.

### Verification gap

Availability was established by evaluation, not by building.
`codex` was built during `M1b` and substituted without compiling; the other four were not built on either platform, and nothing here was built for `aarch64-darwin`, which no check in this repository can reach.
