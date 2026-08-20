# Research — 001-agent-sandbox

Findings from the `M1` spikes, and from every later task that could not state a criterion without measuring something first.
Each section records what was observed, against which artefact, so a later reader can re-run the observation rather than trust the conclusion.
A section named after a `PENDING` task is a spike run ahead of it, and says so.

Versions observed: `nono` 0.73.0 for the `M1` sections and 0.74.0 from `M4b` onward, `claude-code` 2.1.233 then 2.1.237, `opencode` 1.18.18, `pi` 0.84.2, `codex` 0.146.0.
The pinned toolchain arrived with `M4b`; everything before it was measured against whatever the host offered, which is recorded per section.

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

### Trust in the inspecting authority does reach `git` — but only where something is inspected

Separate question, and the one Journey 6 actually exists to answer. This was first answered wrongly, and the correction is the more useful record.

**The wrong answer.** The binary carries a contiguous run of CA-bundle variable names — `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO` — beside the tool-sandbox launch machinery, and the profile guide says of `network.tls_intercept.ca_env_vars` that "nono still sets the standard CA variables". Read together those looked like a guarantee that every session gets them. Inferred, never observed.

**Falsified.** A plain `nono run -- env` passes 233 variables to the child and **not one of them is a CA variable**. The strings are the names nono *would* set, sitting in code that does not always run.

**The right answer.** `network.tls_intercept` has no `enabled` switch — its properties are only `ca_lifecycle`, `ca_validity`, `leaf_validity` and `ca_env_vars` — because interception is not a session-wide mode. The guide, line 361, gives two forms of `allow_domain` entry: a plain string is a CONNECT tunnel, an object with `endpoints` is inspected. Line 375: "the proxy performs TLS interception to enforce method+path restrictions (default-deny). This is useful for restricting access to specific API endpoints **without credential injection**." So inspection is per-destination, switched on by a credential route or by an object-form entry.

Switch it on and the variables appear. Observed, with `--allow-domain 'https://github.com/**'`:

```text
SSL_CERT_FILE=~/.local/state/nono/sessions/intercept-80452-522455426/intercept-ca.pem
REQUESTS_CA_BUNDLE=…/intercept-ca.pem   NODE_EXTRA_CA_CERTS=…/intercept-ca.pem
CURL_CA_BUNDLE=…/intercept-ca.pem       GIT_SSL_CAINFO=…/intercept-ca.pem
```

Five variables, one authority, minted per session — matching `ca_lifecycle: session`, "a per-run CA exposed through trust-bundle env vars". `GIT_SSL_CAINFO` is the load-bearing one for FR-17.

**The consequence for `check_j6_1`, which is the whole point of recording this.** `plan.md` first specified it as "assert exit 0, which holds only if the interception CA reached `git`". That claim is false in both directions. `git` exits 0 when trust propagated, and it also exits 0 when nothing was inspected at all, because `/etc/ssl` and `/etc/pki` are in the bare floor and the real certificate validates fine. One observable, two opposite states of the feature, so the check would have passed with the feature deleted. **Trust propagation is only observable as a difference**, so the check must carry both sides — see `plan.md`'s entry for it.

### Decision

**Journey 6 narrows to an exchange that needs no credential, and `git` gets no registry entry.**

- A registry entry was rejected: every store it could point at is in a `"required": true` deny group, so the entry would have to fight the mechanism's own floor.
- Routing `git` through substitution was rejected as a shipped default, not as impossible. It works — a `custom_credentials` route with `upstream` `https://github.com`, `inject_mode` `basic_auth` and `credential_key` `env://GITHUB_TOKEN` would authenticate a push without the credential ever entering the boundary. It is not shipped because it names one forge, demands a token no requirement here asks for, and covers only HTTPS remotes. It belongs to the consumer, and Out of scope says so.
- Note that the shipped `github` and `gitlab` routes in the `nolabs-ai/opencode` and `nolabs-ai/pi` packs would not serve a push in any case: their upstreams are `https://api.github.com` and `https://gitlab.com/api`, the REST endpoints, not the hosts `git` pushes to.

`spec.md` is corrected in place: Journey 6's When and Then, its *Independently verifiable by*, a new Out of scope entry, and Risk 2 marked resolved by its own stated fallback.

### The host git configuration runs inside the boundary, and this changes a grant

Found by accident, while confirming the CA variables. The same session was given `--allow-file ~/.gitconfig`, and `git` did this:

```text
fatal: unable to create directories for '…/agent-sandbox/.cache/git/credential': Permission denied
fatal: cache daemon did not start:
```

`git` had read `credential.helper = cache` out of the host's `~/.gitconfig` and tried to **start a daemon**. It failed only because that session's workdir happened to be read-only. In the shipped arrangement the workdir is read-write, so it would have succeeded: a host configuration file starting a long-lived process inside the boundary and writing into the project.

This is the same class of hazard `plan.md` already cited when declining to grant `$XDG_CONFIG_HOME/git` — a readable git config lets `core.hooksPath` fire host code later — but observed, through a different key, on the file that had looked harmless enough to grant. nono's `git_config` group is what grants it, read-only, and read-only is no protection: the danger is in the directives, not in writing to them.

The host configuration can be neutralised entirely. Verified on git 2.55.0:

```sh
git config --show-origin --get credential.helper
# file:/home/pallon/.gitconfig	cache

GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git config --get credential.helper
# exit 1 — the directive is gone
```

**Decision.** Do not include nono's `git_config` group, grant no host git configuration file, and set `GIT_CONFIG_GLOBAL` to a project-owned file plus `GIT_CONFIG_SYSTEM=/dev/null` through `environment.set_vars`. Withholding the grant alone would already stop the read, but directing the toolchain instead makes the effective configuration identical on every machine — which is what the repetition scenarios ask for — and gives the commit identity somewhere to live. The author's name and address are copied out of the host once, at setup, and a consumer may override them; they are not credential material and the copy is visible in the file it produces. This is `spec.md`'s new **R10** and **FR-23**.

### Verification gap — closed, and the constraint it recorded was too strong

Everything above that needed a live session was run outside this one and reported back, because a bare `nono run` from inside it fails:

```text
nono: Snapshot error: Failed to create session directory
      /home/pallon/.local/state/nono/audit/…: Permission denied (os error 13)
```

`M1c` concluded from that failure that a confined session is unreachable from an agent session in this repository. **That is false, and the correction matters to the suite rather than only to the record**: nono derives its state root from the environment, so pointing the environment somewhere writable is enough. A real, kernel-enforced session runs from inside the outer sandbox under four conditions, each found by the failure it removes.

| # | Condition | Observed failure when it is missing |
| --- | --- | --- |
| 1 | `TMPDIR` points inside the project | `nono: Sandbox initialization failed: Refusing to grant '/home/pallon/.cache/opencode/tmp' (source: group:system_write_linux) because it overlaps protected nono state root '…/nonostate/nono'.` |
| 2 | `XDG_STATE_HOME` points at a writable path **outside** the project that no group grants | the state root is not granted to the supervisor, and the run fails after the child has finished |
| 3 | `$XDG_STATE_HOME/nono/audit/ledger.ndjson` exists before the run | `nono: Snapshot error: Failed to copy legacy audit ledger to temporary file …/audit/ledger.ndjson.tmp: Permission denied (os error 13)` |
| 4 | `/nix/store` is granted read | `/bin/sh` exits **127**, with nono's own diagnostic that it "resolved to /bin/sh and is readable, but execution still failed" |

Condition 1 is the fail-closed refusal `plan.md` Risk 4 wants pinned, now observed rather than predicted: nono will not grant a path that overlaps its own state root, and says so instead of proceeding. Conditions 1 and 2 are therefore one constraint seen from both sides — the state root must be somewhere the sandbox neither grants nor denies. Condition 4 is `M1e`'s `nix_runtime` finding arriving by a different route.

**Condition 3 is load-bearing for every check in this repository, not just for running by hand.** The migration that fails runs *after* the child exits, and its failure **replaces the child's exit status with 1**. A session whose child exited 0 reports 1; a refusal that should exit 77 reports 1. Every assertion in the suite that reads an exit status — the pre-flight's `77`, the refusal scenarios, their positive controls — would be reading the supervisor's cleanup rather than the child, and `check_controls` could not tell the difference. `touch`ing the ledger suppresses it; unsetting `NONO_AUTO_MIGRATE` does not. `scripts/checks/integration.sh` must establish it before its first session, and `NONO_NO_UPDATE_CHECK=1` from `M1e` goes in the same place.

The incantation that satisfies all four:

```sh
env -u NONO_AUTO_MIGRATE -u NONO_CAP_FILE \
  TMPDIR="$PWD/.tmp/t" \
  XDG_STATE_HOME=/some/writable/path/outside/the/project \
  NONO_NO_UPDATE_CHECK=1 \
  nono run --allow-cwd --read /nix/store -- <cmd>
```

Verified with it, in this checkout, from an agent session: exit statuses propagate faithfully (`true` → 0, `false` → 1, `exit 77` → 77); a child's stdout is returned; a child reading `$HOME` is denied; a child writing a canary outside the project fails and the canary does not exist afterwards. So kernel enforcement is observable here, and the integration layer is not the human-only layer `M1c` took it for.

**What still needs a human** is narrower than a layer. An interactive OAuth login needs a browser, and a live provider rejection needs a real account in a real state; both are already in `plan.md`'s coverage gap. That is why `M1g` is run by hand — not because a confined session is out of reach.

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

`check_component_merge` uses the same command, which is the only way to observe merge semantics without starting a session.
`M3d` settled what it compares: not a profile against its base, since [D10](plan.md#d10) means no description names one, but the description under test against three derived counterparts — the same description stripped to `{meta}` for the floor, with one probe path added to `filesystem.read` for precedence, and with one probe group added to `groups.include` for additivity.
It also found the manifest carries a fifth key, `$schema`, alongside the four above, and **no `environment` key at all**, which is why the `allow_vars`/`deny_vars` order is asserted behaviourally by `check_r3` rather than here.

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

D4's merge claims are **not** settled here, because the schema describes the fields and not how they combine.
`M3d` settled the ones this environment rests on, by observation against resolved manifests: the floor arrives in full though no parent is named, an included group adds grants and removes none, and a `required` group's `deny` survives a description grant for the same path.
The one it could **not** settle is the `allow_vars`/`deny_vars` order recorded at the top of this section, because the resolved manifest has no `environment` key and no other resolved form prints one.
That order is read from the schema and stays read from the schema; nothing here depends on it, since [D6](plan.md#d6) sets an allowlist and no `deny_vars`, and FR-5's real requirement is asserted from inside a session by `check_r3`.

### A description names no parent, and the floor is the same either way

Three descriptions were written by hand under a redirected `XDG_CONFIG_HOME`, `XDG_STATE_HOME` and `HOME`, and their resolved manifests compared. One with no `extends` key and one with `extends: ["default"]` resolve **byte-identically** — `grants=33 deny=48 netmode=unrestricted blocked=46`, the only difference being the pid in the `/proc/<pid>` grants of whichever process asked. `default` is the floor every description sits on, not something a description opts into by naming it. **So descriptions name no parent and declare what they want**; naming one would imply an inheritance that is not what happens.

Three shape facts, each learned from the error it produces:

- `meta.name` is required — omitting it gives `Profile parse error: missing field \`name\` on line 2 column 11\`, exit 1.
- `groups` is `{"include": […], "exclude": […]}`, not a map of booleans: `{"nix_runtime": true}` gives `unknown field \`nix_runtime\`, expected \`include\` or \`exclude\`\`.
- `network.mode` is derived and cannot be set. The default is `unrestricted`; `{"block": true, "allow_domain": ["api.anthropic.com"]}` resolves to `{"allow_domains": […], "dns": true, "mode": "blocked"}`.

The floor grants read on `/bin /usr/bin /lib /lib64 /etc/pki /etc/ssl /etc/resolv.conf`, readwrite on the `/dev` character devices, read on six `/proc` files, write on `/tmp` and `$TMPDIR`, a handful of individual store files for hosts, nsswitch, services, os-release, locale and terminfo — plus the workdir. Its 48 denies come from the required credential, keychain and shell-history groups, rooted at whatever `$HOME` resolves to. `process.blocked_commands` holds 46 entries, `git` not among them.

**`/nix/store` is not in the floor**, which is why a bare session cannot run anything from the store — the first attempt exited 127. The lever is `"groups": {"include": ["nix_runtime"]}`, which adds exactly four grants, all **read**: `/nix/store`, `/nix/var/nix/profiles`, `/etc/profiles/per-user` and the system-path closure. Reaching for `--allow /nix/store` instead grants read **and write** to the store, which is wrong and should never appear in a description here.

### What leaks into a session as things stand

A plain `nono run -- env` passes **233 variables**. `HOME` is unchanged. `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` and `XDG_BIN_HOME` still name host paths — denied on the filesystem, so a tool honouring them *fails* rather than relocating, which is the worst of both. `XDG_RUNTIME_DIR` is `/run/user/1000`. `NONO_AUTO_MIGRATE=1` is set by the prior-art home-manager module, which is the registry-fetch switch P8 wants off. Nix exports the whole devShell hook body as a variable and nono passes it through verbatim, loose `mkdir -p` fragments and all. `JAVA_HOME` and an `XDG_DATA_DIRS` full of openjdk, postgresql, zellij and nodejs store paths confirm the Kafka drift by observation rather than by reading `flake.nix`. `XDG_CACHE_HOME` and `TMPDIR` were correctly project-rooted, and nono auto-grants `write $TMPDIR`.

Two decisions this leaves to `M3`: whether the cut is an `environment.allow_vars` allowlist or a `deny_vars` denylist — P1 argues allowlist, since a new host variable should arrive excluded — and whether `HOME` itself is set into the project. Setting it would relocate most agents for free, which is also the argument against it: a relocation failure is better seen failing loudly than masked.

### `nono why` reports its verdict in the body, not the exit status

| Query | `.status` / `.reason` | exit |
| --- | --- | --- |
| `--path ~/.ssh/id_ed25519 --op read` | `denied` / `filesystem_deny` | 0 |
| `--allow $PWD --path $PWD/flake.nix --op read` | `allowed` / `granted_path` | 0 |
| `--path /etc/shadow --op read` | `denied` / `path_not_granted` | 0 |
| `--command rm`, no `--profile` | `denied` / **`command_policy_unavailable`** | 0 |

The last row is the trap: a query nono **could not answer** still says `denied`. Every refusal check must therefore assert on `.reason` as well as `.status`, and treat any `*_unavailable` reason as an error rather than as a refusal — otherwise a malformed query passes as a successful refusal with the boundary switched off. `nono profile validate` is the opposite and does carry its verdict in the exit status.

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

**The last sentence of that paragraph used to say an untrusted user "gets a prompt rather than the cache". That is wrong, and `M4b` observed it.** Non-interactively there is no prompt: nix prints `warning: ignoring untrusted flake configuration setting 'extra-substituters'` — once per setting — and carries on without the cache. So a `nixConfig` block is a record and a hint for a trusted user, not a mechanism, and the operative form is passing `--extra-substituters` and `--extra-trusted-public-keys` on the command line. See [M4b](#m4b--the-pinned-toolchain-and-two-preconditions-the-plan-did-not-name).

Two further facts from the same block, for `M4b`:

1. `allow-import-from-derivation = false` — the input asserts its own purity, which **P8** wants and which nothing here needs to relax.
1. It pins its own `nixpkgs` (`b47ad65d…`, unstable). Whether it is given `inputs.nixpkgs.follows` — one revision in the closure, at the risk of breaking a package built against another — or left independent, is `M4b`'s decision and is not settled here.

Upstream `HEAD` moved to `c4c6673c4c1ceb69d845fa665a714e1273d0acac` while `M1` was in flight, and to `5aad5f64e621fc35fed0fddcc2b6e17ab662cf78` before `M4b` began.
Every version in the table above was read at `3589c005…`, so the lock must pin a revision explicitly rather than track the branch, or the numbers recorded here stop describing what is built.
Three observed moves in one feature is the evidence for that, not one.

### Verification gap

Availability was established by evaluation, not by building.
`codex` was built during `M1b` and substituted without compiling; the other four were not built on either platform, and nothing here was built for `aarch64-darwin`, which no check in this repository can reach.

## M1g — claude-code's configuration root

The one relocation question `M1` left open, and it moved from peripheral to load-bearing when `claude-code` became both the reference case and the credential source for the other two agents. `M1d` did this work for `pi`; nothing equivalent was ever done here. `spec.md` only ever claimed relocation "with known fallback cases", on the strength of documentation rather than observation.

A first look at the payload, by `strings` occurrence count, says it relocates through many variables rather than one:

| Variable | Occurrences | Why it matters |
| --- | --- | --- |
| `CLAUDE_CONFIG_DIR` | 51 | the likely primary root |
| `CLAUDE_JOB_DIR` | 38 | |
| `CLAUDE_CODE_TMPDIR` | 28 | |
| `XDG_CONFIG_HOME` | 26 | honoured too, so the XDG redirection may already do part of the work |
| `CLAUDE_PROJECT_DIR` | 26 | |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR` | 13 | where the credential is likely to land, which FR-7 depends on |
| `CLAUDE_CODE_REMOTE_MEMORY_DIR` | 11 | |
| `CLAUDE_CODE_PLUGIN_CACHE_DIR` | 7 | |
| `CLAUDE_CODE_ADDITIONAL_DIR` | 7 | |
| `CLAUDE_SKILL_DIR` | 6 | |
| `CLAUDE_TMPDIR` | 5 | |
| `CLAUDE_CODE_PLUGIN_SEED_DIR` | 5 | |
| `CLAUDE_CODE_DEBUG_LOGS_DIR` | 5 | |

Enough to expect success; nowhere near enough for FR-4 to lean on. A count of strings says a variable is read somewhere, not that it governs what it appears to govern — the `pi` case proved that in the other direction, where a variable the shipped documentation described did not exist in the binary at all.

`M1g` mirrors `M1d` exactly: set the candidates, run the agent, observe whether anything is written beneath the home directory, and — the part `M1d` did not need — establish where the credential comes to rest, since FR-7's arrangement reads it from there. Same evidentiary standard: a control run without the overrides, so the default is fixed and the override is shown to be what moved it.

### How it was observed

Five phases, each a real `claude` invocation of `--version` and then one `-p` turn, against `claude` 2.1.233 and `nono` 0.73.0. Phases 1 and 2 run unconfined under a throwaway home directory, without and then with every candidate set, so the default is fixed by observation before the override is credited with moving it. Phases 3 and 4 repeat the pair inside a real confined session, which is what `M1c`'s correction above made reachable. Phase 5 asks the credential question directly, against the host's own authenticated state.

Each candidate is exported to its **own** leaf directory named after the variable in lower case, so a file that appears attributes to the one variable that could have moved it rather than to a shared root. `CLAUDE_PROJECT_DIR` is set to the working directory and excluded from that scheme deliberately: it tells hooks where the project is, and a write diff cannot speak to a variable that governs no writes. Four `XDG_*` roots were added to the eleven remaining `CLAUDE_*` candidates, making fifteen, because the mechanism's own shipped `claude` package grants `$HOME/.cache/claude` and `$HOME/.local/state/claude/locks` and so implies the agent uses them.

### It relocates, and three of the fifteen carry all of it

| Variable | What was written under it, confined |
| --- | --- |
| `CLAUDE_CONFIG_DIR` | the whole root — `.claude.json`, `backups/.claude.json.backup.<epoch>`, `sessions/`, and the turn's transcript at `projects/<slug>/<uuid>.jsonl` |
| `CLAUDE_CODE_TMPDIR` | `claude-1000/`, the per-uid scratch directory that otherwise lands in `/tmp` |
| `CLAUDE_CODE_REMOTE_MEMORY_DIR` | `projects/<slug>/memory/` |

The other twelve received nothing across every phase: `CLAUDE_JOB_DIR`, `CLAUDE_TMPDIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `CLAUDE_CODE_PLUGIN_CACHE_DIR`, `CLAUDE_CODE_PLUGIN_SEED_DIR`, `CLAUDE_CODE_ADDITIONAL_DIR`, `CLAUDE_SKILL_DIR`, `CLAUDE_CODE_DEBUG_LOGS_DIR` and all four `XDG_*` roots. A one-turn exercise does not reach a plugin install or a background job, so silence here means *not needed for a session to run*, not *dead*. `M8b` sets them anyway, because the cost of setting a variable that governs nothing is zero and the cost of missing one is an escape.

The control fixes the default precisely. With nothing set, claude created `$HOME/.claude/{backups,projects,sessions}`, `$HOME/.claude/projects/<slug>/memory/`, `$HOME/.claude.json` and a dated backup beside it. So the default home layout has exactly the three parts the three variables move, and the mapping is complete rather than merely non-empty.

**`$HOME/.claude.json` is not a fallback.** It is the same file as `$CLAUDE_CONFIG_DIR/.claude.json`, and it moves. On the developing host `~/.claude.json` is a symlink into `~/.claude/`, which is that host's dotfile management and not the agent's behaviour — the throwaway-home control shows claude creating it as a real file.

**Nothing was written beneath the home directory once the three were set.** The phase-2 diff of the throwaway home before and after the run is empty, and the confined phases left the real `~/.claude` and `~/.claude.json` untouched. This is criterion 1, and it is the answer FR-4 needs.

### claude ignores XDG entirely

All four `XDG_*` roots received nothing, which falsifies the inference drawn above from `XDG_CONFIG_HOME`'s 26 `strings` occurrences. The only thing that wrote into the relocated `XDG_CONFIG_HOME` was **the mechanism itself**, laying down `nono/profiles` and `nono/profile-drafts` — a supervisor artefact, from outside the boundary, not the agent's. That the shipped `claude` package grants `$HOME/.cache/claude` says what its author expected, not what the binary does.

This is the third time in this feature that occurrence has failed to predict behaviour, after `pi`'s documented-but-absent override in `M1d` and the substitution premise `M1b` falsified. The four `XDG_*` roots stay out of `set_vars`, consistent with D13 and with plan.md's reasoning that a host-pointing `XDG_*` merely relocates the failure.

### The credential rests inside the configuration root, so relocation alone cannot satisfy FR-7

`claude auth status` emits JSON and is the machine-readable observable this question needed. Against the host's real home, with nothing overridden, it reports `loggedIn: true` with `authMethod: "claude.ai"` and `apiProvider: "firstParty"`, exit 0 — and a live `-p` turn returns its answer. Changing exactly two things, `CLAUDE_CONFIG_DIR` and its plausible companion `CLAUDE_SECURESTORAGE_CONFIG_DIR`, and nothing else, the same command reports `loggedIn: false` with `authMethod: "none"`, exit 1, and the turn prints `Not logged in · Please run /login`.

So the credential lives inside the configuration root and follows it. It rests in `.claude.json` at that root's top level — the file the relocation moves, mode `0600` and 77 kB on the authenticated host — and **not** in the secure store, which stayed empty through every phase. `CLAUDE_SECURESTORAGE_CONFIG_DIR` governs nothing observable here.

That closes criterion 3 with the answer the branch in plan.md called the second one: **FR-7 is not satisfiable by relocation.** Confining each project to its own configuration root logs each project out, so a machine-level credential has to reach the session by some route other than the filesystem — which is the supervisor-side injection [D1](plan.md#d1) and [D14](plan.md#d14) already chose, for independent reasons. The spike confirms the architecture rather than redirecting it. What `M7a` still owes is the key name inside that file, which it needs in order to write a `credential_key`; the outer sandbox denies reading `~/.claude.json` from an agent session, so that one fact is a human's to supply, and it is `M7a`'s question rather than this one's.

**Criterion 4 is therefore answered in the negative: no path survives that forces a leak-registry entry.** Every path the agent writes relocates into the project. The only reason to grant anything outside it would be to let a confined claude read the host credential, which is precisely what D1 rejects. The registry stays empty, as [D2](plan.md#d2) concluded on separate grounds.

### Two constraints on the confinement description, found by tripping over them

Neither is about relocation, and both would have been found later and more expensively.

- **The working directory must be granted read **and** write explicitly.** `--allow-cwd` grants it read-only by default — the flag's own help says "level set by profile, defaults to read-only" — and the first confined override run failed with `EACCES: permission denied, mkdir '…/.agents/claude/claude_code_tmpdir/claude-1000'`. That is the sandbox refusing, not the agent misbehaving, and read-only reach makes every agent useless. The description must set the level, or the entry point must grant `$WORKDIR` read-write itself.
- **`TMPDIR` must resolve inside the working directory.** With `TMPDIR` outside it, claude refuses to start: `Temp directory …/.tmp/claude-1000 is not readable (its mode may have been altered, or a path component denies search). Refusing to use it … Set CLAUDE_CODE_TMPDIR to a directory you control`. The bootstrap's `TMPDIR=$PWD/.tmp` already satisfies this, and now has a reason attached rather than being a convention. Note that claude's own diagnostic names `CLAUDE_CODE_TMPDIR`, corroborating the table above from a second direction.

The confined control is worth stating on its own, because it is FR-21 and FR-16 observed at once: with nothing set and the host home denied by the boundary, `claude --version` still exits 0 and the turn reports `Not logged in` rather than crashing on an unreadable path. Host-global configuration neither reaches the session nor breaks it, and the resulting failure is legibly an authentication failure and not a confinement denial.

### Incidental, and carried into implementation

`claude doctor` reports `Auto-updates: disabled (set by env: DISABLE_AUTOUPDATER)` — inherited from the developing session, so the description must set `DISABLE_AUTOUPDATER` itself rather than depend on it, or P8 holds only on this machine. `claude plugin list` and `claude mcp list` both exit 0 with a definite empty answer, which gives `M7` and `M8b` clean observables. `claude project purge` deletes all state for one project. A `.claude.json.lock` **directory** appears under the configuration root, which is the fallback path spec Risk 12 names and `M8b` owns.

The harness and its full transcript live under `.tmp/m1g/`, which is gitignored; nothing in it is a check, and the checks that make these findings permanent belong to `M4b`, `M7a` and `M8b`.

## M3c — The execution substrate, and how a session is actually run

`M3c` could not state its equality without deciding where the Nix store comes from, and that could not be decided from the manifest alone. So the substrate question was settled by running real sessions. The conclusions are [D15](plan.md#d15); what follows is the observation, and the invocation needed to repeat it.

### Running `nono` from inside this repository, non-interactively

Four things must all hold, and each was found by tripping over it:

```sh
# suppress the update check; M1e found it is a network call on almost any invocation
NONO_NO_UPDATE_CHECK=1
# must EXIST, or nono silently falls back to the host's $HOME/.config (M1e)
XDG_CONFIG_HOME=$PWD/.tmp/<scratch>/config
# must overlap NO grant — see below. Not under the project, not under /tmp
XDG_STATE_HOME=<somewhere outside every granted path>
# must resolve inside the project, or the floor's $TMPDIR grant lands outside it
TMPDIR=$PWD/.tmp
nono run -s --workdir "$PWD" --allow-cwd \
  --no-rollback --no-rollback-prompt --no-audit \
  --profile <path-or-name> -- <cmd>
```

- **`nono run` refuses outright without `--allow-cwd` in non-interactive mode**, even when the description sets `workdir.access = "readwrite"`: `nono: CWD access requires --allow-cwd in non-interactive mode`. `M1g` already found the flag grants read-only unless the description says otherwise; this is the other half — without it there is no session at all. `M4b`'s entry point needs both facts.
- **`--workdir` exists on `run` but not on `profile show`.** So a check that resolves a description reads whatever cwd it was invoked from, which is why `manifest_grants` runs from the repository root.

### nono's state root cannot be moved into the project, and nono cannot nest

nono refuses to start when its own state root overlaps **any** granted path, naming both sides:

```text
nono: Sandbox initialization failed: Refusing to grant '/tmp' (source: group:system_write_linux)
  because it overlaps protected nono state root '/tmp/m3c-state/nono'.
nono: Sandbox initialization failed: Refusing to grant '…/agent-sandbox' (source: user)
  because it overlaps protected nono state root '…/.tmp/m3c/state/nono'.
```

`/tmp` is granted by the floor and the project is granted by us, so the state root has nowhere inside the project to go. That is what makes [D2](plan.md#d2)'s accepted leak unavoidable rather than merely convenient, and it should be stated that way in the handbook at `M10a`.

The same protection means **nono cannot run inside nono**: attempted from within a sandboxed session, it fails with `Failed to write config to /home/…/.local/state/nono/sessions/<id>.json: Permission denied (os error 13)`. Anyone developing this repository from inside a confined agent has to point `XDG_STATE_HOME` outside the outer sandbox's reach to run the integration layer at all — a real constraint on `M9c`.

### A deny cannot carve a hole in a grant. Landlock, not nono

`filesystem.deny: ["/nix/store/*-source", "/nix/store/*-source/**"]` beside `filesystem.read: ["/nix/store"]` **passes `nono profile validate --strict`** and appears verbatim in the manifest's `.filesystem.deny[].path`. The session then does not start:

```text
nono: Sandbox initialization failed: Landlock deny-overlap is not enforceable on Linux.
Refusing to start with conflicting policy.
1082483 deny rule(s) cannot apply under an allowed parent directory.
- deny '/nix/store/01x5…-source' overlaps allowed parent '/nix/store' (source: profile)
```

nono expands the glob by walking the store, finds a million conflicts, and stops. An **exact** path deny fails identically with `1 deny rule(s) cannot apply`. Landlock rules only ever add access to a subtree; nothing subtracts from one. So the only way not to grant a path is not to grant its parent, and there is no pattern-based middle ground to reach for.

Two consequences already carried into the tasks. `nono why` answers from the resolved policy and reported `denied` / `filesystem_deny` for a path Landlock cannot deny at all, so it is not a proxy for enforcement. And because `validate --strict` accepts the overlap, validation cannot be the observer either — `M3d` asserts the disjointness as a set property over the manifest.

### Closure versus whole store, measured by `strace`

Two descriptions, each declaring only `meta`, `workdir.access = "readwrite"` and `filesystem.read`, run over a probe under `strace -f -qq -e trace=openat`:

| | `read /nix/store` | `filesystem.read` = 62-path closure of bash, coreutils, nodejs |
| --- | --- | --- |
| store paths opened | **55** | 113, of which 62 are nono opening each grant to build its rule |
| `EACCES` / `EPERM` | 3: `/home/pallon`, two cgroup files | those 3, plus the deliberate `ls /nix/store`, plus `…-glibc-locales-2.42-67/lib/locale/locale-archive` and `/run/current-system/sw/lib/locale/locale-archive` |
| probe result | bash, coreutils and `node` all run; `$HOME` denied | the same, and store enumeration additionally denied |

So the closure **works**, and is a tight upper bound — 62 granted against 55 needed. Its failure mode is a path wanted at runtime but absent from the static closure, and both instances were the locale archive, one of them outside the store. That is why `M4c` makes `LOCALE_ARCHIVE` a criterion rather than a discovery.

Scale on the developing machine: 61,799 store paths in total; 211 of them `-source` trees belonging to other projects; 128 paths in the closure of a realistic session set (bash, coreutils, nodejs, git, jq, ripgrep). The 211 are the argument for `M4c` — read access to another project's source is the leak this feature exists to prevent.

**`strace` is the observer because nono is not.** On the session that died of the denied locale archive, `nono run --diagnostics-json` reported `"denials": []`, `"ipc_denials": []` and `"violations": []`, offering only two `severity: info` diagnostics — `command_failed_likely_sandbox`, whose remediation is `run_discovery`, and `command_failed_application`. There is no `--discover`, `--learn`, `--permissive` or `--trace` flag on `nono run` and no `discover` subcommand, so that remediation names something that does not exist. A check trusting nono's own denial reporting would pass over exactly the failure it was written to catch.

### Method notes, each one a bug that cost time

- `nix build --no-link --print-out-paths nixpkgs#bash` prints **two** paths, `-man` first, silently corrupting a variable that expects one. Use `nixpkgs#bash^out`.
- `nono why --profile <path>` hung past 120 s once, so wrap every nono invocation in `timeout`.
- nono grants **stdout's file** `readwrite`. Redirecting `profile show` into a file puts that file in the manifest being compared; command substitution does not.
- The `/proc/<pid>` and `/proc/<pid>/fd` grants carry the resolving process's own pid, so two invocations of the same description differ and the pid must be normalised away.
- `.filesystem.deny[]` elements are objects, not strings.

The scratch harness lived under `.tmp/m3c/`, which is gitignored, and has been removed; every finding above is either in `plan.md` as a decision or in `tasks.md` as a criterion.

## M4b — The pinned toolchain, and two preconditions the plan did not name

Done before `M4b` rather than during it, because adding the flake input changes the substrate under every check `M1`–`M4a` established, and because two of these findings would otherwise have surfaced as inexplicable failures.

Pinned at `github:numtide/llm-agents.nix/5aad5f64e621fc35fed0fddcc2b6e17ab662cf78`, `lastModified` 1787216589. Root inputs are `bun2nix`, `flake-parts`, `nixpkgs`, `systems`, `treefmt-nix` — five, where `M1f` recorded only `nixpkgs`. The `inputs.nixpkgs.follows` decision is against that closure, not against a single input.

### Availability at the revision that will be locked

Evaluated as `packages.<system>.<attr>`, both systems, at `5aad5f64…`. `M1f`'s table was read at `3589c005…` and its numbers have all moved.

| Attribute | Version | `license.free` | `license.fullName` |
| --- | --- | --- | --- |
| `claude-code` | 2.1.237 | `true` | **`Unfree`** |
| `codex` | 0.148.0 | `true` | Apache License 2.0 |
| `nono` | **0.74.0** | `true` | Apache License 2.0 |
| `opencode` | 1.18.18 | `true` | MIT License |
| `pi` | 0.84.2 | `true` | MIT License |

Identical on `x86_64-linux` and `aarch64-darwin`, as `M1f` found.

**`M1f`'s `allowUnfree` reasoning is dead, and implementing `M4b` is what killed it.** `claude-code` carries `fullName = "Unfree"` beside `free = true`, so the unfree gate never fires: `nix build` of it succeeds in pure mode with `allowUnfree` set nowhere. There is no permission to scope, and no way to scope one either — these packages are instantiated by the input against *its* nixpkgs, so setting `config.allowUnfree` would mean importing our own nixpkgs with the input's `shared-nixpkgs` overlay and taking `pkgs.llm-agents.claude-code` instead. That is a different derivation from the one `cache.numtide.com` holds, so the price of the gesture is compiling everything from source. It is the `follows` argument a second time: the honest environment is the one that takes the binary the publisher published.

### Precondition 1 — `XDG_DATA_HOME` is set nowhere, and nix needs it

Any `nix eval` or `nix build` against a flake that declares `nixConfig` fails outright:

```text
error: opening file "/home/pallon/.local/share/nix/trusted-settings.json": Permission denied
```

nix reads that file to decide whether the flake's `nixConfig` may be honoured. **`--no-accept-flake-config` does not avoid the read** — the decision is recorded there either way. Pointing `XDG_DATA_HOME` inside the project fixes it, and nothing is written: the file was never created, so nix only reads it and its absence is fine.

`grep -c XDG_DATA_HOME flake.nix .envrc` returns `0` and `0`. **This is a live P1 gap in the repository as it stands**, not a property of the input: the environment claims to keep every tool inside the project, and nix's own data root currently resolves to the host `$HOME/.local/share`. Under the development sandbox that fails closed rather than leaking, which is the arrangement AGENTS.md §3 calls the feature — but it means the input cannot be added until the variable is set. Placing the export above `use flake` in `.envrc` brings it under `check_bootstrap_mirror` automatically, because that check derives its variable list from the exports in that region rather than from a list.

### Precondition 2 — `nixConfig` is ignored, so the cache must be passed

The substituter and key `M1f` recorded are correct and reachable from here. Building `nono` from the input with them passed explicitly copied `nono-0.74.0` from `https://cache.numtide.com`, 45.3 MiB unpacked, nothing compiled.

In the same run nix printed, once per setting:

```text
warning: ignoring untrusted flake configuration setting 'extra-substituters'.
Pass '--accept-flake-config' to trust it
```

and the same for `extra-trusted-public-keys` and `allow-import-from-derivation`. So for a non-trusted user a `nixConfig` block does nothing at all — no prompt, no cache, just a warning. `M1f`'s claim that an untrusted user "gets a prompt" is corrected in place above. Declaring the substituter in `flake.nix` stays worth doing as the record of where the binaries come from, but what actually reaches the cache is `--extra-substituters` and `--extra-trusted-public-keys` on the command line, and the handbook must say that rather than implying the declaration suffices.

### The substrate change is safe, and this is the experiment that shows it

Every check from `M1` to `M4a` ran against the host `nono 0.73.0`, resolving from `/etc/profiles/per-user/pallon/bin/nono` — **a user profile, which AGENTS.md §3 says is not available at all**. `M4b` replaces it with the pinned `0.74.0`, changing the binary under every component and integration assertion in the middle of the feature, and every finding in `M1b`, `M1c`, `M1e` and `M1g` was observed against the old one.

Run with the pinned binary first on `PATH`, unchanged otherwise:

```text
== component
PASS  check_confinement_validates
PASS  check_sc1
PASS  check_component_merge
== integration
PASS  check_r6
```

All four pass against `0.74.0` with no edit to any check. That is the dividend of AGENTS.md §4's rule about deriving expected values from the system under test: the floor is computed by stripping the description under test rather than listed, the `set_vars` expectation is applied from the agent table rather than restated, and the store grant comes from the registry rather than a literal — so a version bump moves the baseline instead of breaking the suite.

The consequence for `M4b` is a criterion, not a note: the checks must invoke the **pinned** nono, or the suite keeps testing a binary a stranger does not have while reporting green.

### What a session grants is readable, and it is not the banner

`check_j1_1` needs the *set* of paths a real session reached. Three candidates were compared, and only the third is usable.

| Candidate | Why not |
| --- | --- |
| The startup banner on stderr | Collapses the floor to `+ 34 system/group paths (-v to show)`. A summary for a human, not a set. |
| `nono profile show --format manifest` | Describes the resolution, not the session. It reported the project `readwrite` for a run that reached only `/nix/store` — see below. |
| `$XDG_STATE_HOME/nono/audit/<session>/session.json` | `.tracked_paths`, written per session beside `.command`, `.exit_code` and `.executable_identity`. |

`tracked_paths` was probed against every way a path can be widened, each arm with a fresh state root:

| Session | `tracked_paths` |
| --- | --- |
| `--workdir $PWD`, no `--allow-cwd` | `["/nix/store"]` |
| `--workdir $PWD --allow-cwd` | `[project, "/nix/store"]` |
| `.filesystem.read += ["/etc/nixos"]` | `[project, "/etc/nixos", "/nix/store"]` |
| `.filesystem.allow += ["/etc/nixos"]` | `[project, "/etc/nixos", "/nix/store"]` |
| `--read /etc/nixos` on the stock description | `[project, "/etc/nixos", "/nix/store"]` |

So it responds to a widening from the description, from the CLI and from the working-directory consent alike, and it excludes the floor. It is `granted ∖ floor` — exactly the left-hand side of the property `plan.md` states for `SC-1`, now observable on a live session rather than only on a resolution. It is unordered, so it has to be sorted before comparison.

### `--allow-cwd` is the consent, `workdir.access` is only the level

`nono run --help`: `--allow-cwd` is "Allow CWD access without prompting (level set by profile, defaults to read-only)". Without it a non-interactive session prints `Skipping CWD prompt (non-interactive). Use --allow-cwd to include working directory.` and **the project is not granted at all** — a confined `: > .tmp/probe` leaves no file. The description's `workdir.access = "readwrite"` decides what the consent is worth, not whether it was given.

The resolved manifest reports `readwrite <project>` either way, so **the manifest cannot detect this**. That is the concrete reason `check_j1_1` reads a session rather than a resolution, and it corrects the reason `M4a` recorded for the pre-flight passing no `--allow-cwd` — the pre-flight is right to omit it because it writes nothing inside the project, not because `workdir.access` already covers it.

### The RED arrived by the wrong route, and the route is the finding

`M4b`'s criterion predicted `claude: command not found`. Instead the first run of `check_j1_1` exited **0** and failed with `expected exactly one confined claude session, found 0`: this host carries `claude` *and* `nono` in `/etc/profiles/per-user/pallon/bin`, and `nix develop` keeps the host `PATH`, so the unconfined host binary answered to the name.

M4b's own planted violation therefore occurred unbidden, before the code that was supposed to prevent it existed. Two consequences, both load-bearing rather than incidental:

- `D3`'s shadowing is not a convenience. On a machine that has the agent installed, the confined wrapper must come first on `PATH` or the environment silently runs the host's copy.
- The same is true of `nono`, which is why the suite resolves it from the flake. Sabotaging a `nono` on `PATH` (`exit 3`) leaves all five component and integration checks green *with* the pinning, and fails three component checks plus `check_r6` *without* it.

### Method notes

- `mktemp -d TEMPLATE` ignores `TMPDIR` and creates a **relative** directory in the current directory; only `mktemp -d -p DIR TEMPLATE` places it. The relative path then reached nono as `HOME`, which refused it: `Environment variable 'HOME' validation failed: must be an absolute path`.
- A flake in a dirty tree cannot see an untracked file: `error: Path 'lib/confined-agent.nix' … is not tracked by Git`. `git add -N` is enough.
- `$XDG_STATE_HOME` must stay outside the project, or nono refuses to start: `Refusing to grant '<project>' … because it overlaps protected nono state root`. The integration layer's four conditions, recorded in `M3c`, all still hold under `0.74.0`.
- The devShell has to carry `shellcheck` and `shfmt` itself. `AGENTS.md` §4 names both, and until now they resolved only from a user profile — the same class of mistake as the host `nono`.

## M4c

Measured on `x86_64-linux`, NixOS host, nono `0.74.0`, against the shipped `.#confinement-claude-code` description and the shipped `.#claude` wrapper. Every arm ran under `HOME` and `XDG_STATE_HOME` outside the project, `TMPDIR` inside it, and a pre-touched audit ledger — the four conditions `M3c` recorded.

### The substrate can be narrowed by three orders of magnitude, and the agent does not notice

| root | paths in closure |
| --- | --- |
| `claude-code-2.1.237` | 17 |
| `nono-0.74.0` | 7 |
| the `.#claude` wrapper | 25 |
| the 35 store directories on the devShell's own `PATH` | 111 |
| the whole store, for comparison | 67,051, of which 251 are `-source` |

Two arms of `strace -f -e trace=openat` over `claude --version`, differing only in `filesystem.read`:

| arm | rc | child output | `openat` lines | distinct store paths opened |
| --- | --- | --- | --- | --- |
| `["/nix/store"]` | 0 | `2.1.237 (Claude Code)` | 152 | 13 |
| the agent's 17 paths | 0 | `2.1.237 (Claude Code)` | 196 | 25 |

The closure arm opens *more*, not less: nono opens each grant to build its Landlock rule, the same inflation `M3c` saw. Function is unchanged, so the narrowing costs the session nothing.

The agent's closure is `glibc`, `openssl`, `readline`, `socat`, `bash`, `pcre2`, `libcap`, `libunistring`, `libidn2`, `bubblewrap`, `wrap-buddy`, `libselinux`, `ncurses`, three gcc runtimes and the agent itself. There is no `node` in it — the publisher's build is self-contained — and no `coreutils`.

### Criterion 3 cannot be met as written, because the floor itself denies

Both arms produce exactly the same **11** `EACCES`, none of them in the store: `/sys/devices/system/cpu/online`, nine `cpu.max`/`memory.high`/`memory.max` files under three `/sys/fs/cgroup/user.slice` levels, and `/sys/kernel/debug/tracing/trace_marker`. A session that reaches the whole store is already denied all eleven, so "no `EACCES` outside what a probe asks for" is false of the control as much as of the treatment.

The property has to be **differential**: run the shipped description and a control whose `filesystem.read` is `["/nix/store"]`, and assert the two denial sets are *equal*. That is derived from the system under test rather than pinning `/sys` literals a kernel or a cgroup layout can move, it states the claim exactly — narrowing the substrate costs the session nothing — and criterion 7's plant, dropping a needed path, breaks it by adding a denial the control does not have.

### The locale archive, and why setting `LOCALE_ARCHIVE` is not enough on its own

Under the closure grant the *only* non-`/sys` denial is `openat("/run/current-system/sw/lib/locale/locale-archive") = -1 EACCES`. The whole-store arm never sees it because that path is a symlink into `/nix/store/…-glibc-locales-…`, which a whole-store grant covers.

Setting `LOCALE_ARCHIVE=/nonexistent/bogus-archive` in the *parent* changed nothing: the child still opened the same path. So the variable never reaches the child — `allow_vars` is default-deny under [D6](plan.md#d6) — and the path is nixpkgs glibc's compiled-in default rather than something the environment chose. glibc then probes `$glibc/lib/locale/en_US.UTF-8/LC_*` and `/usr/lib/locale/locale-archive`, all `ENOENT` and harmless, and successfully reads `…-locale.conf`, a store path nono's **floor** grants individually. The floor already carries single store paths beside our directory grants, which is fine: Landlock is allow-only, so overlapping allows compose.

`glibcLocales` is 222 MiB; `glibcLocalesUtf8` is **2 MiB** at the same version, closure of one. Granting the UTF-8 one *and* setting `set_vars.LOCALE_ARCHIVE` to the archive inside it validates (`Result: valid`), opens the archive successfully, keeps `claude --version` at rc 0 and leaves **zero** non-`/sys` denials. Setting the variable without granting the path it names only moves the `EACCES`, so the criterion needs both halves. Both are glibc-specific and must be conditional on `stdenv.hostPlatform.isLinux`; `lib/confinement.nix` has no platform conditional today.

### `PATH` is inherited whole and cannot be narrowed

This is the finding that decides what the substrate has to be. A confined `bash -c` printed a `PATH` carrying the devShell's entries *and* the entire host user profile — `/etc/profiles/per-user/…`, `~/.nix-profile/bin`, `/run/current-system/sw/bin`, `~/.local/bin`, flatpak and devbox exports — even though `PATH` is not in `allow_vars`. nono then prepends its own `nono-browser-XXXX` under `$TMPDIR`.

- `set_vars.PATH` is refused: `Invalid set_vars key 'PATH': PATH is reserved; use allow_vars/deny_vars to control it`.
- `deny_vars: ["PATH"]` changes nothing — the inherited value comes through byte for byte.

So nono offers no mechanism to narrow the session's `PATH`, and the confinement cannot assume the agent will only execute its own closure. Under the 17-path grant, `ls`, `env`, `sort` and `cut` all resolve to `coreutils` and die with `Permission denied`: **the agent's own closure is not a viable substrate**, because the agent's Bash tool could not run `ls`.

### The root set has to be the paths that are actually on `PATH`

A 109-grant profile assembled from *package attributes* (`coreutils`, `bash-interactive`, `git`, `ripgrep`, `jq`, `findutils`, `gnugrep`, `gnused`, plus the agent and the locales) started in 0.33 s — grant count is not a constraint at this scale — but `jq` failed inside it. `PATH` names `…-jq-1.8.2-bin/bin/jq`, the `bin` output, while `nixpkgs#jq^out` yields `…-jq-1.8.2`. Different path, not granted, `EACCES`.

Deriving the root set from the devShell's `PATH` instead — 35 store roots, 111 paths, plus the locales — fixes it. Every tool the devShell provides works:

| tool | resolves to | result |
| --- | --- | --- |
| `ls`, `env` | `coreutils-9.11` | works |
| `jq` | `jq-1.8.2-bin` | works |
| `rg`, `sed`, `grep`, `find`, `bash` | the devShell's own | works |
| `git`, `node` | `/etc/profiles/per-user/…` | **denied** |

`git` and `node` fail because the devShell does not provide them: they resolve through the host user profile into store paths nothing granted. In the package-attribute arm `git` *worked*, by the accident that the hand-listed `git` closure happened to contain the very path the host symlink pointed at. That accident is exactly what `AGENTS.md` §3 warns about, and a closure-scoped substrate turns it into a hard failure — which is the outcome we want, but it means **every tool the agent needs must be in the list**, and today `git` is not.

The design this points to: one nix list, used twice — as the devShell's `packages` and as `closureInfo`'s `rootPaths`. Then the grants and the `PATH` are the same expression, criterion 1's "cannot drift apart" holds by construction rather than by discipline, and the `jq^bin` class of mistake cannot recur because nothing restates an output.

### A confined agent cannot start a second confined agent

`claude` inside a confined session exits 1 with `XDG_CONFIG_HOME: not set; enter the environment … rather than running this from the store`. `XDG_CONFIG_HOME` is not in `allow_vars`, so the wrapper's own guard fires. That is the designed refusal from `M4b`, not a defect, and nesting is not a use case — but it does mean the wrapper is unusable as a probe from inside a session.

### Method notes

- `nixpkgs#strace` prints the `-man` path first; `nixpkgs#strace^out` is required, or `env` reports `No such file or directory` with rc 127. The same trap as `M3c`'s `nixpkgs#bash`.
- `strace` is Linux-only. `nix eval nixpkgs#legacyPackages.aarch64-darwin.strace.drvPath` refuses: `not available on the requested hostPlatform`. An unconditional `strace` in the devShell would stop `devShells.aarch64-darwin.default` evaluating, which `M4b` verified as working and the handbook now claims, so it must be `lib.optionals stdenv.hostPlatform.isLinux`.
- The store figures move. `M3c` measured 61,799 paths and 211 `-source` trees; this session measures 67,051 and 251. Nothing should pin either number.

### What the narrowing actually cost, measured after it landed

The preconditions above answered "can the substrate be narrowed".
These answer "did narrowing it change what the session may reach", and they are the observations `M4c`'s criteria were finally checked against.

| arm | `.filesystem.read` | an out-of-closure `-source` tree |
| --- | --- | --- |
| the closure and `builtins.storeDir` together | 129 paths | `OPENDIR_OK` |
| the closure alone | 128 paths | `OPENDIR_DENIED` |

Landlock rules are allow-only, so an allow on an ancestor subsumes every path beneath it.
Granting the store *beside* the enumerated closure therefore grants the whole store, and the enumeration is decorative.
This is why the registry's entry had to be **deleted** rather than kept as an upper bound, which `M4c`'s criterion 6 permitted and this measurement ruled out.

Two method traps cost a wrong conclusion on the way:

- **`ls -d <path>` is not a probe.**
  It only stats, and Landlock does not mediate `stat` or `lstat`.
  Both arms reported the path present.
  A probe must *open*: list a directory's contents, or read a file inside it.
- **nono's floor does not grant the store.**
  `nono profile show <floor> --format manifest` grants seven specific store *files* — `share/terminfo`, `hosts`, `etc-nsswitch.conf`, `etc/services`, `etc-os-release`, `locale.conf`, `gai.conf` — and never `/nix/store` itself.
  Had it granted the store, the whole task would have been pointless, so this had to be ruled out before anything else.

`strace` ptraces normally inside a confined session; nothing in the sandbox blocks it.
Both arms of the final differential exit 0 printing `2.1.237 (Claude Code)`, record 59 `openat` lines each, and deny the same eleven `/sys` paths.
So the narrowed substrate takes nothing away, and the assertion has to be an equality between the two arms rather than a count or a path list.

`coreutils-9.11` **is** in the closure and granted, correcting the note above that the agent's own closure carries no `coreutils`: that was true of the 17-path agent closure, not of the 128-path session substrate.

## M5a — A key outside the project is unreadable

Measured on `x86_64-linux`, nono `0.74.0`, against the shipped `.#confinement-claude-code`, with `bash` resolved from the substrate itself.
Every arm ran with `HOME` and `XDG_STATE_HOME` outside the project, `TMPDIR` inside it, and a pre-touched audit ledger.

### The fake `$HOME` must be outside the project, and the reason generalises

A `HOME` inside the checkout makes nono refuse to start:

```text
Sandbox initialization failed: Landlock deny-overlap is not enforceable on Linux.
Refusing to start with conflicting policy.
48 deny rule(s) cannot apply under an allowed parent directory.
```

The conflicts name `$HOME/.1password`, `$HOME/.aws`, `$HOME/.azure`, `$HOME/.bash_history`, … each `overlaps allowed parent '<project>' (source: user)`.
The resolved description carries **48 `$HOME`-relative deny rules**, resolved from the ambient `HOME`, so any `HOME` under the granted project turns all of them into a refusal.
A check that wants a fake home cannot put it in the project's own scratch directory; `mktemp -d -p "$XDG_RUNTIME_DIR"` is the route, and on this machine `XDG_RUNTIME_DIR` is itself under `$HOME`.

### R1 already holds as shipped, and both halves are observable in one session

One session, `bash -c` with three probes:

| probe | result |
| --- | --- |
| `$(<$HOME/.ssh/id_ed25519)` | `READ_DENY`, bash reporting `Permission denied` |
| `$(<$PROJECT/.tmp/inside.txt)` | `READ_OK :: PROJECT-FILE-CONTENT` |
| `command -v cat` | `/nix/store/…-coreutils-9.11/bin/cat` |

So `check_r1` needs no instrument beyond the shell: the refusal, the absence of key material in the output, and `D9`'s positive control all come from one invocation.

### A deny the description carries does not outrank a grant of the same path

Two arms differing only by one added entry in `filesystem.read`:

| grant | `$HOME/.ssh/id_ed25519` | `$HOME/plain/secret.txt` |
| --- | --- | --- |
| `$HOME/.ssh` | `READ_OK :: PLANTED-KEY-MATERIAL` | `READ_DENY` |
| `$HOME/plain` | `READ_DENY` | `READ_OK :: PLAIN-HOST-FILE` |

In the granted arm the resolved manifest **still lists** `$HOME/.ssh` under `.filesystem.deny`, and lists it under `.filesystem.grants` as `read` at the same time.
Both arms carry 48 denies.
The deny entry has no `source` field, so the manifest cannot say where it came from.

`nono profile groups --json` will not attribute it: each group's `deny` there is a summary object (`{"access": N, "commands": N, "unlink": bool}`), never a path list.
The **per-group detail** does, and it is the instrument `check_component_merge` already uses — `nono profile groups <name>` prints `… -> /path` lines.
Five groups are `required: true`, and they apply whether or not a description includes them, which is why a description with `groups = [ ]` still resolves to 48 denies:

| required group | denied paths | denies `$HOME/.ssh` |
| --- | --- | --- |
| `deny_browser_data_linux` | 7 | no |
| `deny_credentials` | 20 | **yes**, and `$HOME/.gnupg` |
| `deny_keychains_linux` | 4 | no |
| `deny_shell_configs` | 13 | no |
| `deny_shell_history` | 4 | no |

So the deny is `deny_credentials`', which is the strongest form the finding could take: the one group whose whole purpose is to keep credentials out, marked `required` so it cannot be omitted, is overridden by a description that names the exact path.

The model this settles:

- A deny is not a subtractive kernel rule.
  Landlock is allow-only, so a deny is the **absence of a grant**, and the deny list is a record of what nono declines to grant on its own.
- A grant **equal to** a denied path: nono starts, the grant takes effect, and the deny remains in the manifest as decoration.
- A grant on an **ancestor** of denied paths: nono refuses to start, which is `D15`'s refusal rather than a quiet narrowing.

Two consequences for the feature.
`plan.md`'s [D4](plan.md#d4) claimed a group's deny "outranks any grant, which is why `deny_credentials` and the keychain groups are `required: true` and cannot be traded away" — they can be, by naming the exact path, so that sentence is corrected there.
And the required deny groups are **not** a backstop behind the leak registry: `FR-3`'s strictness is the only thing between a session and `~/.ssh`.
That is why `R1` has to be asserted from inside a live session rather than from a resolved description, and why `check_component_merge`'s claim 2 — that a deny survives into the merge — must record that surviving in the manifest is compatible with the path being readable.

### `$HOME` expands at the boundary, and the registry hands it over unexpanded

Measured while planting `M5a`'s violation, because the plant depended on it and nothing had tested it: `lib/confinement.nix` copies `entry.path` into `filesystem.read` verbatim, and only `$WORKDIR` was known to be substituted.
With `{ path = "$HOME/.ssh"; mode = "read"; }` in the registry, the built description carries the literal string `$HOME/.ssh`, and the session reads the key out — so nono expands `$HOME` against the ambient environment, the same way it resolves the 48 `$HOME`-relative denies.

The plant also failed `check_j1_1`, for a reason unrelated to `R1`:

```text
the session reaches more or less than the project, its substrate and the leak registry:
@@ -1,4 +1,3 @@
-$HOME/.ssh
 /home/pallon/projects/hivemind/agent-sandbox
 /nix/store/03ll5c4q8j8dqsx4q822g7h9js51gfyp-nixfmt-1.4.0
```

Two separate things are visible there.
The expected side carries the **unexpanded** string, because that check builds it from `nix eval .#leakRegistry`, while `tracked_paths` is written by nono after expansion — so the two can never match for an entry naming a variable.
And the session side gained **nothing at all**: `check_j1_1`'s fake home has no `.ssh` in it, so the grant named a path that did not exist and no tracked path came of it.
A grant on a missing path is therefore silent rather than an error, which is worth knowing on its own: it is the failure mode a typo in a registry entry produces.

The registry is empty, so nothing fails today, but **the first entry naming any variable will fail `check_j1_1` spuriously**.
Fixing it means choosing where expansion happens — in `lib/confinement.nix` when the description is built, or in the check when the comparison is made — which is a change to the description's contract and belongs with whichever task first needs an entry.

### The pre-flight's bare-name exec is `PATH`-dependent

`lib/preflight.sh` runs `nono run … -- true`.
On this host `true` resolves to `/run/current-system/sw/bin/true`, which the session is not granted, so nono exits `127`:

```text
The executable 'true' was resolved at: /run/current-system/sw/bin/true
but its directory is not readable inside the sandbox
```

The pre-flight reads that as assertion 1 failing and refuses with `77`, naming Landlock — fail-closed, but attributing the refusal to the wrong cause.
Inside the devShell the store's `coreutils` comes first on `PATH` and the same code passes, which is why `check_r6` fails when the suite is run directly and passes under `nix develop -c`.
The checks resolve every binary they run through `substrate_member` precisely to avoid this; the shipped pre-flight does not.

### Method notes

- `nono profile show --format manifest` writes its `WARN` lines to the same stream as the JSON.
  `sed -n '/^{/,$p'` before `jq`, or `jq` fails with `Invalid numeric literal at line 1, column 2`.
- With `HOME` inside the project, nono also warns that it is *skipping* the `system_write_linux` grant on `<project>/.tmp` for the same overlap reason, before going on to refuse.

## M5b — A write outside the project is refused

Same instrument as [M5a](#m5a--a-key-outside-the-project-is-unreadable): the shipped `.#confinement-claude-code`, a `bash` from the substrate, a fake `$HOME` under `$XDG_RUNTIME_DIR`, `TMPDIR` inside the project and the audit ledger pre-touched.
The probe writes to a target outside the project, reports its own status, then writes inside the workdir and reports that, so the second write is attempted whatever the first one did.

### A home directory cannot be granted at all, for a reason that arrives before the deny rules

`filesystem.allow += ["$HOME"]` does not widen anything and does not narrow anything.
nono refuses to start:

```text
nono: Sandbox initialization failed: Refusing to grant
'/…/agent-sandbox-r2.EYKqds/home' (source: Profile) because it overlaps
protected nono state root '/…/agent-sandbox-r2.EYKqds/home/.nono'.
```

The state root named is `$HOME/.nono`, which **does not exist** and is not the state root this session uses — `XDG_STATE_HOME` points the real one elsewhere, and it is honoured.
nono is protecting the *candidate* location it would have used, so the refusal does not depend on the directory being there or on the session using it.

That is a second reason a grant cannot name a home directory, and it fires earlier than the deny-overlap refusal M5a measured: with `$HOME` granted the 48 `$HOME`-relative deny rules also overlap it, but the message never mentions them.
Either way the consequence for a check is the same — a plant must name an exact path, and one that names `$HOME` fails every check in the layer at startup rather than testing anything.

### `$HOME` expands in `filesystem.allow`, and an exact grant is honoured

`filesystem.allow += ["$HOME/probe"]`, written unexpanded exactly as the registry would produce it, starts and lets the write through; the file is on the host afterwards.
The same path under the shipped description is refused with `Permission denied` and leaves nothing.
So the expansion M5a found in `filesystem.read` applies to `allow` too, and the difference between the two arms is the grant rather than the path.

### nono's own denial report is not evidence

For a write it had just refused, nono's summary said:

```text
No path denials were observed during this session.
The failure may be unrelated to sandbox restrictions.
```

A `Landlock`-refused `open` for writing does not reach whatever nono counts as a path denial.
A check that read nono's report would conclude the refusal was unrelated to confinement, so `check_r2` asserts on the shell's `Permission denied` and on the file's absence on the host instead.

## M5c — No host secret crosses

Measured on x86_64-linux with nono 0.74.0, against the shipped `.#confinement-claude-code`, with `HOME` and `XDG_STATE_HOME` in a `mktemp -d -p "$XDG_RUNTIME_DIR"` and `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `TERM` and `LC_TESTVAR` canaries in the host environment.

### The substrate's bash cannot list its own environment

The first probe used `for name in $(compgen -e)`, and every arm printed `compgen: command not found`.
The substrate's `bash-5.3p15` is nixpkgs' non-interactive build, without programmable completion, so `compgen` is not there to be called.
`export -p` is available but quotes what it prints — `declare -x TERM="…"` — so an assertion looking for `NAME=value` does not match it.

The probe is therefore `env -0` out of the same substrate, run as the session command with no script between it and the scenario.
`-0` matters: the host carries the devShell's entire `shellHook` body as a variable of its own, newlines included, and a newline-separated listing splits it into entries that parse as further variables.
It is captured to a file, because bash drops NUL bytes from `$(…)` and would run the whole environment into one unsplittable line.

### `allow_vars` is what does the work, and its absence means pass-everything

| Arm | Variables crossing | `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` canaries |
| --- | --- | --- |
| shipped description | 20 | absent |
| `del(.environment.allow_vars)` | 221 | present |
| `allow_vars += ["ANTHROPIC_API_KEY"]` | 21 | present |

The default without the key is pass-everything rather than deny-everything, which is what makes removing it a plant that bites.
The 221 corroborates the 233 that [`M1e`](#what-leaks-into-a-session-as-things-stand) measured from a plain child process, on a host whose environment has since moved; what has not changed is that a session with no `allow_vars` sees the lot.

What the 221-variable arm carried, beyond the 20 below: the `shellHook` body, `DIRENV_DIFF`, `DIRENV_WATCHES`, `XDG_CONFIG_HOME`, `STARSHIP_CONFIG`, `SSH_AUTH_SOCK=/run/user/1000/gnupg/S.gpg-agent.ssh`, the whole nix-shell build environment, and `OPENCODE=1`.

### The 20 that cross, and what sanctions each

- **Ten through `allow_vars`** — `HOME`, `USER`, `LOGNAME`, `TERM`, `LANG`, `PWD`, `SHELL`, `COLORTERM`, and `LC_ALL` and `LC_TESTVAR` through the `LC_*` pattern, **so the glob works**.
  `TZ` was unset on the host, so an allowed name with no host value does not appear.
- **Seven through `set_vars`** — `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_TMPDIR`, `CLAUDE_CODE_REMOTE_MEMORY_DIR`, `DISABLE_AUTOUPDATER`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `LOCALE_ARCHIVE`.
- **Three from nono, which nothing in this repository asked for** — `PATH`, `BROWSER` (pointing at `$TMPDIR/nono-browser-XXXXXX/nono-browser`) and `NONO_CAP_FILE` (pointing at `$TMPDIR/.nono-<hex>.json`).

`HOME` crosses with the host's value, deliberately, per [D13](plan.md#d13).
The `PATH` nono writes is rewritten but still ends with the whole host `PATH`, `/run/current-system/sw/bin` included — the same fact behind the pre-flight's bare-name exec, recorded in the coverage gap.

### Two things that make a variable check fail for the wrong reason

`jq '.environment.allow_vars += […]'` against a description that has no `allow_vars` yields a one-element list, which is *stricter* than the shipped description rather than looser.
A positive-control arm built that way stops seeing `TERM` and fails its own control, so a check must not read a passing granted arm as evidence that the shipped arm's list is the reason for anything.

Removing `allow_vars` also fails `check_substrate_denials`: the host's own `LOCALE_ARCHIVE` then crosses, naming a `glibc-locales` store path that is not in the narrowed substrate, and the narrow arm denies something the whole-store arm does not.
The environment is part of what makes the substrate sufficient.

## M5d — An agent cannot widen its own confinement

Measured on x86_64-linux with nono 0.74.0, from inside the devShell, against the shipped `.#confinement-claude-code` and `.#claude`. The fake `$HOME` was a `mktemp -d -p "$XDG_RUNTIME_DIR"` holding `reach/target.txt` with a canary, and the session wrote the widened registry over `lib/leak-registry.nix` using shell builtins only.

### A session can edit the source of its own confinement, and nothing happens until a rebuild

| Step | Observed |
| --- | --- |
| Session 1: read the target, copy a widened `lib/leak-registry.nix` over the source, read it again | `BEFORE :: 1 ::` (empty, `Permission denied`), `EDIT :: 0`, `AFTER :: 1 ::` |
| Did the edit land? | Yes — the file differs from the backup and carries the planted path |
| Session 2, same description, after session 1 exited | `READ :: 1 ::` |
| `nix build .#confinement-claude-code` from the edited tree | a new store path, and `warning: Git tree is dirty` on stderr |
| `nix build .#claude` from the edited tree | a new wrapper; the **old** wrapper store path still names the **old** description |
| Session 3, rebuilt description | `READ :: 0 :: <canary>`, and the capability banner lists the granted directory as `r` |
| Restore the source, rebuild | the original description store path returns, `git diff --stat` empty |

So FR-9 holds for a mechanical reason rather than a defensive one: the description is a store path, the entry point is built naming it, and a store path cannot be rewritten. The edit is real and it does widen — after a human re-enters the environment, which is exactly the clause R4 ends on.

The grant has to name an exact directory inside the fake `$HOME` rather than `$HOME` itself, as the scenario's wording suggests. Granting `$HOME` covers a parent of nono's deny rules and it refuses to start, measured under [`M5b`](#m5b--a-write-outside-the-project-is-refused); every session would then fail to start and the refusals would prove nothing.

### A line-level search for `$PWD` cannot express "the description is pinned"

The first draft of the wrapper assertion looked for `$PWD` on any line mentioning `--profile` or `PREFLIGHT_PROFILE=`. It failed against the *shipped* wrapper, on two lines that are correct:

```text
53:	if ! nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" -- true >/dev/null 2>&1; then
67:	nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" \
```

The `$PWD` there is the *workdir*, which is the project and is supposed to come from the invocation. What has to be pinned is the description, so the assertion extracts the value handed to `--profile` and to `PREFLIGHT_PROFILE=` and requires each to be the store path or the variable holding it. Under the shipped wrapper those values are `$PREFLIGHT_PROFILE` twice and the store path once.

### nono's capability banner goes to stderr

Roughly 150 lines of it, per session. A check that merges stdout and stderr the way `check_r1` and `check_r2` do turns its own readings into needles in that banner, so this one keeps the two apart. The same applies to `nix build` in a check: with the tree edited it warns that the git tree is dirty, and on the suite's own stderr that reads as the suite having left the tree changed.

## M5e — An untrusted repository cannot grant itself paths

Measured on x86_64-linux with nono 0.74.0, from inside the devShell, against the shipped `.#confinement-claude-code`. The fake `$HOME` was a `mktemp -d -p "$XDG_RUNTIME_DIR"` holding `reach/target.txt` with a per-run canary, and every arm ran `nono run <flags> --workdir <project> --allow-cwd` over a probe printing `READ :: <status> :: <value>`.

The checkout's own agent configuration was modelled as a nono **user profile inside the project**, at `<project>/.tmp/r5/cfg/nono/profiles/evil.json`, built from the shipped description with one directory added to `filesystem.read`. That location is not contrived: the devShell points `XDG_CONFIG_HOME` at `$PWD/.config`, and nono's user profile directory is `$XDG_CONFIG_HOME/nono/profiles`, so a confinement description written inside the project is already a description nono will find. This is the other side of the trade recorded as `C1`.

### R5 holds, and the flag on the command line is the whole reason

| Arm | Invocation | `READ` |
| --- | --- | --- |
| A | `nono profile list`, config root inside the project | lists `evil` under `User (<project>/…/nono/profiles)` |
| B | `--profile <store path>`, the same config root present | `1` — denied |
| C | `--profile evil`, resolved by name from that config root | `0`, canary read |
| D | `--profile <store path>` plus `NONO_ALLOW=<dir>` | `0`, canary read |
| E | `--profile <store path>` on the command line, `NONO_PROFILE=evil` in the environment | `1` — denied |
| F | no `--profile` at all, `NONO_PROFILE=evil` | `0`, canary read |
| G | the same read, unconfined | canary read |
| H | `--profile <store path> --extends evil` | `0`, canary read |

Arm B is R5. Arm C is what makes it evidence: the same file, in the same place, grants the very path the moment anything resolves it, so B is a request refused rather than a file nobody read. Arm G says the target was reachable to begin with.

What refuses the request is arm E: `lib/confined-agent.nix` writes `--profile <store path>` into the wrapper as a command-line argument, and the argument beats `NONO_PROFILE`. Nothing about a description living inside the checkout is refused, or even noticed — A, C, F and H all read the canary out. R5 rests on the entry point naming its description explicitly, which is the same fact FR-9 rests on and the same assertion `check_r4` already makes about the wrapper.

### Widening from the invocation exists today, and nothing counters it

Arm D is FR-15's override path, already present in nono: `NONO_ALLOW` is **additive to a pinned description**, so a caller widens a session without touching the profile it names. `--extends` (arm H) is a second such channel and composes with `--profile` in the same way. Every widening flag has a variable of its own — `--allow`/`NONO_ALLOW`, `--profile`/`NONO_PROFILE`, `--credential`/`NONO_CREDENTIAL`, `--env-credential`/`NONO_ENV_CREDENTIAL`, `--trust-override`/`NONO_TRUST_OVERRIDE` — and the wrapper passes nothing that would override any of them.

So FR-15's "widening works from the invocation" needs no new mechanism. Its "and only from there" is where the reading is thinner: a checkout's own `.envrc` is part of the calling environment once a human has run `direnv allow`, and nothing in the mechanism distinguishes that from a widening declared above the checkout. The distinction FR-15 draws is a human one — `direnv allow` on a file the human read — and not one nono can make.

### nono's own configuration surfaces

`$XDG_CONFIG_HOME/nono/` carries `profiles/`, `profile-drafts/`, `config.toml` and `trust-policy.json`; `nono profile promote` applies a draft from `profile-drafts/`. There is also a project-level `trust-policy.json` looked for in the current directory, and nono ships a claude integration of its own that writes `.claude/settings.json` and `.claude/hooks/nono-hook.sh`.

### The three surfaces that were owed, measured

Same harness, same fake `$HOME`, the config root inside the project. `config.toml` at `$XDG_CONFIG_HOME/nono/config.toml` is a file a checkout can ship, because `XDG_CONFIG_HOME` is `$PWD/.config` under [C1](plan.md#c1).

| Arm | Observed |
| --- | --- |
| `[extensions] extra_flags = ["--allow", <dir>]` | denied — no widening |
| `[extensions] extra_env_vars = { NONO_ALLOW = <dir> }` | denied — no widening |
| `[overrides] paths = [<dir>]` | denied — no widening |
| `[extensions] extra_flags = 42`, a type error | **starts anyway** — so the section is not validated, and therefore not a key nono 0.74.0 knows |
| `[ui] detach_sequence = "x"`, a known key with an invalid value | **refuses to start**: `Configuration parse error: Failed to parse user config: … detach sequence must contain at least two key presses` |
| malformed TOML | **refuses to start**: `Configuration parse error: Failed to parse user config: TOML parse error at line 1, column 6` |

The last two rows are what make the first three evidence. A silently ignored file and a file that widens nothing look identical from outside, and `[extensions]`'s accepted type error says that `extra_flags`, `extra_headers` and `extra_env_vars` — which do appear in the binary's serde field names — belong to some other structure and not to `config.toml`. What `config.toml` is read for is the `[ui]`, `[updates]`, `[redaction]`, `[trusted_keys]` and rollback-limit keys; the binary's own text says `user config for rollback limits`.

So `config.toml` cannot widen. It can, however, **stop every session on the machine from starting**, from inside a checkout — and through the entry point that refusal arrives as exit `77`, which is `R6`'s status for a host that cannot enforce confinement. A file in the project thereby produces the diagnosis "this host cannot confine". That is a misdiagnosis rather than a leak, so `R5` is unaffected, and it is recorded as [D19](plan.md#d19).

`--bypass-protection <PATH>` does not widen on its own: with no accompanying grant it refuses to start with `bypass_protection '<path>' has no matching grant. Add a filesystem allow (--allow, --read, --write, or profile filesystem) for this path.` And it adds nothing to a grant that has one — `--read <home>/.ssh` alone reads the key out, with or without it, which is the same hole `M5a` found and further evidence the required deny groups are not a backstop. It is also the one widening flag with **no environment variable of its own**: `--allow` carries `[env: NONO_ALLOW=]` and `--read` and `--write` carry none at all, so all three can only arrive on the command line the wrapper writes.

A project-level `trust-policy.json` is created by `nono trust init` in the current directory and carries `predicate`, `includes`, `publishers`, `blocklist` and `enforcement`. Every field selects *which files are verified and against which keys*; none of them names a path to grant. It is a channel for making a checkout's own files pass trust verification, not for widening reach, so it is outside `R5` and belongs to whatever eventually covers trust enforcement.

### The entry point is the instrument, and its capability banner is the observable

`nono` prints its whole capability set to stderr at startup, one line per grant — `r <store path> (dir)`, `r+w <project> (dir)`, `+ 34 system/group paths (-v to show)`, `net outbound allowed` — with no ANSI escapes when stderr is not a terminal. Extracting the lines whose first field is one of `r`, `w`, `x`, `r+w`, `net` or `+` and sorting them gives a granted-reach **set** that can be compared between two runs.

That turns the real entry point into the probe, rather than a hand-rolled `nono run`:

| Arm, `.#claude` run as `claude --version` | Observed |
| --- | --- |
| in-project `evil` profile and `config.toml` present, neither named | exit 0 in about a second, 131 capability lines, the hostile path absent |
| the same, config root clean | the **same 131 lines** |
| `NONO_ALLOW=<dir>` at the invocation | 132 lines — the set differs by exactly `r+w <dir> (dir)` |
| `NONO_PROFILE=evil` in the environment | the same 131 lines — the command-line argument wins |
| malformed in-project `config.toml` | exit 77, no banner |

`claude --version` exits in about a second and the banner is printed before the program runs, so the reach of a real session is observable without a shell inside it. This matters for the plant: every session in `check_r4` is driven by a `--profile` the check itself supplies, so a wrapper that resolved its description from the checkout would leave that check's readings untouched and had to be caught by reading the wrapper's text. Driving the real entry point instead means the plant moves the observable directly.

### Naming a description by name fetches one off the network, and this falsifies part of `D10`

Found by planting `M5e`'s violation — the wrapper writing `--profile claude-code` instead of the store path — and watching what a session did with an **empty** config root, where the plant was supposed to have nothing to resolve.

It resolved anyway, from the network:

```text
⬇ pulling nolabs-ai/claude
   assets/logo.png  733.92 KB ✓   bin/nono-hook.sh  2.62 KB ✓   hooks/hooks.json  486 B ✓
   profiles/claude.json ✓        skills/nono-sandbox/SKILL.md  4.65 KB ✓   … 13 artifact(s)
✓ nolabs-ai/claude 0.1.0
   Installed at  <XDG_CONFIG_HOME>/nono/packages/nolabs-ai/claude
Verified 1 pack(s)
```

`packages/lockfile.json` names the source: `"registry": "https://registry.nono.sh"`, the pack `nolabs-ai/claude` at `0.1.0`, `"pinned": false`, with sigstore provenance naming `github.com/nolabs-ai/nono-packs`. The description it installed and applied, `profiles/claude.json`, extends `default` and grants `$HOME/.claude` read-write, `$HOME/.claude.json` and `$HOME/.claude.json.lock` as files, `/tmp/claude-$UID`, and `$NONO_CONFIG/profile-drafts` read-write; it includes the `git_config` group that [D11](plan.md#d11) refuses, sets `network.block: false`, and carries a `bypass_protection` entry on the macOS keychain.

Four separate things follow, and only the last was anticipated.

- **`D10`'s "the mechanism ships no agent preset" is half wrong, and the half that is wrong is the important one.** `nono profile list` with a clean config root really does report nine built-in profiles, all language runtimes, and `nono profile show claude-code` answers `Profile not found: claude-code` — so `M1e` measured correctly with the instruments it used. But `nono run --profile claude-code` is served by a *different resolver*, which reaches a registry the introspection subcommands know nothing about. An agent preset exists; it is merely not local until something asks for it. `D10`'s other clause survives intact and is now corroborated from the horse's mouth: the packaged description grants the agent's whole credential directory read-write, which is the leak this feature removes.
- **The name is the fetch.** `--profile totally-bogus-name-xyz` exits 1 with `Profile not found`, so a name is not silently ignored; `claude-code` resolves because the registry has it. The difference between a session confined by this repository and a session confined by a third party is one token in the wrapper.
- **A store path never pulls.** With `--profile <store path>` and a clean config root, `pulling` appears nowhere and the root ends up holding `profiles/` and `profile-drafts/` and no `packages/` at all. So `FR-9`'s pinning buys more than reproducibility: it is also what keeps a network fetch out of session startup. That was not among the reasons the plan gave for it.
- **The plant demonstrated the leak by committing it.** The suite run under the plant pulled the pack into this repository's own `.config/nono/packages` — 1.1 MiB, `installed_at` matching the run to the second — because the devShell points `XDG_CONFIG_HOME` at the project. So a by-name wrapper writes third-party policy *and two executable hook scripts and a skill* into the project directory, which is `FR-26`'s category arriving through a channel nothing was watching. The residue was removed afterwards; `.config/` is gitignored, so it never reached the index.

`check_r5` does not assert against this. Its arms all drive the real entry point, which names a store path, and the by-name arm it does use resolves a file the check itself planted in the config root, so it never reaches the registry. What the check does assert is the property that makes all of the above unreachable: the reach of a session started in a hostile checkout equals the reach of one started in a clean one. The pull is recorded here as the sharpest available account of what the plant is protecting against, and as a correction owed to `D10`.

### Method notes

`env VAR=VAL … cmd --flag` stops treating arguments as assignments at the first one that is not `VAR=VAL`, so flags handed to `env` before the command become `env: '--profile': No such file or directory`. Every flag goes after the command name.

`XDG_STATE_HOME` must be outside the workdir. Pointed inside it, nono refuses with `Refusing to grant '<project>' (source: user) because it overlaps protected nono state root '<project>/…/nono'`, which is the same protected-state-root refusal `M5b` met from the other side.

## M5f — A host-global configuration does not reach an undeclared session

Measured on x86_64-linux with nono 0.74.0 against `claude-code` 2.1.237, through the built `.#claude` entry point and, for the arms that need a baseline, the raw binary out of the same closure.

### The enumeration instrument is `claude plugin list`

`claude-code` has no counterpart to `opencode debug skill`. Its subcommands are `agents auth auto-mode doctor gateway import install mcp plugin|plugins project setup-token ultrareview update`; `claude --print /skills` answers `/skills isn't available in this environment.`, and `claude doctor` reports installation health only — version, platform, authentication state, a `~/.local/bin` PATH warning — and names no extension.

`claude plugin list` is the instrument. It prints a `Skills-directory plugins (.claude/skills/*):` heading and one stanza per extension carrying the name as `<name>@skills-dir`, then `Version:`, `Scope:`, `Path:` and `Status: ✔ loaded`. It runs confined, exits 0 in about a second, and needs no credential, so it is both the "the agent starts and works" observable and the "which extensions reached it" observable in one run.

Two properties of its output shape the check. The status is a **later line** of the stanza the name heads, so a file-wide search for the name and for `loaded` would let one extension's status stand in for another's when several are planted. And the path is **abbreviated**: the extension that arrived under the plant was reported as `Path: ~/.claude/skills/<name>`, not as the absolute path, so an assertion that the listing mentions nothing under the fake `$HOME` would have passed while a host extension was loading. The name is the only usable observable.

### A skills-directory extension needs a manifest, and prose alone is invisible

A directory holding only `SKILL.md` is not reported at all — measured unconfined, against a plant that had one and nothing else: `No plugins installed`. `claude plugin init <name>`, documented as scaffolding at `~/.claude/skills/<name>/` and auto-loading next session as `<name>@skills-dir`, writes `.claude-plugin/plugin.json` (`{$schema, name, version, description, author, skills: ["./"]}`) beside a frontmattered `SKILL.md`, and `plugin list` then reports it loaded. It also writes `~/.claude.json` and `~/.claude/backups/`.

So the minimal observable plant is a manifest plus a frontmattered `SKILL.md`. A check that planted prose alone would watch the agent report nothing and record it as confinement.

### The host surface is hidden by redirection, not by denial — which is a finding against `D17`

Three canaries planted at once, at `$HOME/.claude/skills`, at `$WORKDIR/.agents/claude/skills` and at `$WORKDIR/.claude/skills`:

| Arm | Reported |
| --- | --- |
| unconfined, `HOME` only | the host canary, `Scope: user`, `Path: ~/.claude/skills/…`, loaded |
| unconfined, plus `CLAUDE_CONFIG_DIR=$WORKDIR/.agents/claude` | the project-state canary only; the host one **absent** |
| confined, through the entry point | the project-state canary only; the host one absent, and **no denial in stderr** |

`D17`'s hazard — an extension root read `$HOME`-relative, reaching a session that granted nothing — was measured for `opencode` and **does not transfer to this agent**. `claude-code`'s user-scope skills root follows `CLAUDE_CONFIG_DIR`, which the description already sets to a path inside the project, so the host root is not consulted at all. The set equality `D17` asks for is still the right assertion, and for a sharper reason than the one it gives: the mechanism that hides the host surface here is a variable in `set_vars`, and nothing about a *grant* is doing the work, so a check that only compared reach would pass while an extension arrived. Both halves have to be asserted, and neither implies the other.

The confined arm is indistinguishable from the unconfined arm that has the variable set, which is FR-21's "must not prevent one from working" already holding.

### The in-project control cannot be `.claude/skills`

Every arm above also printed `⚠ 1 project-scope plugin directory under ./.claude/skills/ was not loaded because this workspace was not trusted when plugins were scanned. After accepting the trust dialog, run /reload-plugins (or relaunch) to load it.`

A project-scope extension is therefore scanned and **not loaded** without an interactive dialog, and cannot serve as a positive control. `$CLAUDE_CONFIG_DIR/skills` — `$WORKDIR/.agents/claude/skills`, inside the project directory and inside the one grant every session has — loads cleanly, and is what the control uses.

### Which plants bite, and which does not

| Plant | Fires |
| --- | --- |
| `--read "$HOME/.claude/skills"` in the wrapper's exec block | the reach comparison and the host-path assertion. **`check_j1_1` passes**: its fake home has no `.claude/skills`, and a grant on a path that does not exist is silent |
| the same, plus deleting `CLAUDE_CONFIG_DIR` from the description | all four assertions — the host extension loads, the control breaks, and the reach moves |
| deleting `CLAUDE_CONFIG_DIR` alone | **nothing.** The session looks at `$HOME/.claude/skills`, is refused *silently* — exit 0, `No plugins installed`, and no denial anywhere in stderr — and the agent still works |

The third row is why the extension assertion needs the grant to be planted alongside the redirection: the redirection is not what keeps the host surface out on its own, and removing it produces a session that is indistinguishable from a correct one.

The first row is why this check exists beside `check_j1_1` rather than being folded into it. The two make the same comparison; only this one has a home directory with something in it for a stray grant to find.

### An in-project declaration channel neither check can see

The plant the task's criterion names is the wrapper reading the declaration from a file inside the project. The faithful rendering of that in this repository is an entry in `lib/leak-registry.nix` naming `$HOME/.claude/skills` — and it **does not fail either check**, because the registry appears on both sides of the reach comparison by design, and the redirection hides the surface anyway.

That is not a hole in the checks so much as the boundary of what they cover: the registry is this repository's own reviewed content, pinned by the ref a consumer names, and not a file a consumer's checkout carries. `check_r4` covers a session editing it, and `check_r5` covers a checkout shipping a description of its own. What no check covers is a reviewer waving through a registry entry that names a host path, which is a human gate and is recorded as one.

## M8e — Where each agent reads its declarative extensions from

**Partial.** `opencode` is measured; `claude-code` and `pi` are not.
The session doing the measuring was itself confined and got `Permission denied` on `~/.claude`, `~/.config/pi` and `~/.pi`, so their layouts are unobserved and `M8e` still owes them.
`~/.config/claude` and `~/.config/anthropic` returned `ENOENT` rather than a denial, so those two do not exist on this machine.

Measured against `opencode` 1.18.18, and against its own documentation at `opencode.ai/docs/skills` and `/docs/config`.

### The instruments

`opencode debug` answers questions that would otherwise need `strace`:

| subcommand | what it reports |
| --- | --- |
| `paths` | the nine roots it resolved: `home data bin log repos cache config state tmp` |
| `skill` | every skill it can see, as JSON with `name`, `description`, `location`, `content` |
| `config` | the resolved configuration after every merge |
| `agent <name>` | one resolved subagent |

`debug skill`'s `location` field is the decisive one: it names the file each skill was read from, so the discovery surface can be enumerated without tracing syscalls.

### The blanket `XDG_CONFIG_HOME` hides the config root, and two roots survive it

Same working directory, one variable changed, `opencode debug skill | jq -r '.[].location' | sort`:

| arm | `XDG_CONFIG_HOME` | skills found | every one from |
| --- | --- | --- | --- |
| inside the devShell | `$PWD/.config` | 9 | `~/.agents/skills/*/SKILL.md` |
| the host's own value | `$HOME/.config` | 10 | `~/.config/opencode/skills/*/SKILL.md` |

Three things follow, each measured rather than argued.
The blanket is what hides `~/.config/opencode`, which is [C1](plan.md#c1)'s cost made visible.
`~/.agents/skills` is read **`$HOME`-relative** and therefore survives the blanket entirely — which is why the confined session doing this investigation had skills at all, and why an extension can arrive in a session that declared nothing.
And skill names **dedup across roots**, with `~/.config/opencode/skills` outranking `~/.agents/skills`: the host arm shows none of the `~/.agents` copies, the devShell arm shows a skill the host arm does not, and neither arm shows both copies of the seven names they share.

### The full discovery surface, from the documentation

Six skill roots, in the order the docs list them:

| root | resolved |
| --- | --- |
| `.opencode/skills/<name>/SKILL.md` | project-relative |
| `~/.config/opencode/skills/<name>/SKILL.md` | config root |
| `.claude/skills/<name>/SKILL.md` | project-relative |
| `~/.claude/skills/<name>/SKILL.md` | **`$HOME`-relative** |
| `.agents/skills/<name>/SKILL.md` | project-relative |
| `~/.agents/skills/<name>/SKILL.md` | **`$HOME`-relative** |

The project-relative three are found by walking up from the working directory to the git worktree root, so they need **no grant at all** — which is what makes `check_j8_2`'s in-project control cheap.
Subdirectories accept plural or singular: `agent(s)`, `command(s)`, `skill(s)`, `plugin(s)`, `modes`, `tools`, `themes`.

### The mechanism that names an extra root is `skills.paths`, and it is not the obvious one

- **`skills.paths`** — a configuration key taking absolute roots, scanned recursively for `**/SKILL.md`.
  This is the one that covers skills.
- **`OPENCODE_CONFIG_DIR`** — searched like a `.opencode` directory, but the documented list is agents, commands, modes and plugins.
  **Skills are not in it.**
  Pointing this at a granted root and assuming skills followed is the failure `M8f`'s planted violation exists to catch.
- **`OPENCODE_CONFIG`** — one extra configuration *file*, merged between global and project.
- **`OPENCODE_CONFIG_CONTENT`** — inline JSON, merged last of the local scopes.

Escape hatches that matter under confinement, because a denied scan surfaces as `EACCES` rather than as an empty result: `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` skips the `~/.agents` scan, `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` the `~/.claude` one, plus `OPENCODE_DISABLE_PROJECT_CONFIG`, `OPENCODE_DISABLE_DEFAULT_PLUGINS` and `OPENCODE_PURE`.

### The config root splits cleanly, and the split is what `FR-25` and `FR-26` need

`ls -A ~/.config/opencode` on this machine: `agent`, `agent-backups`, `bun.lock`, `command`, `dcp.jsonc`, `.gitignore`, `node_modules`, `opencode.jsonc`, `package.json`, `package-lock.json`, `plugin`, `plugins`, `prompts`, `skills`.
`ls -A ~/.agents`: `backups`, `skills`.
`ls -A ~/.local/share/opencode`: `auth.json`, `bin`, `log`, `mcp-auth.json`, `opencode.db`, `opencode.db-shm`, `opencode.db-wal`, `repos`, `snapshot`, `storage`, `tool-output`, `worktree`.

So `opencode` already separates the two by directory: the config root holds settings and extensions only, while credentials (`auth.json`, `mcp-auth.json`), history and state (`opencode.db`, `storage`, `tool-output`, `log`, `snapshot`) all live under the data root.
An ancestor grant on `~/.config/opencode` would still be wrong, because it hands over `plugin/` — executable extensions, which `FR-26` refuses — and `node_modules`, `bun.lock` and the two `package*.json` files, which are the build product `FR-22` says must be provisioned rather than fetched.
`agent-backups` and `~/.agents/backups` are noise.
Hence [D17](plan.md#d17)'s enumerated, never-ancestor grant.

### Two surfaces the spike must also weigh

`.opencode/plugin(s)/*.ts` is **auto-discovered**, loaded in-process, and gets hooks on `config`, `tool.execute.before`/`after`, `chat.*`, `shell.env` and `permission.ask`.
That is arbitrary host code with the session's full reach, which is why `FR-26` separates it from the authoring surface rather than collapsing the two.

Configuration supports `{env:VAR}` and `{file:path}` substitution, and `{file:…}` accepts `~/` and absolute paths.
That is a host-file read channel inside a configuration file, and it is relevant to `FR-5` and `FR-6` independently of any grant.

`opencode`'s provider base URL is a configuration key, `provider.<id>.options.baseURL` (`endpoint` is the Bedrock alias), which is what `M8c` needs for the mediated route.

### The state root, which `D13` left open

`opencode debug paths` inside the devShell reports `state /home/pallon/.local/state/opencode` — the one root of the nine that is **not** redirected, because the shell hook sets no `XDG_STATE_HOME`.
Pointing the variable at a project path relocates it cleanly and creates the directory, so the agent honours it.
Inside a confined session the host path is denied instead, so the agent fails rather than relocating.
`M6a` carries this.

Reading the binary for variable names is not available for this agent: `strings -a` over the resolved `opencode` for `OPENCODE_[A-Z0-9_]+` yields nothing, because it is a compiled bun bundle.

### Method notes

- `opencode debug skill` is the enumeration instrument of choice, but it reports what the agent **resolved**, not every path it tried.
  A root that is denied and one that is empty look the same.
  Enumerating the locations an agent *attempts* still needs `strace -f -e trace=openat`, which is how the other two agents must be measured.
