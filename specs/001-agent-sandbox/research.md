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

The "by what" column is corrected for `opencode` and `pi` by [`M8c`](#m8c--opencode-needs-no-variable-of-its-own-and-takes-its-credential-from-the-environment) and [`M8d`](#m8d--pi-needs-two-variables-and-fr-22-is-not-the-networks-doing), which ran the agents rather than reading them. Both configuration keys exist, and neither is needed: both agents default the base URL from `ANTHROPIC_BASE_URL` and the key from `ANTHROPIC_API_KEY`, in the same constructor, so all three shipped agents take the mediated route out of the environment and this environment writes no provider configuration at all. The row for `opencode` was also wrong to expect config precedence to shadow the variable — config wins only where it is set, and nothing sets it.
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

**The consequence for `check_j6_1`, which is the whole point of recording this.** `plan.md` first specified it as "assert exit 0, which holds only if the interception CA reached `git`". That claim does not hold, because what `git` does when nothing was inspected is a property of the **host**, not of the feature. `/etc/ssl` and `/etc/pki` are in the bare floor, so on a host where those directories hold real certificate files the exchange succeeds on the system trust store and exit 0 says nothing at all. `M7e` later measured the other case on the developing machine and found the opposite — see [`M7e`](#m7e--the-toolchain-survives-interception-and-nothing-else-would-carry-it). Either way one observable cannot tell the two states apart portably, and the check would be reading the host as if it were reading the feature. **Trust propagation is only observable as a difference**, so the check must carry both sides — see `plan.md`'s entry for it.

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
A consumer who wants a package provisions it into the project before the session, which is exactly what FR-22 asks for.

Two claims in the paragraphs above are corrected by [`M8d`](#m8d--pi-needs-two-variables-and-fr-22-is-not-the-networks-doing), which had to make `PI_OFFLINE` bite:

- "`PI_OFFLINE` disables *startup* network operations, not explicit commands" is right, but the *startup* half was never observed here, because it was measured with no package declared and there was nothing for it to disable. Declare one and it is plain: `{"packages":["npm:left-pad"]}` in the user settings file, and without the variable the next `pi` invocation runs a real `npm install` and leaves `npm/node_modules/left-pad` under the relocated root. With it, `pi list` reports the package and installs nothing.
- "`PI_OFFLINE` also suppresses the update check and the model-catalogue refresh" was inferred from the documentation rather than measured, and no run here could tell the two arms apart: `pi --list-models` and a real `-p` exchange produced identical file trees and identical `connect` sets under `strace` either way. Whatever those two operations are gated on, it is not something an unattended check reaches. The variable stays for the install, which is observable.

Also worth writing down, because the name reads exactly like the mechanism FR-22 wants: `PI_PACKAGE_DIR` is documented as "override the package directory, useful for Nix/Guix store paths", and it is **not** about `pi` packages. It defaults to `dirname(process.execPath)` and feeds `getThemesDir()` and its siblings — it names `pi`'s own installation. Setting it would point the agent's themes and assets at the wrong place while moving no extension at all.

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

This is the third time in this feature that occurrence has failed to predict behaviour, after `pi`'s documented-but-absent override in `M1d` and the substitution premise `M1b` falsified. That claude ignores the four `XDG_*` roots is a fact about claude, not a reason to leave them unset: `M6a` later put all five of `TMPDIR`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_STATE_HOME` under `$WORKDIR` in `set_vars`, because they are the *shared* roots every agent and every session tool reads, and pointing them at the host would merely relocate the failure. The finding here is narrower than the sentence this replaces: relocating the `XDG_*` roots does nothing for `claude` in particular, so `claude`'s own containment rests entirely on the three variables that do govern.

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

- **`nono run -s` refuses outright without `--allow-cwd`**, even when the description sets `workdir.access = "readwrite"`: `nono: CWD access requires --allow-cwd in non-interactive mode`, exit 1. `M1g` already found the flag grants read-only unless the description says otherwise; this is the other half — without it there is no session at all. `M4b`'s entry point needs both facts. The `-s` is load-bearing and this line named the wrong cause until `M9a`: see [the three states of `--allow-cwd`](#the-three-states-of---allow-cwd) for what happens without it.
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

A third consequence surfaced at `M9a`, once the pre-flight started passing `--allow-cwd` and the project became a genuinely allowed parent: **the floor's dotfile denies are derived from `$HOME`, so a `$HOME` inside the granted project makes nono refuse to start.**

```text
nono: Sandbox initialization failed: Landlock deny-overlap is not enforceable on Linux.
48 deny rule(s) cannot apply under an allowed parent directory.
```

A check that fabricates a home under `$REPO_ROOT/.tmp/` therefore never reaches the assertion it exists for — it trips assertion 1 instead. `check_r6` arm 3, which needs an unwritable `$HOME` to prove the pre-flight reports one, keeps its scratch home under `$XDG_RUNTIME_DIR`. That is no contrivance: a real user's home is never inside the checkout either.

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

### The three states of `--allow-cwd`

`nono run --help`: `--allow-cwd` is "Allow CWD access without prompting (level set by profile, defaults to read-only)". It is the **consent**; the description's `workdir.access = "readwrite"` decides what the consent is worth, not whether it was given. The resolved manifest reports `readwrite <project>` either way, so **the manifest cannot detect a missing consent**. That is the concrete reason `check_j1_1` reads a session rather than a resolution.

Omitting the flag does not have one behaviour, it has three, and which one you get depends on `stdin` and on `-s`. Measured on nono 0.74.0 against the project's own opencode description, whose `workdir.access` is `readwrite`:

| Invocation | `stdin` | Behaviour |
| --- | --- | --- |
| `--allow-cwd` | anything | Silent. Project granted `r+w`. Exit 0 |
| no flag | not a TTY | `Skipping CWD prompt (non-interactive). Use --allow-cwd to include working directory.` on stderr, and **the project is not granted at all** — a confined `: > .tmp/probe` leaves no file. Exit 0 |
| no flag | a TTY | **Blocks on a prompt**: `Share <project> with read+write access? … [y/N]`, with `use --allow-cwd to skip this prompt` beneath it |
| `-s`, no flag | either | `nono: CWD access requires --allow-cwd in non-interactive mode`. Exit 1 |

Both message strings live in the same binary, so the earlier reading of the refusal as *the* non-interactive behaviour was a conflation: `-s` suppresses the notice, and a run that cannot say it is skipping the prompt refuses instead of proceeding half-granted.

The third row is the one that mattered. `M4a`'s pre-flight omitted the flag on the argument that it writes nothing inside the project — true of the *grant*, and silent about the *prompt*. It sent both streams to `/dev/null` while leaving `stdin` attached to the user's terminal, so a real session hung on a question whose text had been discarded, showing nothing at all. Nothing in the suite could see it: `validate.sh` runs every check under `</dev/null`, which is precisely row two. `M9a` gave the pre-flight the flag on both of its runs, and added `check_r6` arm 4 — an argv-logging `nono` stub asserting that every `nono run` the pre-flight makes carries `--allow-cwd`, a property that holds for invocations added later and needs no TTY to check.

The general lesson is worth more than the fix: **a check suite that pins `stdin` to `/dev/null` is blind to every interactive prompt the product can produce**, and a wrapper that discards `stderr` turns such a prompt into a silent hang. Redirect what you must, but assert on the argv.

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

## M5g — A host tool configuration does not direct the session

Measured on x86_64-linux with nono 0.74.0 and git 2.55.0 out of the shipped substrate, against `.#confinement-claude-code` and the `.#claude` entry point. The planted host configuration was the same one the check now uses: `$HOME/.gitconfig` carrying `user.name`, `user.email`, `credential.helper = cache --timeout=99999`, `core.hooksPath`, `commit.gpgsign = true` and `alias.canary = !echo <canary>`, plus a `$HOME/.config/git/config` carrying `core.hooksPath`, that being git's second global location.

Resolving git inside the substrate needs a `[ -x "$p/bin/git" ]` loop over `store-paths`, not a name match: `grep -m1 -E '\-git-[0-9]'` finds the `-doc` output first, which has no `bin/git`.

### The effective configuration inside a session is already clean, and the file it is pointed at did not exist

| Reading, inside the session | Observed |
| --- | --- |
| `GIT_CONFIG_GLOBAL` | `$WORKDIR/.agents/git/config` — and the file was **absent** |
| `GIT_CONFIG_SYSTEM` | `/dev/null` |
| `XDG_CONFIG_HOME` | unset — no `XDG_*` variable is in `allow_vars` |
| a direct read of `$HOME/.gitconfig` | denied |
| `git config --list --show-origin --show-scope` | `local file:.git/config` entries only — no `global` scope, no `system` scope, none of the six planted directives, no canary |
| the same probe, unconfined, same `HOME` | all six directives, under `global file:$HOME/.gitconfig` |

So the probe discriminates, and pointing `GIT_CONFIG_GLOBAL` at a path that does not exist suppresses **both** `~/.gitconfig` and `~/.config/git/config`. The absent file is the gap this task closed: the control criterion — a setting this environment wrote, read back — could not pass, because `user.name` inside a session was coming from the repository's own `.git/config`.

### `GIT_CONFIG_SYSTEM=/dev/null` is load-bearing on a host with no system file

`/etc/gitconfig` does not exist on this machine and nix's git ships no `$out/etc/gitconfig`, but git's compiled-in system path is `/etc/gitconfig` regardless.

| `git config --list --system` | Result |
| --- | --- |
| with the variable set | exit 0, empty output |
| with the variable absent | exit 128, `fatal: unable to read config file '/etc/gitconfig': No such file or directory` |

The variable stops the toolchain *going looking*. The assertion is therefore that the system scope **resolves and contributes nothing**, which fails by error on a host like this one and by content on a host that carries the file. `/dev/null` never appears as a `file:` origin, so the origins property needs no special case for it.

### A `core.hooksPath` hook does run, so the second arm is testing something live

Measured unconfined, with the planted `core.hooksPath` and a `pre-commit` writing a marker: the hook ran and the marker was written. The hook lives **inside the project directory** in every arm, because a hook in the fake home would be unreadable inside a session and a crossed directive would then fail for a reason that has nothing to do with the directive. Its shebang is the substrate's own bash: `#!/bin/sh` would fail to exec in a store-only session, which would mask a leak as an unrelated failure.

A commit with no identity at all fails visibly — exit 128, `Author identity unknown`, `*** Please tell me who you are.` — which is the **P9** shape, and is why a host with no identity leaves no file rather than a placeholder.

### The grant and the variables catch different things

| Plant | Integration | Component |
| --- | --- | --- |
| `groups = [ "git_config" ]` | **nothing** — `10 checks passed` | `check_confinement_validates`: `groups.include carries git_config`; `check_sc1`: `~/.gitconfig`, `~/.config/git/ignore` and the host's home-manager gitconfig store path granted |
| that, plus dropping `GIT_CONFIG_GLOBAL` | `check_r10`, every assertion but the system scope — including the hook actually running | the same two |
| dropping `GIT_CONFIG_SYSTEM` | `check_r10`, the system scope and the direction | `check_confinement_validates` |

The first row is the finding: **the grant alone is not the leak.** While `GIT_CONFIG_GLOBAL` is set, git ignores `~/.gitconfig` however readable it is. What leaks is the *search*, which is exactly what `D11` says and what a read-only grant does not stop. So `check_r10` is not the check that catches a `git_config` grant — the component layer is — and the two halves of the criterion belong in two layers rather than being duplicated into both.

The second row reconstructs the incident `D11` was written from: `credential.helper = cache` in the effective configuration, `commit.gpgsign` producing `gpg failed to sign the data` and `COMMIT_RC :: 128`, and a program named by the host configuration executing inside the session and leaving its marker behind.

### Two bugs in the check itself, both found by planting

- **`git config --file <listing>` parses a listing.** Control 2 first read the effective configuration back with `git config --file effective.txt --list`, falling back to `sed` on failure. git parsed the `--show-origin --show-scope` listing as though it were a configuration file and exited 0, so the fallback never ran and the control failed against a file that plainly carried the setting. The fix strips the two tab-separated prefix fields with `sed` and matches with `grep -qxF`.
- **git lowercases section and key names in `--list` output.** `core.hooksPath` reads back as `core.hookspath`, so the one directive whose hook was observed *running* was the one directive the check did not report. It was the only assertion of the six that could not have failed. Matching is now case-insensitive. Both bugs argue the same thing: a check that has only ever passed has not been checked.

## M5h — Every refusal check has a control

Measured on x86_64-linux with nono 0.74.0, from inside the devShell, over the suite as it stood at eight refusal checks.

### The enumeration is not vacuous, and it is not uniform either

`refusal_check_bodies` finds exactly eight `check_r*` functions — `check_r6`, `check_r1`, `check_r2`, `check_r3`, `check_r4`, `check_r5`, `check_r10` in `scripts/checks/integration.sh`, and `check_r7` in `scripts/checks/unit.sh` — and all eight already carry an in-body control marker. So the check passes as shipped and could only be seen to fail under a plant.

There is no mechanical marker on a control assertion anywhere in the suite, and inventing one would have meant rewriting eight checks to satisfy a ninth. What exists is a comment convention, and it appears in two places: a paragraph in the header comment above the function, and a `# Control …` line inside the body. **The marker is looked for inside the body only**, and the reason is the plant below: `check_r2`'s header paragraph, "Two controls, because the observable is a failure (D9)", survived the deletion of both controls untouched. A check that read the header would have been satisfied by prose describing arms that were no longer there.

### Plant 1 — a refusal check with its controls deleted goes on passing

The plant removes `check_r2`'s two control arms the way a careless hand would leave them, comments and code together, and leaves the check otherwise able to run: the unconfined write that proves the target was writable, and the granted arm that proves the probe can write outside the project when the boundary allows it.

| Layer | Result |
| --- | --- |
| unit | `2 of 5 checks failed` — `refusal check asserts no permitted action: check_r2 (integration.sh)`, plus the standing `check_sc3` progress bar |
| integration | **`10 checks passed`, `check_r2` among them** |

The second row is the whole argument for the check. With both controls gone `check_r2` still reports a refusal it can no longer distinguish from a session that never started, and nothing but `check_controls` says so.

### Plant 2 — the suite-wide lever is the workdir grant, and `"none"` is accepted

Every refusal check drives its sessions from the built description, so the description is the one lever that reaches all of them at once. `lib/confinement.nix` carries `workdir.access = "readwrite"`; nono 0.74.0 accepts `"none"` in its place and does withhold the project.

| Check | Outcome under the plant |
| --- | --- |
| `check_r6` | **PASS** — starts no session at all, so the description cannot reach it |
| `check_j1_1` | FAIL — the reach diff, the project line gone |
| `check_substrate_denials` | FAIL — `the narrow arm did not start (exit 1)` |
| `check_r1` | FAIL — `the shipped arm never read the file inside the project, so it observed no session (exit 126)`, and the same for the granted arm |
| `check_r2` | FAIL — `the shipped arm never wrote inside the project, so it observed no session (exit 126)`, and the same again |
| `check_r3` | **PASS** — its subject is the environment, which the workdir grant does not touch |
| `check_r4` | FAIL |
| `check_r5` | FAIL — `the file the checkout planted did not make the path outside the project readable when it was resolved (exit 126), so it is inert and arm 1 proves nothing` |
| `check_j8_2` | FAIL |
| `check_r10` | FAIL |

`8 of 10 checks failed`, and three of them failed in the control's own words rather than on the refusal they exist to assert. That is D9 holding across the suite rather than check by check.

**Both survivors are principled, and saying which is the point of running the plant.** `check_r6` asserts the pre-flight refuses an unenforceable host, which happens before any session exists; a description it never reaches cannot invalidate it. `check_r3` asserts a secret does not cross in the environment, and its session genuinely ran — a denied workdir does not stop a program that reads its substrate and prints its own environment. Neither is an uncontrolled check that got away with it.

### A denied workdir surfaces as exit 126, and nono's own summary misreports it

Exec'ing the substrate's `bash` under `workdir.access = "none"` gives **exit 126**, with nono's note `The file may not have execute permission, or the sandbox may be blocking execution of binaries in that directory`. Its end-of-session summary still prints `No path denials were observed during this session. The failure may be unrelated to sandbox restrictions.` — the same unreliable self-report `M5b` recorded for a refused write, now for a refused exec, and a second reason no check reads that summary as evidence.

## M6a — Agent state lands in the project

Measured on x86_64-linux with nono 0.74.0 and `claude-code` 2.1.237, from inside the devShell, against the shipped `.#confinement-claude-code` and the shipped `.#claude` entry point. The fake `$HOME`, the ambient `XDG_STATE_HOME`, the config root and the scratch project were four siblings under `mktemp -d -p "$XDG_RUNTIME_DIR"`, so the project is never under the home.

### Journey 2.1 already holds for this agent, so the RED has to be planted

`claude plugin list` through the entry point, with the fake `$HOME` listed before and after:

| Observed | |
| --- | --- |
| exit status | 0 |
| `diff` of the fake `$HOME` before and after | **empty** |
| what landed in the project | `.agents/claude/.claude.json` and `.agents/claude/backups/.claude.json.backup.<epoch-ms>` |

So the scenario's `Then` and `And` both already hold, and the control the criteria ask for — the writes found where they were redirected to — is what makes the empty diff mean anything. `plugin list` is enough of a session to write state, needs no credentials, and finishes in about a second, so no conversation has to be driven to get a write.

`.claude.json` is the file `M5f` saw `claude plugin init` create in a host home. Under `CLAUDE_CONFIG_DIR` it lands in the project instead, which is the redirection working rather than a second location.

### D13's load-bearing assumption is true, and this is the observation `M6a` owes

The question `D13` left open is whether the supervisor's own protected state root and the child's `XDG_STATE_HOME` resolve independently. Two arms, one description apart — `jq '.environment.set_vars.XDG_STATE_HOME = "$WORKDIR/.agents/state"'`:

| Arm | Child's `XDG_STATE_HOME` | Child writes there | nono starts | Supervisor's audit record |
| --- | --- | --- | --- | --- |
| shipped | **`<unset>`** | denied | yes | under the ambient value |
| `set_vars.XDG_STATE_HOME = "$WORKDIR/.agents/state"` | the expanded project path | **ok**, and the directory appears at `<project>/.agents/state/probe` | yes, no overlap complaint | under the ambient value |

So the child can be moved into the granted workdir without making that workdir ungrantable: `$WORKDIR` expands in `set_vars`, no `Refusing to grant … overlaps protected nono state root` appears, and the supervisor went on writing its audit record under the ambient path in both arms. `M6a` can assert this by observation exactly as its criterion demands.

### Inside a session the variable is *unset*, not host-valued, and that correction matters

The handbook and `D13` both read as though a confined session inherits the host's `XDG_STATE_HOME`. It does not: `allow_vars` carries no `XDG_*` pattern, so the variable does not cross at all. A tool that honours XDG therefore falls back to the specification's default, `$HOME/.local/state`, which the session denies — the same failure `D13` predicts, reached by a different route. The distinction is not cosmetic: it means the fix is adding the key to `set_vars`, and that nothing has to be *removed* from `allow_vars` first.

### Two traps that will otherwise cost a session

A probe script must live **inside the granted workdir**. Written to the scratch directory beside the fake `$HOME` instead, every arm reported **exit 126** with no output — the same signature `M5h` produced by denying the workdir outright. A run that fails this way looks exactly like a boundary working.

The identity file `.agents/git/config` was **not** written by any of these runs, and that is an artefact of the developing environment rather than a defect. The wrapper copies it with `git config --global --get`, and this repository's own agent session is itself confined by an outer sandbox that denies `~/.gitconfig`, so both values come back empty and the wrapper correctly writes nothing. `check_r10` measures the copy against a planted `$HOME/.gitconfig` and is unaffected.

### Every environment-resolved root arrives unset, and one of them fails *silently*

A `bash` probe out of the substrate, in a shipped-description session with the fake `$HOME` and the scratch project as siblings:

| observable | result |
| --- | --- |
| `TMPDIR`, `TMPPREFIX`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_RUNTIME_DIR` | **all `<unset>`** |
| `HOME` | the fake home, as `allow_vars` intends |
| `mkdir -p $HOME/{.cache,.local/share,.config,.local/state}/probe` | **denied**, all four |
| `mkdir -p /tmp/probe-$$` | **ok** |
| `mkdir -p <proj>/{.cache,.local/share,.config,.agents/state,.tmp}/probe` | **ok**, all five |
| the fake `$HOME` afterwards | empty |

Three things follow. `D13`'s hole is wider than that decision states — *no* XDG root crosses, and neither does `TMPDIR`, so the devShell's redirection stops at the boundary entirely and the task's "not only the ones the devShell happens to redirect" turns out to mean *none of them*. Every `$HOME`-relative fallback is denied, which is **P9** working as designed. And `/tmp` **is writable** inside a session, because it is among the 33 system paths in the floor — so a tool falling back there because `TMPDIR` is unset writes outside the project, silently, at a path two projects share. That last one is the only hole here that no criterion had named, and it is the reason `TMPDIR` joins the four XDG keys rather than the state root going in alone.

### A plant harness that reverts by `git checkout` will eat an uncommitted GREEN

The first harness for this task reverted with `git checkout -- lib/agents.nix lib/confinement.nix lib/confined-agent.nix` from an `EXIT` trap. The GREEN change was not yet committed, so the trap discarded it along with the plant, and the next run measured a tree with no relocated roots at all and reported four coverage failures that had nothing to do with the plant. It is a false result that reads exactly like a true one. A harness must back the files up by copy and restore by copy, and this one now says so where the trap is set.

### Two nono facts about granting the fallback, which the plant needs

A grant naming a regular file is refused at startup: `nono: Configuration parse error: CLI path '<home>/.claude.json' is not a directory. Use --allow-file for single files.` And granting `$HOME/.claude` is not sufficient on its own, because `~/.claude.json` is a sibling rather than a child — which is why nono's own `nolabs-ai/claude` pack names `$HOME/.claude`, `$HOME/.claude.json` and `$HOME/.claude.json.lock` separately. A plant reproducing the leak needs both grants and both flags.

### An empty fake home cannot demonstrate the leak, and the snapshot has to carry more than paths

With an empty `$HOME`, dropping the relocation and granting the fallback still left the diff arm empty: the agent's fallback location did not exist, so it wrote nowhere and the arm passed for the wrong reason. Planting a prior installation — `$HOME/.claude` and a `$HOME/.claude.json` — is both the fix and the more honest Given, since a consumer adopting this environment has run the agent before. Under that fixture the leak the plant produces is a **single file rewritten in place**, so a snapshot of paths alone still reports no change. Both snapshots therefore carry size and mtime, `find "$home" -printf '%p\t%s\t%T@\n'`.

## M6b — Two concurrent projects share nothing

Measured on x86_64-linux with nono 0.74.0 and `claude-code` 2.1.237, through the built entry point, with two `git init`ed checkouts, one fake `$HOME`, one config root and **one** ambient `XDG_STATE_HOME` shared between both — which is the arrangement a consumer is actually in, and the one spec Risk 16 is about. Both sessions were started with `&` and joined with `wait`, so they were genuinely concurrent rather than sequential.

### Journey 3.1 already holds, and nothing contended

| Observable | Result |
| --- | --- |
| Both exit statuses | `0` and `0` |
| Each project's diff | its own `.agents/claude/.claude.json` and one timestamped backup, and nothing else |
| The other project's diff | empty, in both directions |
| The fake `$HOME` diff | empty |
| Either project's path in the other session's stderr | absent, in both directions |
| Anything matching `lock|contend|busy|port|address in use|conflict|retry` in either stderr | nothing |
| Granted reach, non-store lines | `r+w <root>/alpha (dir)` for one and `r+w <root>/beta (dir)` for the other, plus the 34 system/group paths and `net outbound allowed` — neither names the other |

So both halves of FR-8 hold as shipped, and `M6b` is another task whose only available RED is a planted one.

**Risk 16's two premises come apart.** The shared supervisory state directory is real — `$XDG_STATE_HOME/nono/` gained `audit/`, `sessions/` and, notably, **`audit/ledger.lock`**, so nono guards the shared ledger with a lock rather than assuming one writer. The loopback port the risk also names was **not observed**: nothing in either session's output mentions a port, and two concurrent sessions produced no contention message of any kind. The risk should be narrowed to what was measured rather than left as written.

### Three audit records per session, so `check_j1_1`'s selection idiom does not carry over

Each session leaves **three** records under `$XDG_STATE_HOME/nono/audit/*/session.json`, not one:

| `.command[0]` | `.tracked_paths` |
| --- | --- |
| `true` | 128 — the store only |
| `sh` | 128 — the store only |
| `/nix/store/…-claude-code-2.1.237/bin/claude` | 129 — the store plus the one project |

The `true` record is the pre-flight's enforceability probe and the `sh` record is raised alongside it; neither is granted a workdir, which is why both are one path short. `check_j1_1` selects "the one record whose `.command[0]` ends in `/bin/claude`" and requires exactly one, which is sound for a single session and **wrong for two** — two concurrent sessions leave two such records.

A record carries no working directory. Its keys are `audit_attestation audit_event_count audit_integrity command ended executable_identity exit_code merkle_roots network_events session_id snapshot_count started tracked_paths`, and `.cwd`, `.workdir` and `.working_directory` are all absent. So a record cannot be attributed to a session by any field it carries, and selecting by the project path in `tracked_paths` is the obvious substitute — which the plant below falsified. Selection has to be by the agent's own command, and the property has to be stated over the pair.

### `$WORKDIR/..` is expanded and canonicalised, and it defeats selection by path

The plant that grants a sibling checkout is one line: `allow = pathsWith "readwrite" ++ [ "$WORKDIR/.." ]`. The description carries the literal `"$WORKDIR/.."`, and nono resolves **and canonicalises** it — the banner's only non-store grant is `r+w <tmp>/work (dir)` and the audit record's only non-store `tracked_paths` entry is `<tmp>/work`, the parent, with neither project named.

That is why `check_j3_1` cannot select its records by project path. Under the plant the selection found **0** records for each project and the check returned early on `expected exactly one session record naming alpha, found 0` — failing on its own bookkeeping before reaching its subject. A plant naming the sibling exactly would have broken it the other way, finding 2. So selection is by `.command[0] | endswith("/bin/claude")` requiring exactly two, which is path-independent, and the property is stated over the pair: each record reaches exactly one of the two checkouts and the two differ. **An ancestor counts as reaching**, since a grant that contains a checkout is as bad as one that names it.

### The read-only arm fires one half and not the other

Appending the same path to `read` rather than `allow` fires the reach assertion and leaves every cross-write assertion green. That is the measured reason both halves of FR-8 are asserted rather than one standing in for the other: a read grant on a sibling is a leak that no write attempt can observe.

### Two method notes

A jq `.` **rebinds after a `|`**. The ancestor clause was first written `any(.tracked_paths[]; . == $p or startswith($p + "/") or ($p | startswith(. + "/")))`, and inside that last parenthesis `.` is `$p`, so the clause compared `$p` against itself and never matched. It has to bind the element first: `. as $t | $t == $p or ($t | startswith($p + "/")) or ($p | startswith($t + "/"))`. The bug was silent — the plant still failed, on the other half, so only the message text (`reaches 0 of the two checkouts (none)`) gave it away.

`v=$(<"$f" 2>/dev/null)` yields the empty string whatever the file holds. Bash's `$(<file)` fast path takes no additional redirection, so the added `2>/dev/null` turns it into an ordinary redirection-only command with no output.

## M7 — The credential surface, and interception measured rather than reasoned

Measured on x86_64-linux against the pinned **nono 0.74.0**, whereas [`M1b`](#m1b--pointing-an-agent-at-a-substituted-endpoint) was measured at 0.73.0. Everything below comes either from `nono profile schema` — a 103,981-byte JSON Schema, so the whole surface is machine-readable and needs no `strings` over the binary — or from live sessions against the shipped `.#confinement-claude-code` with one `jq` edit between arms.

### The credential surface is five top-level keys plus two under `network`

The description has 34 top-level keys. Five carry credentials, and the two `M1b` discussed by name are **not** among them, because they live under `network`:

| key | shape | what it is for |
| --- | --- | --- |
| `credential_capture` | object → `CredentialCaptureEntry` | supervisor-side commands or provider subprocesses backing a `credential_key: "cmd://<name>"`. Captures run lazily and "captured material is injected by the proxy and never exposed to the sandboxed child" |
| `credential_providers` | object → `CredentialProviderDef` | declarative OAuth capture: token endpoints to capture, API origins where phantoms resolve, optional store detection and lifecycle helpers |
| `credential_routes` | **array** → `CredentialRouteDef` | binds a provider to a sandbox-visible phantom credential |
| `env_credentials` | `SecretsConfig` | keystore account names or `op://`/`bw://`/`apple-password://`/`env://` URIs mapped to variable names, loaded at startup |
| `secrets` | `SecretsConfig` | an alias for `env_credentials` |
| `network.credentials` | array of names | "Credential service names to enable via the reverse proxy" — the activation list |
| `network.custom_credentials` | object → `CustomCredentialDef` | "Keys are service names used with `--credential`" |

Required fields, which is what constrains the arrangement `M7a` and `M7b` have to write:

- `CredentialRouteDef` — `name`, `provider`. `env_var` is optional and its own description says why: it is "for clients that can start from a sandbox-visible phantom token. Many OAuth CLI clients instead receive phantoms through their captured credential store during login." `base_url_env_var` "points SDKs at the mediated proxy base URL". `upgrades` names WebSocket targets, each origin having to be one of the provider's `api_hosts`.
- `CredentialProviderDef` — `type` (`oauth_capture`), `token_endpoints` ("Configure every token-bearing endpoint the client may use"), `api_hosts`. `inject_header` defaults to `Authorization` and `credential_format` to `Bearer {}`.
- `CustomCredentialDef` — only `upstream`. **`env_var` is required whenever `credential_key` is a URI manager reference** — `op://`, `bw://`, `apple-password://`, `file://`, `cmd://` — and optional only for `env://`, where it is derived. `credential_key` is mutually exclusive with `auth`, `aws_auth` and `spiffe`. A non-empty `endpoint_rules` makes that route default-deny, and `rate_limit` "applies only to L7-visible traffic" with "no effect on opaque CONNECT tunnels".
- `CredentialCaptureEntry` — nothing required. `command` is "executed without a shell", `provider` is a subprocess speaking `nono.credential-provider.v1`, and `interaction` is an "explicit opt-in policy for interactive capture commands".
- `CommandCredentialConfig` carries a **`local-socket`** kind whose `path` is "commonly `$SSH_AUTH_SOCK` for SSH agent", with `mode: connect`. So the forwarded-agent-socket route [`D16`](plan.md#d16) names for a signing key is a first-class credential type rather than something that would have to be built, which is what `M7f`'s closing note should cite.

A bogus service name is still accepted silently at 0.74.0: `nono run --credential __bogus__ --dry-run -- true` exits 0 with nothing in either stream matching `bogus|unknown|credential`. `M7a`'s criterion that the wrapper validate the name itself therefore still stands, and is not an artefact of the older version it was first measured against.

### D12 holds exactly, and the plant `M7e` names is measured to bite

`allow_domain`'s items are `oneOf` a plain string or an `AllowDomainWithEndpoints`, which requires `domain` and `endpoints`; each `EndpointRule` requires `method` and `path`, both **singular**. Guessing the plurals gives `Profile parse error: data did not match any variant of untagged enum AllowDomainEntry` and exit 1 — a malformed arm refuses to start rather than falling back, so a check cannot get this subtly wrong and pass.

Two arms, one `jq` edit apart, each running a bash probe out of the substrate:

| `network.allow_domain` | the five trust-bundle variables | the banner's network line |
| --- | --- | --- |
| `["example.com"]` | all five **`<unset>`** | `net outbound allowed` |
| `[{"domain":"example.com","endpoints":[{"method":"GET","path":"/"}]}]` | all five set, to the **same** path | `net proxy` |

Both exit 0. So interception is per-destination and off by default exactly as `D12` says, and `M7e`'s planted violation — asking for the destination as a plain string — leaves all five unset, which means arm 1 asserts a difference rather than restating the description. The banner's `net proxy` is a second observable for the same fact, independent of the child's environment, and worth asserting alongside the variables rather than instead of them.

### The trust bundle is readable from inside, and it does not widen the reach

This was the open question, because the bundle is at `$XDG_STATE_HOME/nono/sessions/intercept-<pid>-<n>/intercept-ca.pem` and [`D13`](plan.md#d13) keeps `XDG_STATE_HOME` deliberately outside the project. From inside the intercepting session:

| observable | value |
| --- | --- |
| `SSL_CERT_FILE` | the `intercept-ca.pem` path under the ambient `XDG_STATE_HOME` |
| the file exists | yes |
| reading it | succeeds, and it contains `BEGIN CERTIFICATE` |
| the banner's non-store grants | the project, `+ 34 system/group paths`, `net proxy` — **and nothing else** |
| the audit record's non-store `tracked_paths` | the project, and nothing else |

Both halves matter. **`M7e` arm 1 can assert that the file exists and parses, from inside the session**, which is what the criterion asks for and what the location made doubtful. And the readability does **not** appear as a tracked path, so `check_j1_1`'s and `check_sc1`'s set equalities are unaffected by interception and neither needs a new exception. Whatever mechanism delivers the file — a pre-opened descriptor, a bind, or a path inside the collapsed `+ 34 system/group paths` — is invisible to the observable the reach checks are built on.

The intercept directory is also **removed when the session ends**: `find "$XDG_STATE_HOME/nono/sessions" -name 'intercept-*'` afterwards finds nothing. So a check must read the bundle from inside the session and cannot inspect it afterwards.

### Two traps for whoever writes these checks

`XDG_CONFIG_HOME` pointing at a directory that does not exist produces nine `WARN Ignoring invalid XDG_CONFIG_HOME='…' (canonicalize failed: No such file or directory)` lines on stderr and **falls back to `$HOME/.config`** — silently, as far as the exit status goes. A check that means to isolate the config root must `mkdir -p` it, or it will be testing the developer's own configuration.

`nix build .#nono` is the way to reach the pinned supervisor from a harness; `substrate_member`'s loop over `store-paths` testing `[ -x "$p/bin/bash" ]` is the way to reach a `bash`, and a name regex is not, because the `-doc` output sorts first and carries no `bin/`.

## M7a — A readable credential is a substitute

Measured on x86_64-linux with nono 0.74.0, against the shipped `.#confinement-claude-code`, from harnesses that ran a bash probe out of the substrate and printed `VAR :: <name> :: <value|<unset>>` for `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_API_BASE_URL` and `NONO_CAP_FILE`. Each arm is one `nono run --profile <file> --workdir <scratch project> --allow-cwd`, with the fake `$HOME`, the ambient `XDG_STATE_HOME` and the config root as siblings of the project under `$XDG_RUNTIME_DIR`.

### The arrangement is one line, and it is nono's own built-in route

`network.credentials = [ "anthropic" ]` and nothing else. `anthropic` is one of six service names nono ships in its `network-policy.json` — the others are `gemini`, `github`, `gitlab`, `google-ai` and `openai` — so the upstream, the injected header and the endpoint policy are all nono's rather than ours.

| Arm | `network.credentials` | supervisor's `ANTHROPIC_API_KEY` | child's `ANTHROPIC_API_KEY` | child's `ANTHROPIC_BASE_URL` | banner |
| --- | --- | --- | --- | --- | --- |
| A | absent | unset | `<unset>` | `<unset>` | `net outbound allowed` |
| I | `["anthropic"]` | unset | `<unset>` | `http://127.0.0.1:35467/anthropic` | `net proxy`, plus a `credential_not_found` warning |
| J | `["anthropic"]` | `sk-real-canary-4711` | `6b0edabc…5a0adb8d` (64 hex) | `http://127.0.0.1:45233/anthropic` | `net proxy` |

Arm J is Journey 4.1 in one invocation. The real value is in the supervisor's environment, which is what "the user has authenticated once on the machine" looks like on Linux where there is no keychain; the session reads a **64-lowercase-hex substitute** in its place; and the real value appears **nowhere** in the child's environment, nowhere in the resolved capability manifest the session can read, and nowhere in the project directory afterwards — all three searched for the canary string, all three absent.

Three things follow that the plan did not know.

**No `custom_credentials`, no `credential_capture` and no `credential_providers` are needed.** The elaborate surface `M7` measured is for services nono does not ship a policy for. For the one agent this feature has, the arrangement is a single service name, and `D1`'s "the leak registry stays empty provided `credential_key` resolves through `env://` or `cmd://`" is satisfied without writing a `credential_key` at all.

**A missing credential is loud, and the session still starts.** Arm I prints `Credential not found for route 'anthropic' — managed-credential requests on this route will be denied until the credential is available. Looked for env var 'ANTHROPIC_API_KEY' (not set).` both as a `Proxy credential warnings:` block and as a `credential_not_found /anthropic` line in the capability banner. That is P9's visible failure arriving from the mechanism, and it is also the observable `M7c` needs for R8: an authentication failure that names itself and is nothing like a path denial. The message's keychain advice is macOS-specific and misleading on Linux, which is worth a line in the handbook.

**The substitute is per session.** Two identical runs gave `2bd2c52f…` and `1b48ba31…`, so a substitute copied out of one session is not even the string the next session sees — a stronger property than FR-6 asks for, and one `check_j4_1` can assert cheaply.

### The route injects sixteen variables, and `check_r3` has to learn about them

`check_r3` asserts that every name crossing into a session is matched by an `allow_vars` pattern, is a key of `set_vars`, or is one of nono's three own injects — `PATH`, `BROWSER` and `NONO_CAP_FILE`. Enabling the route takes a session from 24 names crossing to 40, withdrawing none. The first arms of this section reported the addition as **two**, `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL`, because those were the only names the probe asked about; a full `env -0` diff, taken before the check was written, says sixteen:

| group | names |
| --- | --- |
| the credential | `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL` |
| the trust bundle | `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO` |
| the proxy | `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, `no_proxy`, `NO_PROXY`, `NONO_NO_PROXY`, `NONO_PROXY_TOKEN`, `NODE_USE_ENV_PROXY` |

None is in `allow_vars` (`ANTHROPIC_API_KEY` deliberately is not, per FR-5) and none is in `set_vars`, so the check fails the moment the route ships. **The lesson is about the instrument rather than about nono**: a probe that prints the variables it was told to look for cannot report the ones nobody thought of, and the whole environment was available for the asking.

For a route defined in our own description the names would be derivable, from `credential_routes[].env_var` and `.base_url_env_var` or from a `custom_credentials` entry's `env_var`. For a **built-in** service they are not: they live in nono's `network-policy.json`, and the description says only `"anthropic"`. Reading them back out of the session's resolved capability manifest was tried and does not work either — `NONO_CAP_FILE` is a 44 KiB JSON document, but it is written progressively and a probe reading it from inside the session gets an unterminated object (`Unfinished JSON term at EOF`), so it is not a usable source. What the manifest *did* answer is that the real canary is absent from it.

So the names have to be written down, and that is the one place a literal is the criterion: the assertion is precisely "these sixteen names arrive because this repository enabled this route, and no seventeenth does". A seventeenth appearing is a change in nono worth failing over, which is the same argument the check already makes for `PATH`, `BROWSER` and `NONO_CAP_FILE`. The list is consulted only for an arm whose description asks for a route, so a session with no route is still held to the narrower set.

### The substitute is the session's own proxy token, and the route switches interception on

`NONO_PROXY_TOKEN` holds the **identical** 64 hex characters as `ANTHROPIC_API_KEY`, and the same string appears as the password in `http_proxy=http://nono:<that value>@127.0.0.1:<port>`, alongside `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>/anthropic`, `NO_PROXY=localhost,127.0.0.1` and `NODE_USE_ENV_PROXY=1`. So the substitute is not a minted stand-in for the credential at all — it is the ticket that authenticates the child to its own supervisor, handed over under the name the client expects a key in. That is a stronger property than FR-6 asks for and it explains why it is per session: it is scoped to a proxy that stops existing when the session does.

The five trust-bundle variables point at `$XDG_STATE_HOME/nono/sessions/intercept-<pid>-<n>/intercept-ca.pem`, and the banner reads `net proxy` with `mode supervised (proxy, supervisor)` rather than `net outbound allowed`. **The shipped description asks for no inspected destination** — it has no `allow_domain` at all — so `D12`'s "interception is off by default" holds only of the `allow_domain` half. A credential route turns inspection on because it has to mediate, which is corrected in [`D12`](plan.md#d12) and changes `M7e`'s plant.

### The route overrides `allow_vars`, which is what broke `check_r3`'s control

Four arms of a full `env -0`, one description edit apart, with `ANTHROPIC_API_KEY=HOST-SECRET-…` in the supervisor's environment throughout:

| arm | names crossing | `ANTHROPIC_API_KEY` in the child | host secret present |
| --- | --- | --- | --- |
| shipped | 24 | `<unset>` | no |
| `network.credentials = ["anthropic"]` | 40 | 64 hex | no |
| `allow_vars += ["ANTHROPIC_API_KEY"]` | 25 | the host secret | **yes** |
| both | 40 | 64 hex, a different value | no |

The last row is the finding: an explicit grant on the name the route claims does not get the host value through. So the mediation is not a filter a widening can get behind — but it also means `check_r3`'s granted arm could no longer demonstrate what its control existed to demonstrate, since the one name it granted was the one name the route overrides. The rework grants a second name no service policy claims and asserts both halves: the unclaimed canary crosses with its host value, so default-deny is what withholds things; and the claimed one does not, so the route beats the grant. Replacing the control outright would have lost the second property.

`check_r3`'s R3 assertion itself survived untouched, because `M5c` wrote it against the canary's **value** rather than against the name `ANTHROPIC_API_KEY` being absent, on the stated grounds that M7 would plausibly set a credential under that very name. It did.

### What the plants say, including the one that says nothing

Withdrawing the route and allowing the host name through fires three of `check_j4_1`'s assertions at once — the form, the leak, and the per-session property, since two sessions handed the same host value get the same string — and takes `check_r3` with it on both its R3 assertion and the routed-name one. SC-6's project-tree search does **not** fire: the value crossed in the environment and nothing wrote it at rest, so the environment half and the at-rest half are independent and that plant exercises only the first.

Adding the grant while leaving the route in place is **inert**: `13 checks passed`. That is the suite-level confirmation of the table above, and it is why the new `check_r3` assertion is falsifiable only by removing the route.

No component-layer assertion was added. `check_j4_1` does not read the route out of the description — it asserts the substitute's form directly — so withdrawing the route is caught at the integration layer, unlike `M6a`'s third plant where the integration check read its own expectation from the description and only a component-layer mirror could see the hole.

### `credential_providers` is the wrong mechanism here, and two arms say why

The plan's `D1` assigns `claude-code` the OAuth branch, `credential_providers` + `credential_routes`. Measured, that branch is real but not usable for this feature:

- The shape is exacting. `token_endpoints` items are **objects**, not URLs — `["https://platform.claude.com/v1/oauth/token"]` gives `Profile parse error: invalid type: string …, expected struct CredentialProviderTokenEndpoint` and exit 1. The accepted form is `{host, path, response_fields}`, `response_fields` an array of `{path, kind?}` with `minItems 1`. A malformed credential arrangement therefore **refuses to start rather than starting inert**, which is a good property and the opposite of the command-line `--credential` form.
- With a correct provider and route, `ANTHROPIC_BASE_URL` is set but **`ANTHROPIC_API_KEY` stays `<unset>`** and the banner stays `net outbound allowed`. The phantom exists only once a token exchange has actually been captured, so **the OAuth branch cannot be exercised unattended**, and a check written against it would assert "every readable value is a substitute" over an empty set of readable values. That is the vacuity the plan's own control exists to prevent.
- It cannot be mocked either. `token_endpoints[].host` must be HTTPS — `http://127.0.0.1:8099` gives `Profile parse error: credential_providers.mock.token_endpoints[0].host '…' must use https` — so a loopback token server is not available, and there is no way to produce a capture without the real provider.

A `credential_store` of kind `file_json` pointing inside the project (`$WORKDIR/.agents/claude/.credentials.json`, `phantom_fields` naming `claudeAiOauth.accessToken`) *is* accepted, and nono creates the parent directory. That is worth remembering for `M7b`, because it is the mechanism that would put phantoms rather than real tokens into the agent's own credential file — which is where SC-6 bites hardest.

### Two more findings about the description form

A service name in `network.credentials` with no matching definition is **refused**: `Configuration parse error: Unknown credential service '__bogus__'. Available: ["anthropic", "gemini", "github", "gitlab", "google-ai", "openai"]`, exit 1. That **corrects `M7a`'s third criterion**, which was written from the measurement that `nono run --credential __bogus__` exits 0 and yields an unauthenticated session. The command-line form is silent; the description form is not. So an arrangement that lives in the description gets P9's visible failure from the mechanism, and the wrapper needs no validation of its own — the criterion is met by not using the flag.

The substitute carries **no `nono_` prefix**. `M1b` recorded the sandbox holding a phantom `nono_<64 hex>`; what a proxy credential route hands the child is bare 64 hex. The prefixed form presumably belongs to `credential_providers` phantoms, which no arm here got far enough to see.

### Method note

`env VAR=VAL … cmd` stops treating arguments as assignments at the first one that is not `VAR=VAL`, so every flag goes after the command name. And a probe that reads `NONO_CAP_FILE` with a `while IFS= read -r` loop gets a truncated document; if the manifest is ever needed, it has to be read after the session rather than during it.

**A plant harness must not nest `direnv exec .`.** A harness run as `direnv exec . bash .tmp/plant.sh` cannot call `direnv exec . bash scripts/validate.sh` from inside itself: the inner call dies with `.envrc is blocked. Run \`direnv allow\` to approve its content`and the layer produces no output whatsoever, which reads exactly like a layer that found nothing to say. It is already inside the environment, so it calls`bash scripts/validate.sh\` directly.

**A `sed` plant needs a guard that the edit landed.** The `allow_vars` items in `lib/confinement.nix` are indented eight spaces, not ten; a pattern written for ten matched nothing, and the run would have reported a plant that changed no behaviour as a plant that bit nothing. The harness now aborts unless `git diff` mentions the string it meant to add.

## M7b — Authenticating once serves every project, and every agent

Measured on x86_64-linux with nono 0.74.0, against the shipped `.#confinement-claude-code` — which carries `network.credentials = ["anthropic"]` since `M7a`. Every arm ran a bash probe out of the substrate printing `env -0`, with the fake `$HOME`, the config root, the ambient `XDG_STATE_HOME` and the scratch checkouts as siblings under one `mktemp -d -p "$XDG_RUNTIME_DIR"`.

### Both axes of Journey 5.1 already hold

One fake `$HOME`, one config root, one shared ambient `XDG_STATE_HOME`, two unrelated checkouts as siblings under `work/`, and `ANTHROPIC_API_KEY=sk-real-canary-4711` in the **supervisor's** environment for all three arms. The second agent is stood in for by the shipped description with `jq '.meta.name = "second-agent"'`: the same `credentialServices`, a different name, and nothing about it reading the first agent's store.

| Arm | Description | Project | `ANTHROPIC_API_KEY` in the child | Real value present |
| --- | --- | --- | --- | --- |
| alpha | shipped | `work/alpha` | `480dae4be5074f44…` | no |
| beta | shipped | `work/beta` | `6032751251cb825d…` | no |
| second | `second-agent` | `work/beta` | `e512dd0c86c0e03b…` | no |

All three exit 0, `NONO_PROXY_TOKEN` holds the identical value in each, the three substitutes are **three distinct values**, no arm produced a `credential_not_found` warning, and each session's audit record reached only its own project.

**Across projects holds because the login is the machine's, not the project's.** A second, unrelated checkout is authenticated with no further login, and nothing a project holds takes part in it.

**Across agents holds by a simpler route than `D14` describes.** A second agent needs no login of its own and reads nothing of the first agent's: it declares the same service name in its own table entry and the supervisor mints it an independent substitute. There is no authenticating agent, and no dependency between agents at all. `D14`'s outcome survives; its mechanism — capture `claude-code`'s token flow, expose it to the other two — is withdrawn, the same way `M7a` withdrew `D1`'s fork. `M7b`'s second criterion goes with it.

### Three of the six built-in services name an environment variable, and three do not

All six declared at once, with no credential variable set: exit 0, `net proxy`, and a `Proxy credential warnings:` block carrying a `credential_not_found /<service>` line for **every** one. Only three of them say what to set.

| Service | Variable it looks for |
| --- | --- |
| `anthropic` | `ANTHROPIC_API_KEY` |
| `github` | `GITHUB_TOKEN` |
| `gitlab` | `GITLAB_TOKEN` |
| `openai`, `gemini`, `google-ai` | **none named** — the warning stops at "will be denied until the credential is available" |

So at 0.74.0 three of the six cannot be fed the way `claude-code`'s is, and an agent needing one of them would have to bring a `custom_credentials` route of its own. That is `M8`'s problem and not this task's, because `opencode` and `pi` both address Anthropic. Each warning also carries keychain advice that only applies on macOS.

### An unauthenticated route is observable, which is the control M7b asks for

The same six declared, with only `ANTHROPIC_API_KEY` set: `ANTHROPIC_API_KEY` arrives as 64 hex and `GITHUB_TOKEN` and `GITLAB_TOKEN` **do not arrive at all**, with the warning block naming exactly those two. So the criterion's "a third identity that has not been authenticated must not work in the same session" is a single session's observation: the credential variable is absent and the route says so by name. `github` is the identity to use, because it is one of the three that names a variable.

### A base URL is injected per declared route whether or not a credential was found

The name delta against the shipped description, with six routes declared and nothing withdrawn: `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`, `GEMINI_BASE_URL`, `GITHUB_BASE_URL`, `GITLAB_BASE_URL` and **`GOOGLE-AI_BASE_URL`**. All the base URLs point at one shared loopback port, `http://127.0.0.1:<port>/<service>`.

Two things follow. `check_r3`'s `routed` literal grows by a base URL per declared service, and by a credential variable per service that found one. And `GOOGLE-AI_BASE_URL` is **not a valid shell identifier**: `env -0` reports it, but no shell can reference it, so a service whose name carries a hyphen produces a variable the session cannot use.

### The substitute is one token per session, not one per route

`NONO_PROXY_TOKEN` held the same 64 hex as `ANTHROPIC_API_KEY` in every arm, with six routes declared as with one. `M7a` measured the equality; this adds that the token is the session's rather than the route's, so a second route would not yield a second value to compare.

### Method note

**A probe must write its dump inside the granted workdir.** The first harness wrote `env -0` to a path outside it: every arm exited 1 with no output, which reads exactly like the mechanism refusing to start rather than like a redirection being denied.

## M7c — A stale substitute answers differently from a denied path

Measured on x86_64-linux with nono 0.74.0, against the shipped `.#confinement-claude-code`. One probe out of the substrate makes a provider request with bash's own `/dev/tcp`: there is no HTTP client in `sessionTools`, and adding one would widen every session's substrate for a check's convenience. The request is `POST <ANTHROPIC_BASE_URL>/v1/messages` with `connection: close`, and the response is read with the substrate's own `timeout` and `cat`.

### The proxy answers three different ways, and only one of them needs the internet

| What the session presents | Route's credential | Response |
| --- | --- | --- |
| the substitute this session was minted | present | forwarded upstream — `server: cloudflare`, `{"type":"error","error":{"type":"authentication_error","message":"API key is invalid."}}`, because the real value was a canary |
| a 64-hex token that is **not** this session's | present | `HTTP/1.1 401 Unauthorized`, `{"error":"Unauthorized"}`, **no upstream headers at all** |
| an empty token | present | the same 401 |
| anything | route declared, variable unset | `HTTP/1.1 503 Service Unavailable`, `{"error":"Service Unavailable"}` |
| anything | `network.credentials = []` | no `ANTHROPIC_BASE_URL` crosses, so there is no provider request to make |

The second row is R8's `Given` — a stored substitute that is no longer the one the supervisor holds — and it is answered **locally**: the reply carries none of the upstream's headers, so the check needs no internet. The first row does, which is why the check must not send the session's own substitute.

A missing credential and a stale one are **not** the same failure: 503 against 401. `M7a` read the `credential_not_found` warning as R8's observable; it is the observable for a credential that was never there, and R8 asks about one that has stopped working.

### The two messages, and the word that would have confused them

| | |
| --- | --- |
| authentication failure | `HTTP/1.1 401 Unauthorized` … `{"error":"Unauthorized"}` |
| confinement denial | `cat: <path>: Permission denied` |

They share no vocabulary. The authentication failure is carried by the status code the protocol defines for exactly this, and the denial is the operating system refusing a path — the same words `check_r1` and `check_r2` already assert on. Asserting the status **code** rather than the body is also what keeps FR-16 honest: 401 is RFC 9110's meaning and not prose upstream may reword.

The near miss is worth recording. The missing-credential warning reads "managed-credential requests on this route will be **denied** until the credential is available", so a check that keyed on the word `denied` would file an authentication failure under confinement denials.

### The 503 arm is the anti-vacuity control the check can afford

The valid-token arm cannot be in the check, so the check cannot show a provider request succeeding. What it can show is that this port does not answer 401 to everything: the same stale request, in a session whose route has no credential at all, gets 503 instead. The 401 is therefore a judgement about the token presented rather than the proxy's standing answer.

### The plant, and the knob it actually turns

`plan.md` said "collapse both failure paths onto one message **in the wrapper**". The wrapper produces neither message; the knob is the agent table's `credentialServices`. Emptied, no route exists, no base URL crosses, and every failure the session can observe is of one kind — there are no longer two messages to differ.

### Method notes

- **The environment is filtered, so a probe takes its targets as arguments.** The first version passed the outside path in `SECRET=`; the variable does not cross — `allow_vars`, which `check_r3` asserts — and the probe reported `No such file or directory` for a denial it had never attempted.
- **`/etc/shadow` is the wrong target for the denial half.** It is `0640 root:shadow`, so it says `Permission denied` outside the sandbox too. The file has to be one the harness made world-readable.
- The proxy resets the connection after the body, so the reader appends `cat: -: Connection reset by peer` to what it captured.

## M7d — What a second authentication changes, and what it does not

Measured on x86_64-linux with nono 0.74.0, against the shipped `.#confinement-claude-code`. Two authentications in one scratch project, each one the entry point followed by an `env -0` dump out of a session, with a *different* canary in the calling environment each time, against one shared `$HOME` and one shared state root.

### There is no login to run twice, so "authenticate again" is the value supplied again

`M7b` established that nothing logs in: the credential is a value in the supervisor's environment and the session is handed a substitute. Repeating that is repeating the supply. The second authentication deliberately supplies a **different** canary, because a real second login would mint a new token — so anything that remembers which login produced the state shows up as a difference rather than being masked by using the same value twice.

### The entry point writes one file, and writes it the same way both times

| Where | After the first authentication | After the second |
| --- | --- | --- |
| the project | `.agents/`, `.agents/git/`, `.agents/git/config` | byte-identical, by sha256 |
| `$HOME` | nothing beyond what the harness planted | nothing |
| `CLAUDE_CONFIG_DIR` | not created | not created |

`claude --version` exits 0 in about a second and creates no agent configuration at all. The only thing authentication leaves at rest is FR-23's create-if-absent copy of the git identity, and its content does not depend on the run that wrote it.

### Five values are session-scoped, and nothing else varies

Of the 42 environment entries that cross, exactly these differ between the two sessions:

| Value | Carried by |
| --- | --- |
| the 64-hex substitute | `ANTHROPIC_API_KEY`, `NONO_PROXY_TOKEN`, `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY` |
| the loopback authority `127.0.0.1:<ephemeral port>` | `ANTHROPIC_BASE_URL` and the four proxy variables |
| the interception session directory | `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO` |
| the browser shim directory | `BROWSER`, and one `PATH` element |
| the capability file | `NONO_CAP_FILE` |

Everything else is identical, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_TMPDIR` and the proxy exemptions included. Each of the five is a property of *a session* rather than of *an authentication*, so a check for Rep3 masks them and compares what is left. Masking with a long unique string taken from that session's own dump, rather than with a fragment like a bare port number, is what stops the mask from erasing more than it was aimed at.

### The state root is excluded, and the exclusion is D13's doing

Every session appends an audit record and a session directory under `XDG_STATE_HOME`. That is the decision D13 asked for, so two authentications leaving two records there is the feature working. The comparison is over the project and over the environment; the state root cannot be in it.

## M7e — The toolchain survives interception, and nothing else would carry it

Measured on x86_64-linux, NixOS, nono 0.74.0, from a harness running `git` out of `.#substrate-claude-code` inside a session on the shipped `.#confinement-claude-code`. The destination is this repository's own canonical remote, `https://github.com/GRBurst/agent-sandbox`, used as somewhere to talk to and never as an expected answer. Two arms, one `jq` edit apart.

### Interception is already on, and the difference is total

| observable | shipped description | `del(.network.credentials)` |
| --- | --- | --- |
| the banner's network line | `net proxy` | `net outbound allowed` |
| the five trust-bundle variables | all set, to one `intercept-ca.pem` | all `<unset>` |
| that file, read from inside | 120 `BEGIN CERTIFICATE` blocks | unreadable |
| `git ls-remote <remote> HEAD` | **exit 0**, a 40-hex object and `HEAD` | exit 128, `SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)` |

The first row is the finding that matters for the shape of the shipped environment: **the credential route is what switches interception on**, so a session that substitutes a credential is an intercepted session, and Journey 6 is not describing some future opt-in. `lib/confinement.nix` names no `allow_domain` at all, which is why `M7e`'s planted violation could not be the plain-string entry [`M7`](#m7--the-credential-surface-and-interception-measured-rather-than-reasoned) measured. The plant that carries the same meaning here is an empty `credentialServices`: the description asks for nothing to be inspected, and all four of arm 1's observables go with it.

### The host trust store does not save an unintercepted exchange, on this host

This corrects the claim in [`M1c`](#trust-in-the-inspecting-authority-does-reach-git--but-only-where-something-is-inspected) that `git` "exits 0 when nothing was inspected at all, because `/etc/ssl` and `/etc/pki` are in the bare floor and the real certificate validates fine". The directories are in the floor and the file passes a readability test, but on NixOS `/etc/ssl/certs/ca-certificates.crt` is a symlink into `/nix/store`, and the store path it resolves to is not in the session's substrate. Pointing the five variables at it produces `error adding trust anchors from file: /etc/ssl/certs/ca-certificates.crt`, the same shape of failure as pointing them at `/dev/null`.

So on this machine exit 0 *would* have discriminated, and the three-arm design is not what saves the check here. It is still the right design, because which way the unintercepted arm falls is a property of the host's `/etc` and of the substrate's closure rather than of the feature, and a check that reads exit 0 alone is reading the host.

### `ca_env_vars` is additive, so trust cannot be withdrawn from a description

Two attempts to plant the violation by editing `network.tls_intercept.ca_env_vars` both failed, and the reason is worth recording because it is a property of the mechanism rather than an accident.

| the description says | the child gets |
| --- | --- |
| `ca_env_vars = [ ]` | all five standard variables, set |
| `ca_env_vars = [ "NONO_INTERCEPT_CA_UNUSED" ]` | all five, **plus** that name, all pointing at the same bundle |

An empty list means "the defaults", and a non-empty one means "the defaults and also these". A description therefore cannot take the standard trust variables away, which is a good property — FR-17's guarantee is not something a consumer can switch off by mistake — and a bad one for anyone hunting a plant. The first attempt is also the case [`plan.md`](plan.md) warns about: the edit **did** land in the built artefact, so the artefact was inspected before the plant was believed inert.

### The bundle has to be read from inside

Confirming [`M7`](#the-trust-bundle-is-readable-from-inside-and-it-does-not-widen-the-reach) from the check's side: the intercept directory is gone once the session exits, so the probe counts `BEGIN CERTIFICATE` and `END CERTIFICATE` in pure bash while the session is alive and writes the counts out. There is no `openssl` in the substrate — the closure of `.#substrate-claude-code` has no `bin/openssl` — so "parses as a certificate" is asserted structurally at arm 1, by the delimiters balancing, and semantically at arms 2 and 3, where a real exchange either accepts the authority or does not.

## M7f — A commit needs no key, and the demand for one survives while the key does not

Measured in one session against the shipped `.#confinement-claude-code`, in a scratch checkout the real entry point had configured, with `git` and `strace` taken from the substrate.

| Arm | Result |
| --- | --- |
| ordinary commit, nothing demands a signature | exit **0**, HEAD a 40-hex object, `gpgsig` header count **0**, `git log -1 --format=%G?` = `N` |
| the same checkout asked `git config --get commit.gpgsign` | prints nothing, exits **1** — the configuration this environment wrote does not ask for a signature |
| checkout whose own `.git/config` sets `commit.gpgsign = true` | exit **128**, `git rev-list --count --all` = **0**, no HEAD. Message: `fatal: cannot exec 'gpg': Permission denied` / `error: gpg failed to sign the data:` / `fatal: failed to write commit object` |
| the same, plus `gpg.format = ssh` and a `user.signingkey` outside the boundary | exit 128 and 0 objects as well, but the message is only `error: could not create temporary file: No such file or directory` |
| `git config --list --show-origin --show-scope` inside the session | two scopes only: `global file:<project>/.agents/git/config` carrying the two identity keys, and `local file:.git/config` |

### The ssh signing format is not legible, so the check does not use it

Both signing formats refuse, and both leave nothing behind, so either would satisfy the first and third `Then`. Only the OpenPGP one satisfies the second: its message names `gpg` and says the data went unsigned, while the ssh one names a temporary file and would be read as the checkout being unwritable — which is the exact confusion `R11` exists to prevent. The check demands a signature the ordinary way and asserts the message names the act and the material, matching `sign` together with `gpg|key` rather than a string one version of the toolchain happens to emit: a host carrying no signing program at all says `cannot run gpg` instead, and that is the same refusal.

### The denial is an `execve`, so the trace is empty and that is the assertion

`gpg` is refused when it is executed, not when a file is opened, so `trace_denials` — which reads `openat` — sees nothing of it. That is not a gap: `J6.2`'s third `Then` is that nothing outside the session's reach was read in order to produce the commit, and under Landlock that is exactly an empty denial set. The paths the ordinary commit opened outside the project and the store were `/dev/null` (the `GIT_CONFIG_SYSTEM` redirection), `/etc/gitattributes` and `/etc/localtime`, all inside the granted reach.

An empty set is vacuous if nothing was traced, so the trace itself is asserted non-empty first. It is vacuous in a second way if the session never reaches outside at all, and the answer to that is the other arm: the same session, in the same run, does reach for a signing program outside the boundary and is refused. The two arms are each other's control, which is why they share a session rather than being written twice.

### The historical failures were the global file, not this

The four signing failures recorded in [`D16`](plan.md#d16) came from the host's own `~/.gitconfig`. `GIT_CONFIG_GLOBAL` erases that file for the session, so those are the case FR-24 configures away rather than the case `R11` refuses. The demand `R11` needs has to be planted in the checkout's **own** `.git/config`, where nothing this environment sets can reach it — and that is precisely the property the plant below removes.

## M8a — The refactor that had already happened

`M8a` was planned as an extraction: generalise a `claude-code`-specific wrapper into `mkConfinedAgent name`. The premise is false. `git show 7e3aea8:lib/confined-agent.nix` — the file's first commit, at `M4b` — already opens `{ pkgs, agentPkgs, agents, confinement }: name:` and resolves the agent as `agents.${name} or (throw …)`. It was never specific to one agent, so there was nothing to extract, and `M8a`'s production diff is empty.

The name differs from the plan's. The code calls it `mkEntryPoint`, in `flake.nix` and in the file's own docstring, because what it produces is the entry point rather than the agent. The plan has been corrected to that name rather than the code renamed to the plan's, since the code's name is the one three call sites already use.

The command the criterion named does not exist either. There is no `confinement.claude-code` output: a description is a **built artefact**, so it is read with `nix build --no-link --print-out-paths .#confinement-claude-code` and `jq -S`, not with `nix eval`.

### The empty diff is a tautology, so the property was measured instead

With no production change, "the description is unchanged across the refactor" is true by arithmetic and proves nothing. What the refactor exists to buy is that a name the pipeline has never seen generates a working session, so that is what was measured: a second entry was added to `lib/agents.nix` and nothing else was touched.

| Observation | Result |
| --- | --- |
| `nix eval .#agents --apply builtins.attrNames` | `["claude-code","opencode"]` |
| `nix build .#confinement-opencode` | built, `meta.name = "opencode"`, `description = "agent-sandbox confinement for opencode"` |
| `nix build .#substrate-opencode` | built — a closure of the new agent's own package, `filesystem.read` carrying 128 paths |
| `nix build .#opencode` | built, `/bin/opencode`, the name taken from the package's `meta.mainProgram` |
| the new agent's own `stateVars` | present in `set_vars` beside the shared `TMPDIR`, `XDG_*` and `GIT_CONFIG_*` |
| `nono profile validate` on the generated description | `Result: valid`, `All 18 group references valid` — the same verdict the reference agent's gets |
| `nix build .#confinement-claude-code` | the **same store path** as before the second agent existed |

So the pipeline is general in the only sense that matters: one table entry produces a description the mechanism accepts, a substrate, and an entry point under the agent's own command name, and it does so without disturbing the agent already there. The entry was then reverted; `M8c` is where `opencode` arrives with the variables and the checks that make it real.

### Every check names the reference agent, and that is a decision `M8c` inherits

Worth writing down before the other agents land: `agent=claude-code` is hardcoded in three component checks and in every integration check. That is consistent with the spec making `claude-code` the reference case, and it is not a defect today. It does mean the suite will not exercise a second agent merely because the second agent exists — `check_state_vars` and the rest read the reference name, not the table. `check_j5_1` is the exception, and deliberately so: it derives its sessions from `builtins.attrNames agents`, so it is the one check that grows on its own. `M8c` and `M8d` have to decide, per property, which of the others should follow it rather than assuming they already do.

## M8b — The subagent and lock paths, and why the background service stays refused

Spec Risk 12 names the subagent and lock paths as the ones that resolve the configuration root a second time, and `M1g` had only ever driven a one-turn session. This is what the paths beyond it do.

### A subagent path exists that needs no credential and no terminal

`claude agents --json` is documented as "Print active sessions (interactive and background) as a JSON array and exit (for scripting; does not require a TTY)", and it behaves that way: exit 0 and `[]` with an empty throwaway home, with or without the confinement, with or without a key. `claude -p --bg` is refused by claude itself, with a message that explains the conflict rather than a stack trace. `claude --bg '<task>' </dev/null` is the real spawn, and unconfined it exits 0 without a credential and without a terminal.

Relocated, the background spawn writes all of this under `$CLAUDE_CONFIG_DIR` and nothing at all into `$HOME`:

| what appears | where |
| --- | --- |
| `.claude.json`, `backups/` | the relocated root |
| `daemon/auth/<id>.tokens.json`, `daemon/control.key`, `daemon/dispatch`, `daemon/roster.json` | the relocated root |
| `daemon.lock`, `daemon.log`, `daemon.status.json` | the relocated root |
| `jobs/<id>/state.json`, `jobs/<id>/tmp` | the relocated root |

### The ten silent variables stay silent, and setting them is not free

Eight of the ten candidates `M1g` found inert — `CLAUDE_TMPDIR`, `CLAUDE_PROJECT_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `CLAUDE_CODE_PLUGIN_CACHE_DIR`, `CLAUDE_CODE_PLUGIN_SEED_DIR`, `CLAUDE_CODE_ADDITIONAL_DIR`, `CLAUDE_SKILL_DIR`, `CLAUDE_CODE_DEBUG_LOGS_DIR` — were each pointed at an empty scratch directory of its own and a background spawn plus a session listing were run. **Every one received zero entries.** `$HOME` and `XDG_CONFIG_HOME` stayed empty. The paths a one-turn session never reaches still route everything through the configuration root.

That settles the question `M1g` left open, and settles it the other way. `M1g` wrote that "the cost of setting a variable that governs nothing is zero and the cost of missing one is an escape", and both halves are wrong here:

- **`CLAUDE_JOB_DIR` is an output, not an input.** Claude sets it itself when it spawns a background session — `{...e.env, CLAUDE_CODE_SESSION_KIND: "bg", CLAUDE_BG_BACKEND: "daemon", CLAUDE_JOB_DIR: t}` — and `dk()` derives a **job identity** from its basename, ungated by the background-session test that guards most other readers. Setting it from outside hands the agent a fabricated identity for a job that does not exist.
- **`CLAUDE_SECURESTORAGE_CONFIG_DIR` is worse set than unset.** `mK()` reads `let e = env.CLAUDE_SECURESTORAGE_CONFIG_DIR; if (e !== void 0) return (e || join(homedir(), ".claude")); return Tn()`. Unset, it uses the relocated root. Set to the empty string, it falls back to the home. A variable whose *presence* switches on a home fallback is not free.

So the ten stay unset, and the criterion's other half — "any it found documented but absent from the binary is not set" — does not arise for `claude-code`: all thirteen candidates are present in the 2.1.237 payload. That was `pi`'s case in `M1d`.

### The surviving fallbacks all point at the home, which is already denied

The payload resolves the configuration root a second time in several places, and every one of them falls back to the home rather than to the relocated root:

| expression | fallback |
| --- | --- |
| `sQo()`, the IDE lock search list | starts at `join(configRoot, "ide")` and, **when `CLAUDE_CONFIG_DIR` is set**, *appends* `join(homedir(), ".claude", "ide")` |
| `Kt()`, the subprocess session mirror | `join(CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude"), "projects")` |
| `Bqy()` | `join(CLAUDE_CONFIG_DIR \|\| homedir(), ".claude<suffix>.json")` |
| `zRy()` | `SELF_HOSTED_RUNNER_HOST_CONFIG_DIR \|\| CLAUDE_CONFIG_DIR \|\| join(homedir(), ".claude")` |

Relocation *adds* the first of these rather than removing it. That is the shape spec Risk 12 warned about, and it is why the criterion asks for each surviving fallback to be either confined by other means or registered. Here it is the first: the built description carries only `allow` and `read` under `filesystem`, and no string anywhere in it matches `\.claude`, so every one of these paths is denied by the boundary itself. No registry entry is warranted — but the argument is worth nothing unless the check proves it, which is what the extended `check_j2_1` and its plant do.

Contention was measured too, since a lock is the one thing that might reach for a different directory under pressure: eight concurrent `claude agents --json` runs against one relocated root left `$HOME` **completely empty**, produced no stderr at all, and left no surviving `*lock*` or `ide` entry anywhere. `.claude.json.lock` is transient and lives under the configuration root.

### The background service is refused, and the grant that would allow it costs too much

Inside the confinement, `claude --bg` fails — exit 1 after the 45-second timeout, with `Couldn't reach the background service`. Nono's epilogue names the cause exactly: `IPC denial: 448 Unix socket operations blocked`, on `connect` and `bind` against `/tmp/cc-daemon-1000/<hash>/control.sock`.

The path is hardcoded in the payload:

```js
// /tmp is fixed; only Termux differs, and TMPDIR is never consulted
join("/tmp", `cc-daemon-${uid}`, sha256(resolve(configRoot)).slice(0, 8))
```

The per-project component is a digest of the configuration root, so two projects do not collide and FR-8 is not at risk from sharing. But the directory is outside the project, and nono's own help gives the reason not to grant it: `--allow-unix-socket-bind` "implies `--allow` on the parent directory so the kernel can create the socket file", and `--allow-unix-socket-dir-bind` is "non-recursive on macOS and future Linux AF_UNIX mediation; **current Linux Landlock filesystem fallback is recursive**". Granting it would put a recursively writable directory outside the project into the reach, for a daemon that outlives the session — which is the precise shape FR-2's equality-not-containment and the registry's justification fields exist to refuse.

So the background service stays refused. The refusal is clean: `$HOME` is untouched, everything claude does manage to write stays under the relocated root, and the interactive and listing paths are unaffected. It is recorded as a known limitation rather than granted away, and `check_j2_1` deliberately does not assert the spawn's exit status — only that the attempt left its trace inside the boundary — so the check does not break on the day the mediation stops being recursive.

## M8c — `opencode` needs no variable of its own, and takes its credential from the environment

Measured against `opencode 1.18.18`, `/nix/store/na3vfbmg09qm2dyd622xnghnwrg1c91k-opencode-1.18.18`.
Both of the premises `M8c` was written on turned out to be wrong, in the same direction as `M8a`'s and `M8b`'s: the task expected agent-specific work and the measurement found there was none to do.

### Nine roots, and five variables that place eight of them

`opencode debug paths` answers with nine roots and needs no terminal. Run twice — once with nothing but `$HOME` set, once with the four `XDG_*` roots and `TMPDIR` pointed into a scratch tree:

| root | `$HOME` only | roots redirected |
| --- | --- | --- |
| `home` | `$HOME` | `$HOME` — **unchanged, because this root *is* `$HOME`** |
| `data` | `$HOME/.local/share/opencode` | `$XDG_DATA_HOME/opencode` |
| `log` | `$HOME/.local/share/opencode/log` | `$XDG_DATA_HOME/opencode/log` |
| `repos` | `$HOME/.local/share/opencode/repos` | `$XDG_DATA_HOME/opencode/repos` |
| `bin` | `$HOME/.cache/opencode/bin` | `$XDG_CACHE_HOME/opencode/bin` |
| `cache` | `$HOME/.cache/opencode` | `$XDG_CACHE_HOME/opencode` |
| `config` | `$HOME/.config/opencode` | `$XDG_CONFIG_HOME/opencode` |
| `state` | `$HOME/.local/state/opencode` | `$XDG_STATE_HOME/opencode` |
| `tmp` | `/tmp/opencode` | `$TMPDIR/opencode` |

Eight of the nine follow the five roots `M6a` already placed under the working directory, so `opencode` needs no relocation variable of its own and the criterion asking for one had nothing to ask for.
The ninth is `$HOME` itself, which no variable can move; the check asserts it lies *outside* the project instead, and the session's denial is what keeps it honest.

The reach was confirmed by writing rather than by asking: `opencode models` creates `cache/opencode/models.json`, `config/opencode/opencode.jsonc`, `config/opencode/.gitignore`, `data/opencode/opencode.db{,-shm,-wal}`, `data/opencode/log/opencode.log` and `state/opencode/locks/<sha1>.lock/{heartbeat,meta.json}` — every one under a redirected root, with `$HOME` receiving nothing.

`M8e` recorded that reading the binary for variable names "yielded nothing because the bundle is compiled". That is wrong: `strings` yields **84** distinct `OPENCODE_*` names, led by `OPENCODE_SERVER_PASSWORD`, `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT`, `OPENCODE_CONFIG`, `OPENCODE_DISABLE_PROJECT_CONFIG`, `OPENCODE_PURE`, `OPENCODE_DB`.
It is the conclusion that survives, by a different route: **not one of the 84 moves a root.** `OPENCODE_CONFIG_DIR` adds a directory to a search list rather than moving the config root. Occurrence still fails to predict behaviour; here it fails by naming a great deal that governs something other than location.

### The base URL is a variable, and the route already exports it

The task expected the mediated route to need a file this environment writes, via `provider.<id>.options.baseURL`. The agent reads both halves out of its environment:

```js
let q = pG(dG({ settingValue: Q.baseURL, environmentVariableName: "ANTHROPIC_BASE_URL" })) ?? "https://api.anthropic.com/v1"
constructor({ baseURL: $ = z8("ANTHROPIC_BASE_URL"), apiKey: X = z8("ANTHROPIC_API_KEY") ?? null, … })
```

Config wins where it is set, the environment is the documented fallback, and the route injects exactly that pair. So `credentialServices = [ "anthropic" ]` on the entry is the whole of it, and no configuration file is written.

`opencode providers list` is the observable, credential-free and terminal-free. Without a credential it reports the `auth.json` path and `0 credentials`. With one it reports `0 credentials` **and** a second block:

```text
┌  Environment
●  Anthropic  ANTHROPIC_API_KEY
└  1 environment variable
```

Both halves matter and the check asserts them separately: the `Environment` block is the credential arriving by the route, and `0 credentials` is nothing having been read from a store — which is D14's half, since a grant on the other agent's state is exactly what this is meant to rule out. An ANSI escape sits between `Anthropic` and the variable name, so the match has to be `Anthropic.*ANTHROPIC_API_KEY`.

### One variable is set, and two that look free are not

Three gates were decompiled and all three are real: `OPENCODE_DISABLE_AUTOUPDATE` returns early from the startup update check; `OPENCODE_DISABLE_MODELS_FETCH` gates both `ModelsDev.populate` and a background fetch repeating every 60 minutes; `OPENCODE_DISABLE_LSP_DOWNLOAD` sits beside `OPENCODE_DISABLE_EXTERNAL_SKILLS` in the same option record.

Only the first is set, on `claude-code`'s P8 reasoning: Nix owns the version, and an agent that updates itself is not the agent this description was written against.
The other two are deliberately left alone. What they gate lands in the project's own cache and bin roots, so neither is a confinement concern; they are FR-22 concerns belonging to the extension work. Setting them here would repeat exactly the fallacy `M8b` corrected — that a variable which changes nothing costs nothing.

### The check that was needed already existed, for one agent

`M8c` first added `check_state_vars` at the unit layer, asserting that every `stateVars` value lies under the working-directory placeholder. It was then deleted: `check_confinement_validates` already made that assertion, with the same separator rule and the same `DISABLE_AUTOUPDATER=1` example — but opened `local … agent=claude-code`, so the plan's description of it as "a property over the agent table" was drift.

The fix was to make the description true rather than to add a second copy of it: the check now reads the table with `nix eval --json '#agents' --apply builtins.attrNames`, loops it, and names the agent in every failure. `opencode` is covered by construction, and `M8c` added no check of its own at that layer. The plant that proves it is planted on the second agent, which the check was never written for — see the planted-violations table.

The two plants against `check_opencode` are recorded there too. The second is worth reading for its surprise: removing a root's relocation does not make `opencode` write to `$HOME`, it makes `opencode` die with `EACCES` before it can answer. Relocation for this agent is load-bearing rather than tidying, and its failure mode is refusal rather than leakage — the mirror image of `claude-code`, which reached `$HOME` only once the plant also granted the fallback.

One misleading detail worth knowing when reading a failure: nono's epilogue said `No path denials were observed during this session. The failure may be unrelated to sandbox restrictions.` It was entirely related. The denial was an `openat` inside the agent's own error handling rather than a tracked path denial, so nono's own accounting did not see it.

## M8d — `pi` needs two variables, and FR-22 is not the network's doing

Measured against `pi 0.84.2`, `/nix/store/bjgyqm88nc2v0bl2cjbg0lklprnwmmlz-pi-0.84.2` — the same version `M1d` read, so its findings carry over and only the ones below are new.

### The relocation half needed no work, and one documented variable is a trap

`M1d` had already settled it: `PI_CODING_AGENT_DIR` occurs exactly once in the binary, as the sole override of a `$HOME/.pi/agent` default, and `PI_CODING_AGENT_SESSION_DIR` is documented but absent from the code. Both hold. Confirmed by writing: a real session leaves `auth.json`, `models-store.json` and `sessions/<mangled-cwd>/<timestamp>_<uuid>.jsonl` under the relocated root and nothing under the home directory.

The trap is `PI_PACKAGE_DIR`, which `docs/environment-variables.md` describes as "override the package directory, useful for Nix/Guix store paths". It reads like the mechanism FR-22 wants and is nothing of the kind: it defaults to `dirname(process.execPath)` and is consumed by `getThemesDir()` and its siblings, so it names `pi`'s **own** installation — themes, assets, bundled docs. Setting it moves no extension and misdirects the agent's assets. It is deliberately unset, and this is written down because the documentation invites the mistake.

### The credential arrives the same way it does for `opencode`, so `D14`'s written file is withdrawn for both

The task expected `providers.<id>.baseUrl` in a `models.json` this environment writes. The bundled Anthropic SDK reads both names in its own constructor defaults:

```js
constructor({ baseURL = readEnv("ANTHROPIC_BASE_URL"), apiKey = readEnv("ANTHROPIC_API_KEY") ?? null, authToken = readEnv("ANTHROPIC_AUTH_TOKEN") ?? null, ...opts } = {})
```

`docs/providers.md` agrees, documenting a provider-to-variable table whose Anthropic row is `ANTHROPIC_API_KEY`. So `credentialServices = [ "anthropic" ]` is the whole entry again and no file is written — the third agent in a row for which that is true, which is why the correction is made against [`D14`](plan.md#d14) rather than against this task.

`pi auth check --provider anthropic --json --credentials` is a better observable than either of the other two agents offer, because it prints the credential the agent is holding rather than the name of the variable it came from:

| State | Exit | Payload |
| --- | --- | --- |
| credential present | 0 | `{"status":"ready","provider":"anthropic","authType":"api_key","credentials":"<the value verbatim>"}` |
| no credential | 1 | `{"status":"not_ready","provider":"anthropic","reason":"credentials_not_configured"}` |
| relocation dropped | 2 | `{"status":"invalid","provider":"anthropic","reason":"invalid_state"}` |

So the substitute is **read** rather than inferred: the check asserts the 64-hex form on the value the agent itself reports, and asserts the real canary appears in neither stream. The third row is the plant, and it is a distinct payload rather than a distinct exit status alone.

### `PI_OFFLINE` bites, but only against a declared package

`M1d` recorded this variable as gating "startup operations only" and could not see it do anything, because it was measured with nothing declared. With `{"packages":["npm:left-pad"]}` in `$PI_CODING_AGENT_DIR/settings.json`, unconfined, the two arms are plainly different:

| `PI_OFFLINE` | `pi list` | The relocated root afterwards |
| --- | --- | --- |
| `1` | `User packages:` / `npm:left-pad`, exit 0 | no `npm/`, no network |
| unset | the same listing, after `added 1 package, and audited 2 packages in 4s` | `npm/node_modules/left-pad` |

Two details that decide how the check is written. `pi list` reads the `packages` array from the **user** settings file the relocated root holds; a project-local `.pi/settings.json` is ignored until the project is trusted, and a declaration planted there produced `No packages installed.` and no install in either arm. And the listing has to be asserted, not just the absence of `node_modules`: a session asked to install nothing installs nothing, so without that control the FR-22 assertion is vacuous.

### The boundary stops the fetch as well, and that is a second guard rather than the same one

With `PI_OFFLINE` removed **inside** a confined session, the startup install is attempted and killed:

```text
EACCES: permission denied, posix_spawn 'npm'
spawnargs: [ "install", "left-pad", "--prefix", "<proj>/.agents/pi/npm", "--legacy-peer-deps" ]
```

`sessionTools` carries no `npm` and no `node`, so the substrate the session runs cannot spawn the installer. The two guards are independent: the variable stops the attempt, the substrate stops the attempt from succeeding, and either alone satisfies FR-22 for the declared-package path.

### What FR-22 cannot be, measured: egress from a confined session is unrestricted

Worth recording because it is the obvious wrong reading of FR-22. The built description's `network` block is exactly `{"credentials":["anthropic"]}` — no host allow list and no deny list. Inside a session that means:

| Probe | Result |
| --- | --- |
| `bash -c 'exec 3<>/dev/tcp/1.1.1.1/443'` | `connect: Permission denied` — raw TCP is denied |
| `git -c http.proxy="$https_proxy" ls-remote https://github.com/npm/cli HEAD` | a real SHA — arbitrary HTTPS through the injected proxy succeeds |

The session's environment carries `http_proxy`/`https_proxy` as `http://nono:<token>@127.0.0.1:<port>`, `NODE_USE_ENV_PROXY=1`, `NODE_EXTRA_CA_CERTS` pointing at the intercept authority, and `ANTHROPIC_BASE_URL` at the mediated route — which is also, incidentally, how the credential reaches the agent with no file written.

So the boundary mediates egress rather than restricting where it goes, and **FR-22 is not enforceable against a session that decides to fetch.** A consumer who types `pi install npm:something` inside a session will reach the registry. That is exactly how [`spec.md`](spec.md) already frames the requirement — "verified as the absence of a thing" — and the thing whose absence is verified is *this environment* fetching, not the session being unable to. The unrestricted proxy egress belongs in the handbook's known drift rather than in a footnote here.

### The consumer path is inside the session, not outside it

`M8d`'s fourth criterion assumed provisioning an extension had to happen "outside the confined entry point". Measured from **inside** a confined session, it does not, as long as the source is a local path:

```text
$ pi install ./vendor/my-ext
Installing ./vendor/my-ext
Installed ./vendor/my-ext
```

`.agents/pi/settings.json` gains `{"packages":["../../vendor/my-ext"]}`, `pi list` resolves it to the vendored directory, and no `node_modules` is created. `docs/packages.md` explains both halves: local paths "are added to settings without copying", and are "resolved against the settings file they appear in" — so the recorded path is relative and a moved or cloned checkout still resolves it. That is the route the handbook documents, and it is the one that keeps what arrives inside the checkout, under version control, and out of the registry.

## M8e — Where each agent reads its declarative extensions from

All three agents are measured: `opencode` 1.18.18 through its own `debug` subcommands, `pi` 0.84.2 and `claude-code` 2.1.237 through `strace`.

An earlier attempt at the other two failed because the measuring session was itself confined and got `Permission denied` on `~/.claude`, `~/.config/pi` and `~/.pi`.
That was the wrong instrument for the question.
Enumerating the locations an agent *attempts* to read does not need the host's real dotfiles at all: run the raw package unconfined against a scratch `HOME`, plant a fixture in every candidate root, and trace the syscalls.
A denied root and an empty root then stop looking alike, because the trace records the attempt either way.

The `opencode` half below was measured against its own documentation at `opencode.ai/docs/skills` and `/docs/config`.

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

Reading the binary for variable names appeared not to be available for this agent, `strings -a` over the resolved `opencode` for `OPENCODE_[A-Z0-9_]+` seeming to yield nothing because it is a compiled bun bundle. [`M8c`](#m8c--opencode-needs-no-variable-of-its-own-and-takes-its-credential-from-the-environment) found otherwise — the bundle carries 84 distinct names — so the sentence stands only as a warning that none of them relocates a root, not as a claim that they are unreadable.

### Method notes

- `opencode debug skill` is the enumeration instrument of choice, but it reports what the agent **resolved**, not every path it tried.
  A root that is denied and one that is empty look the same.
  Enumerating the locations an agent *attempts* still needs `strace -f -e trace=openat`, which is how the other two agents were measured.

- **An agent has to be given work before it looks for extensions.** `pi --list-models` and the equivalent cheap invocations produce 343 trace lines and touch almost nothing; a print-mode run (`-p 'hi'` with a syntactically valid but wrong `ANTHROPIC_API_KEY`) produces around a thousand for `pi` and nearly eight thousand for `claude-code`, because discovery completes before the request is sent and the request then fails with a 401.
  The 401 is the signal that discovery ran to completion, so it is the instrument working rather than the measurement failing.

- **Plant a fixture in every candidate root, not only the ones expected to win.** Dedup, precedence and trust gates are all invisible when only one root is populated, and each of the three findings below about ordering came from a root that had a file in it.

### `pi` — one variable moves the global surface, and the project surface is behind a trust gate

Four declarative surfaces, each with a global root under `$PI_CODING_AGENT_DIR` and a project root under `.pi/`: `skills/`, `prompts/`, `themes/`, `extensions/`.
Measured with fixtures in all eight, plus `$HOME/.agents/skills` and `PROJ/.agents/skills`, in two arms:

| arm | roots read |
| --- | --- |
| default (project untrusted) | the four global roots, and `$HOME/.agents/skills` |
| `-a` (project trusted for the run) | the same, **plus** the four `.pi/` roots and `PROJ/.agents/skills` |

Three things follow.
`PI_CODING_AGENT_DIR` moves the whole global surface, which is the same relocation `M8d` already relies on for state — one variable, no per-surface variable, and nothing left behind under `$HOME`.
The trust gate is real and observable rather than documented-only: an untrusted project's `.pi/extensions/*.ts` is never opened, while the *global* extensions load in an untrusted project regardless.
And `$HOME/.agents/skills` is read **`$HOME`-relative**, so it is `pi`'s copy of the hazard [D17](plan.md#d17) exists to contain, identical in shape to `opencode`'s.

`pi` probes no `~/.claude` or `~/.codex` root of its own.
Its documentation presents those as sanctioned *entries for the settings `skills` array*, which is a different thing: something a consumer writes down, not something that arrives.

Extensions are TypeScript, auto-discovered from `{global,.pi}/extensions/{*.ts,*/index.ts}`, loaded in-process through **jiti**, and able to register tools, commands and providers and to intercept every tool call.
That is `opencode`'s `plugin/` hazard again, and `FR-26`'s reason for keeping executable extensions out of the authoring surface holds for `pi` unchanged.
Measured detail that matters under confinement: **jiti compiles to `$TMPDIR/jiti/`**, so it honours the redirection and extension loading works inside a session; with `TMPDIR` unset it compiles to `/tmp/jiti/` and fails `EACCES`, which is what the environment setting `TMPDIR` inside the project already prevents.

The extra-root mechanism is the settings arrays — `skills`, `prompts`, `extensions`, `packages` — each taking files or directories, resolved relative to the settings file they appear in.
It covers every surface, unlike `opencode` where `OPENCODE_CONFIG_DIR` covers four of five.
CLI equivalents exist for one-off use (`--skill`, `--prompt-template`, `-e`), all repeatable and all additive even against `--no-skills` or `--no-prompt-templates`.
An extension may also contribute `skillPaths`, `promptPaths` and `themePaths` at run time through the `resources_discover` event, which means the executable surface can enlarge the declarative one.

### `pi` ignores `ANTHROPIC_BASE_URL`, which corrects [D14](plan.md#d14) and `M8d`

Two arms under `strace -f -e trace=connect`, one with the variable unset and one with it set to `http://127.0.0.1:9/v1` — a port nothing listens on, so redirection would be unmissable.
Both connected to `160.79.104.10:443` and both returned the real API's `401 {"type":"error","error":{"type":"authentication_error","message":"API key is invalid."}}`.
`pi` passes an explicit `baseUrl` from its own provider registry, which overrides the bundled SDK's `readEnv("ANTHROPIC_BASE_URL")` default.

So `M8d`'s claim that `pi` picks the mediated base URL up from the environment is **false**, and only `ANTHROPIC_API_KEY` crosses.
This does not change what the environment declares — `credentialServices = [ "anthropic" ]` is still the whole of it — but it changes *why it works*: for `pi`, mediation rests on nono's intercepting proxy in front of the real host, not on the agent being pointed somewhere else.
The two mechanisms are not interchangeable, because the proxy route depends on `NODE_EXTRA_CA_CERTS` and the interception directory, and `M1c` already recorded that interception is skipped when that directory cannot be created.

### `claude-code` — one variable moves everything, and the hazard is the ancestor walk

`CLAUDE_CONFIG_DIR` is the broadest single relocation of the three agents.
Diffing a run with it set against one without: around 84 paths move out of `~/.claude/`, **nothing is left behind under `$HOME`**, and `~/.claude.json` moves too, becoming `$CFG/.claude.json`.
What moves covers the authoring surface (`skills/`, `agents/`, `commands/`, `output-styles/`, `rules/`, `themes/`, `workflows/`, `settings.json`), the executable surface (`plugins/` with `installed_plugins.json`, `known_marketplaces.json`, `cache/`, `synced/`) and every state and credential root (`.credentials.json`, `projects/<mangled-cwd>/`, `sessions/`, `todos/`, `logs/`, `statsig/`, `shell-snapshots/`, `file-history/` and the rest).
One variable for the whole global surface is better than `opencode`, where skills escape `OPENCODE_CONFIG_DIR`, and better than `pi` only in that it also carries state.

**`claude-code` reads no `.agents/` root at all.**
The only `SKILL.md` files opened were `~/.claude/skills/*/SKILL.md` and `PROJ/.claude/skills/*/SKILL.md`; `$HOME/.agents/skills` has zero mentions in either arm, and a fixture at `PROJ/.agents/skills` was never opened.
The `.agents/…` entries that do appear in the trace are `.git`, `.gitignore`, `.ignore` and `.rgignore` probes from the agent's file walk, not discovery — a trap worth naming, because grepping the trace for `.agents` suggests the opposite of what happened.
So the cross-agent `~/.agents` convention is honoured by two of the three, and a surface declared there is invisible to `claude-code`.

**The hazard here is the ancestor walk.**
At every ancestor of the working directory up to `/` — measured through the scratch project, `.tmp/m8e2`, `.tmp`, the repository root, `hivemind`, `projects`, `/home/pallon`, `/home` and `/` — the agent probes `CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md`, `.claude/rules` and `.mcp.json`.
The repository root's `AGENTS.md` was genuinely read this way.
So an authoring surface *and* an MCP server declaration can arrive from a directory nobody named, including `$HOME`.
Inside a confined session the working directory is the project root and every ancestor is denied, so this fails closed — but it fails closed by the boundary, not by the agent, which is exactly the class of thing `check_j8_2`'s set equality exists to keep honest.

**`/etc/claude-code/` is a third kind of root**, neither `$HOME`- nor XDG-relative: probed for `managed-settings.json`, `managed-settings.d`, `managed-mcp.json`, `CLAUDE.md` and `.claude/{skills,agents,commands,output-styles,rules}`.
No variable moves it.
Measured inside a confined session: the profile's `filesystem.allow` is `[]`, `filesystem.read` holds store paths only, and `groups.include` is `[]`, so `ls /etc` exits 2 and `/etc/passwd` cannot be read.
`/etc/claude-code` is therefore unreachable and `FR-26` holds here by construction rather than by declaration.
The banner's "+ 34 system/group paths" are not `/etc` entries.

The XDG- and `TMPDIR`-derived paths all follow the redirection: `$XDG_CONFIG_HOME/anthropic/{active_config,configs/default.json}`, `$XDG_STATE_HOME/claude/locks`, `$XDG_CACHE_HOME/claude-cli-nodejs/<mangled-cwd>/`, `$XDG_CACHE_HOME/claude/staging`, `$XDG_DATA_HOME/claude/versions`, `$TMPDIR/claude-<uid>/`.
Project-relative: `.claude/{skills,agents,commands,output-styles,rules,workflows,worktrees}`, `.claude/{settings.json,settings.local.json,scheduled_tasks.json,CLAUDE.md}`, `.mcp.json`, `CLAUDE.md`, `CLAUDE.local.md`.
Two hardcoded absolute paths are of no consequence and are denied: `/home/claude/.claude/remote/{.oauth_token,.session_ingress_token}`.

### The answer, as one table

Every location, classified as `FR-25` asks — an authoring surface that can be lent read-only, or an executable extension that `FR-26` excludes — with the redirection each one obeys.

| agent | location | kind | moved by |
| --- | --- | --- | --- |
| all three | project-relative roots (`.opencode/`, `.pi/`, `.claude/`) | authoring | nothing; inside the workdir already |
| `opencode` | `~/.config/opencode/{agent,command,skills,prompts,modes,themes}` | authoring | `XDG_CONFIG_HOME`, and `OPENCODE_CONFIG_DIR` for all but skills |
| `opencode` | `~/.config/opencode/plugin(s)`, `.opencode/plugin(s)/*.ts` | **executable** | as above |
| `opencode` | `~/.agents/skills`, `~/.claude/skills` | authoring | **nothing — `$HOME`-relative** |
| `pi` | `$PI_CODING_AGENT_DIR/{skills,prompts,themes}` | authoring | `PI_CODING_AGENT_DIR` |
| `pi` | `$PI_CODING_AGENT_DIR/extensions`, `.pi/extensions` | **executable** | `PI_CODING_AGENT_DIR` / workdir |
| `pi` | `~/.agents/skills` | authoring | **nothing — `$HOME`-relative** |
| `claude-code` | `$CLAUDE_CONFIG_DIR/{skills,agents,commands,output-styles,rules,themes,workflows}` | authoring | `CLAUDE_CONFIG_DIR` |
| `claude-code` | `$CLAUDE_CONFIG_DIR/plugins` | **executable** | `CLAUDE_CONFIG_DIR` |
| `claude-code` | every ancestor's `CLAUDE.md`, `.claude/rules`, `.mcp.json` | authoring, and `.mcp.json` reaches further | **nothing — walks to `/`** |
| `claude-code` | `/etc/claude-code/**` | both | **nothing — absolute** |

Two rows carry the whole risk, and they are the two that no variable moves: `$HOME`-relative roots for `opencode` and `pi`, the ancestor walk for `claude-code`.
Those are the paths along which an extension can arrive in a session that declared nothing, and they are why `check_j8_2` asserts the undeclared case as a set equality instead of trusting that nothing was granted.
The rest are moved by exactly one variable per agent, all of which the agent table already sets.

The extra-root mechanism, per agent, and whether it covers the whole surface:

| agent | mechanism | covers |
| --- | --- | --- |
| `opencode` | `skills.paths` configuration key | skills only; `OPENCODE_CONFIG_DIR` covers agents, commands, modes, plugins and **not** skills |
| `pi` | settings arrays `skills`, `prompts`, `extensions`, `packages` | every surface |
| `claude-code` | none found | — the only lever is `CLAUDE_CONFIG_DIR`, which *moves* the root rather than adding one |

`claude-code` having no additive mechanism is the finding that constrains `M8f` and `M8g` most: for that agent, "declare an extra authoring surface" and "relocate the only global surface" are the same operation, so a declared surface and the agent's own state cannot be separated by pointing at them independently.

### A gap this session cannot close

Whether a real model request succeeds through the mediated route cannot be measured from here, because no credential is resolvable in this session at all: `ANTHROPIC_API_KEY` arrives **empty** with nono's `Credential not found for route 'anthropic'` warning, and the checks only work because they seed a fake host key that nono replaces with a 64-hex placeholder.
`curl` is not an escape hatch either — the substrate grants the `curl` package's default output while `bin/curl` lives in its separate `-bin` output, so the binary is absent.
No check in the suite makes a live model call, and none can without a real host credential.
That is a coverage gap for `M9` and the handbook rather than something `M8e` can resolve.

## M8f — The declared surface, and the two instruments it needed

The design `M8e` left open is settled here, and every part of it was measured before it was written.

### `claude-code` is coverable after all, by symlinking the children

`M8e` recorded that this agent has no additive extra-root mechanism, which looked like SC-9's "name the uncovered location" was the only answer for it.
It is not.
Unconfined, with `CLAUDE_CONFIG_DIR` pointed at a scratch root, a symlink `$CFG/skills/hostskill -> $RO/hostskill` over a `chmod -R a-w` target is followed and read: `openat(…/cfg/skills/hostskill/SKILL.md", O_RDONLY|O_NOCTTY|O_LARGEFILE)` succeeds, with `statx` reporting `S_IFLNK|0777` on the link, `S_IFDIR|0555` on the target and `S_IFREG|0444` on the file.

The hazard `M8e` measured — that the agent writes `manifest.json`, `.staging`, `synced` and `.trash` *inside* `skills/` — is avoided rather than met, because those writes land at the level **above** the links, which is the project's own writable directory.
Symlinking the `skills/` directory itself at a read-only root would have broken them; symlinking each child does not.

### The grant has to be argv, not environment

`nono run`'s filesystem flags are `--allow` (read+write), `--read` and `--write`, plus their `--*-file` forms.
Only `--allow` carries an environment form (`NONO_ALLOW`).
So a *read-only* grant cannot be declared the way `D17` assumed the widening channel would work, and the entry point has to put `--read` on the argv it builds.
There is also no `--set-env`/`--env` flag anywhere in `nono run --help`, which rules out the neater-looking alternative of pointing `opencode` with `OPENCODE_CONFIG_CONTENT`: a run-time value cannot cross the boundary, since nono carries variables only through the profile's build-time `set_vars` or its fixed `allow_vars` pass-through list.

Measured in real confined sessions, against a symlink pointing out of the project:

| grant | result |
| --- | --- |
| none | read through the symlink **denied** — so the grant is load-bearing and the control is not vacuous |
| `--read <parent>` | read succeeds |
| `--read <the directory itself>` | read succeeds — the enumerated, never-ancestor grant `D17` requires is implementable |
| `--read …` then a write | **denied**, surface byte-identical |
| `--allow …` then a write | **succeeds**, surface tainted |

The last two rows are why the check asserts the write denial by attempting it rather than by comparing the surface afterwards: with a read-only grant nothing in a normal session tries to write there, so the comparison alone would pass under a read-write grant too.

### `strace -f -o <file>` is the wrong instrument, and it fails intermittently

The first `check_j8_1` was flaky — a different subset of agents reported a missing read on each run, and once it passed outright.
The cause is not the sandbox and not the agents.
`strace -f` writing to a single file multiplexes every traced process into one stream, so a syscall interrupted by another process is split into `<unfinished ...>` and `<... resumed>` lines.
The path then no longer shares a line with its return value, and any assertion of the form "this path, and this call succeeded" fails on scheduling alone.

`-ff -o <prefix>` writes one complete file per process; concatenating them afterwards gives a stream where every line is whole.
Four consecutive runs passed after the change.
This is a trap for any future check that greps a trace for a call *and* its result, which is most of them.

A second, smaller trap in the same assertion: an `O_PATH` open of the link and of the target directory succeeds **without** any grant, because `O_PATH` needs no read permission.
Only a non-`O_PATH` successful open distinguishes a granted surface from a denied one.

### What the entry point does, and what it leaves behind

Verified across all three agents in real confined sessions, with pre-existing consumer settings in place:

- Declared, the surface arrives — `claude` gains one symlink per skill under `.agents/claude/skills`, `opencode` gains `.skills.paths` in `.config/opencode/opencode.json`, `pi` gains `.skills` in `.agents/pi/settings.json` — and every unrelated key in those files survives.
- Run twice, nothing changes (P8, by checksum).
- Withdrawn, the files return **exactly** to the consumer's own content, with no empty `"skills": {}` left behind: the links are pruned before they are planted, and the jq filter deletes the key and then any container it emptied on the way.

The last point is Journey 8's second scenario obtained for free rather than by a second code path, and it is the reason the pruning happens first rather than last.
The prune deletes symlinks only, so a real skill directory a consumer put under `claude`'s configuration root is theirs and is left alone.

## M9 — Preconditions for the end-to-end layer, measured before it exists

`M9a` is the first task in this feature whose observable lives outside the checkout, so its preconditions were measured rather than assumed.
Two of them are not satisfiable by an agent at all, and saying so here is the point of the section.

### The canonical ref exists, is public, and holds none of this work

`origin` is `git@github.com:GRBurst/agent-sandbox.git`, which confirms FR-19's `github:GRBurst/agent-sandbox` and confirms that [docs/HANDBOOK.md](../../docs/HANDBOOK.md)'s `github:HivemindTechnologies/sandbox-examples` is wrong in both halves.
`git ls-remote https://github.com/GRBurst/agent-sandbox HEAD` succeeds unauthenticated from inside a confined session, so a stranger can reach it.

What is *at* the ref is the problem.
`origin/main` is `1c8b15e`, "Add basic sdd files", whose flake describes itself as "Hivemind Kafka Playground", and local `main` is a long way ahead of it.
The distance is deliberately not written down: it grows with every commit this feature lands, so the tip is the durable fact and the count is not.
The pushed tree is `.envrc`, `.gitignore`, `AGENTS.md`, `docs/`, `flake.{nix,lock}` and `specs/templates/` — no `lib/`, no `scripts/` — and the pushed `flake.nix` is a *Kafka playground* shell holding `just`, `kcat`, `kafkactl`, `postgresql` and `maven`, with no agent, no `nono` and no `nixConfig`.

So `check_j1_1` cannot go green until a human pushes.
That is not a defect and not a reason to delay writing the check: RED is the correct state for a check whose ref does not yet carry the feature, and it is the only honest state until the push happens.

### An e2e run in this repository lies to itself by default

The obvious invocation passes today, against that agentless ref:

```sh
direnv exec . env HOME="$clean" nix develop 'github:GRBurst/agent-sandbox' \
  --command sh -c 'command -v claude opencode pi nono'
```

It reported four store paths — `…-claude/bin/claude`, `…-opencode/bin/opencode`, `…-pi/bin/pi`, `…-nono-0.74.0/bin/nono` — the same ones the developing checkout resolves.

Printing `$PATH` inside that shell explains it.
The ref's own packages occupy positions 1–20; the agents sit at positions **53–55**, appended.
`nix develop --command` *prepends* the devshell's `PATH` and keeps the caller's, so every tool the developing environment already exported is still on it.
A `command -v` inside `nix develop <ref>` therefore measures the caller, not the ref, and would have reported success for a ref containing nothing at all.

This is the trap [AGENTS.md](../../AGENTS.md) § 4 names, reached by the shortest possible route, and it is why `M9a`'s instrument is part of the task's definition rather than an implementation detail.

### The instrument that does not lie

Bare `nix` is unusable here — the ambient sandbox denies `$HOME`, so the fetcher cache fails with a SQLite error — and `direnv exec .` is what contaminates.
`env -i` with a minimal `PATH` is the only form that is both runnable and clean:

```sh
env -i HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" \
  XDG_CACHE_HOME="$H/.cache" TMPDIR="$H/tmp" USER="$(id -un)" \
  PATH="$(dirname "$(command -v nix)")" \
  nix develop --accept-flake-config '<ref>' --command sh -c '…'
```

`$XDG_CONFIG_HOME` must exist before the run, or `nono` falls back to the host's real `~/.config` — the same trap [`M1e`](#m1e--machine-readable-resolved-policy) found, and already a checkbox on the task.
Under this form the agentless ref reports no agent on `$PATH` at all, which is `check_j1_1`'s genuine RED.
Measured directly: `claude`, `opencode`, `pi` and `nono` all report `ABSENT`, the ref's own `just`, `kcat`, `kafkactl` and `postgresql` occupy the front of `$PATH`, and the instrument's own directory is appended at the *end* rather than the front, which is the whole reason the contaminated form lied.

Two parts of that command line are load-bearing in ways a later reader would otherwise simplify away.

- **`PATH` is derived, not written down.**
  `/run/current-system/sw/bin` is where NixOS puts it and is what this host resolves, but `/nix/var/nix/profiles/default/bin` — the multi-user installer's location, and the one a macOS runner has — **does not exist here at all**, so either literal is wrong on the other platform.
  `dirname "$(command -v nix)"` is correct on both, and it is the same rule [AGENTS.md](../../AGENTS.md) § 4 states for assertions: derive the value from the system under test.
  `M9c` runs on `macos-latest`, so this is not a hypothetical portability worry.
- **`TMPDIR` is not tidiness.**
  `env -i` strips it, `nix` falls back to `/tmp`, and a session confined by the ambient sandbox cannot write there: the run dies with `error: creating temporary file '/tmp/nix-shell.oDg5ip': Permission denied` before it fetches anything.
  A stranger's `/tmp` is writable, so this one is a constraint on *developing* the check rather than on running it — which is exactly the kind of difference that makes a check pass for the author and fail for everyone else, or here the reverse.

Run against the *current* flake by revision rather than by path — `git+file://$PWD?ref=main&rev=$(git rev-parse HEAD)` — the same form puts the four confined wrappers at positions **14–17**, at store paths identical to the direnv shell's.
`writeShellApplication` names a wrapper after `mainProgram`, so `…-claude` is the confined entry point and not the raw `claude-code` package, and the check needs no extra step to tell them apart.

### The substituter is genuinely out of reach for a stranger

[flake.nix](../../flake.nix)'s comment on its own `nixConfig` predicted this, and it is now measured rather than predicted.
The clean run prints:

```text
warning: ignoring untrusted flake configuration setting 'extra-substituters'.
Pass '--accept-flake-config' to trust it
warning: ignoring untrusted flake configuration setting 'extra-trusted-public-keys'.
```

The shell still built, but only because this host's store is warm.
A stranger with a cold store, and equally a CI runner, compiles every agent from source unless the substituter is configured on the machine, the user is trusted, or `--accept-flake-config` is passed.
`https://cache.numtide.com/nix-cache-info` answers `200` from here, so the cache is reachable; reachable and *trusted* are different things, and only the second one saves the build.

`M9a` says nothing is passed `--impure` and says nothing about this flag.
The honest reading is that `--accept-flake-config` is a load-bearing part of the invocation a stranger runs, so it belongs in the handbook's copyable command rather than hidden inside a check.

### What the harness already provides, and what M9 has to create

- `scripts/checks/` holds `unit.sh`, `component.sh` and `integration.sh` only.
  **There is no `e2e.sh`**, though `e2e` is the fourth entry of `LAYERS`.
  `source_layers`, `list_checks` and `run_layers` each skip a layer whose file is absent, and the `found`-versus-`ran` guard added in `M8g` counts only files that exist, so creating the file is the whole of the harness work.
  The contract that file has to satisfy is small and is written down here because nothing else states it: it is **sourced**, not executed, so it defines `check_*` functions and runs nothing at the top level; it inherits `SCRIPT_DIR`, `REPO_ROOT` and `SPEC`, and the helpers `die` (exits the whole suite, status 2), `fail` (prints a reason and returns 1) and `pinned_bin <attr>` (builds a flake output and prints its `bin` directory); a check returning **78** is reported `SKIP` and, per P2's anti-vacuity rule, is not counted as having run; and every check is invoked with its `stdin` on `/dev/null`, which is why no check can observe an interactive prompt.
  Three of the four e2e checks this feature still owes live in that one file — `check_j1_1` from `M9a`, then `check_rep1` and `check_rep2` from `M9b` — so `M9a` creates it and `M9b` extends it, which fixes the order the two tasks run in.
- **There is no `.github/`.** `M9c` starts from nothing.
- `AGENTS.md`'s "no cloud, no Kubernetes, no CD pipeline and no deployed service" is the sentence `M9c` has to amend, and it is one sentence in one place.
- `.gitignore` already excludes `.tmp/`, `.cache/`, `/.local/`, `/.config/`, `/.agents/`, `*.log` and `.direnv`, which is what `M9b`'s "tracked files unchanged" rests on.
  An entry added later would weaken that assertion silently, so `check_rep1` compares *tracked* files rather than the working tree.

### The two preconditions an agent cannot satisfy

Recorded here so that a session picking up `M9` does not spend its budget discovering them again.

1. **The push.** `check_j1_1` is RED until `main` reaches `origin/main`, and [AGENTS.md](../../AGENTS.md) forbids pushing unasked.
1. **The second platform.** SC-8 compares the resolved reach *across* `ubuntu-latest` and `macos-latest`, and no single machine can make that comparison.
   It is the one assertion in the suite that only CI can run, which is why `M9c` exists as a task rather than as a check.

## M9a — Starting an agent by hand, which nothing had done

`M9a` began by trying to start the agents the way [docs/HANDBOOK.md](../../docs/HANDBOOK.md) tells a reader to, and none of the three started.
Two defects sat in series, and each of them had been invisible to a suite of thirty-one green checks.
Both are recorded here in full, because what they have in common is more useful than either: **every assertion in the suite was written from inside a fixture whose starting state the defect's precondition never occurs in.**

### The first was the pre-flight's missing consent, and it is written up under [`M4a`](#the-three-states-of---allow-cwd)

In short: `nono run` without `--allow-cwd` behaves differently depending on `stdin`, and the pre-flight sent its output to `/dev/null` while leaving `stdin` on the terminal, so a user got a cursor and no question.
`scripts/validate.sh` runs every check under `</dev/null`, which is exactly the state in which the question is not asked.

### The second: `opencode`'s configuration file is JSONC, and the agent writes to it

`opencode` 1.18.18 parses `opencode.json` with microsoft's `jsonc-parser`, not with a JSON parser.
Measured against the real binary with a scratch XDG environment — `--version` loads no configuration, `models` and every `debug` subcommand do:

| file content | result |
| --- | --- |
| `{ "$schema": …,}` — a trailing comma | accepted, exit 0 |
| `{ // a comment` then `"theme": "system",}` | accepted, exit 0 |
| `{,,,}` | rejected, `PropertyNameExpected at line 1, column 4` |

The third row is the control: the file is genuinely read, so the tolerance in the first two is tolerance and not a skipped file.

It writes there too, and this is the half that matters.
The agent ensures its own `$schema` key in every configuration file it loads, through `jsonc-parser`'s `modify`/`applyEdits`.
Inserting a key into an **empty** object emits a trailing comma:

```text
{
  "$schema": "https://opencode.ai/config.json",}
```

Inserting before an existing key emits a legal one, which is why a file that already had `skills.paths` in it came out valid.
The filename is irrelevant — `config.json` and `mine.json` were both mangled — so this is not the write-target picker choosing `opencode.jsonc`.

`M8e` had pointed `skillSurface.path` at that very file, on the reasoning that a consumer's own settings might already be there and so it must be merged rather than written whole.
The reasoning was sound and the conclusion was the defect: the entry point's merge writes strict JSON with `jq`, `jq` cannot read JSONC, and the agent turns strict JSON into JSONC.
The first start wrote `{}`, the agent made it `{…,}`, and the second start died on `jq: parse error: Expected another key-value pair at line 2, column 48` — a message naming neither this environment nor the file, with `set -e` taking the shell down before the `mv` and leaving a zero-byte `.agent-sandbox.tmp` for the next run.
The developing checkout had been in that state since the day `M8f` landed.

### The fix is ownership, and the precedence chain is what makes it available

Measured, for the four scopes `opencode` merges:

| scope | beats |
| --- | --- |
| global `$XDG_CONFIG_HOME/opencode/opencode.json` | nothing |
| `OPENCODE_CONFIG=<file>` | global |
| project `./opencode.json` | `OPENCODE_CONFIG` |
| `OPENCODE_CONFIG_CONTENT=<inline json>` | everything |

`OPENCODE_CONFIG` names an **additional** configuration file, not a replacement: a global file carrying `username` and the environment's file carrying `skills.paths` both took effect in the same session, and the global file was left byte-identical.
Arrays are replaced rather than concatenated.
A name that does not exist yet is not an error, so it can be pointed at unconditionally.

So `opencode` is pointed at `.agents/opencode/config.json`, a file this environment owns outright, and `skillSurface` gains an `owned` flag that rewrites it from `{}` on every start instead of merging into it.
That answers both halves at once: nothing this environment writes has to survive a round trip through the agent's editor, and the consumer's own `opencode.json` is no longer read, written or fingerprinted.
It also lands the pointing two scopes higher than it was.

`OPENCODE_CONFIG_CONTENT` was the alternative and was rejected: the content is computed at run time, `environment.set_vars` is Nix-static and `allow_vars` is default-deny, and a file on disk keeps FR-25's property that the pointing is a project artefact a consumer can read.
Pre-parsing the JSONC was rejected as fragile, and making the file read-only was rejected because the agent's write would then fail in a way nobody has measured.

**The limit that remains**: a consumer project whose own `./opencode.json` sets `skills.paths` shadows the environment's roots entirely.
`OPENCODE_CONFIG_CONTENT` is the escape hatch if that is ever wanted, at the cost above.

### Running a session twice is not a reproducer

The obvious check — start the agent twice and require the second start to succeed — was written, run, and abandoned, because it is not deterministic:

| subcommand, twice in a pristine project | file after | second run |
| --- | --- | --- |
| `debug paths` | `{}`, untouched | exit 0 |
| `providers list` | `{}`, untouched | exit 0 |
| `debug skill` | `{"$schema": …,}` | **exit 78** |

And `debug skill` mangled the file on one occasion and left it alone on another, with `$HOME` and `AGENT_SANDBOX_SKILLS` held constant.
Whether the agent persists the schema on a given run is not something a check can depend on.
`check_opencode` therefore **seeds** the file with what the agent leaves behind and asserts the session starts anyway, and asserts separately with `jq -e .` that the file is still valid JSON when the session ends.
Seeding the state is the deterministic form of a defect whose trigger is a previous run.

## M9d — The macOS arm, and the eleven failures behind it

This section is the working record for the macOS side of `M9d`, written so that a session picking the work up needs nothing but this file, and so that nothing already measured is measured again.
`M9d`'s task entry carries the decision and the criteria; what follows is the evidence.

### How the arm got here, in five runs

The workflow itself is new in `M9`, so no macOS run predates this feature.
Each row is a pushed commit and the two jobs it produced.

| run | commit | Linux | macOS |
| --- | --- | --- | --- |
| 1 | `5d221cc` | 34 passed | the job died in the nix installer, two steps before the suite |
| 2 | `4c362f8` | 34 passed | 23 of 33 failed, every session refused to start |
| 3 | `e189d82` | 34 passed | the same 23, plus the probe step's answers |
| 4 | `518ed2d` | 34 passed | **11 of 33 failed**, sessions start |
| 5 | `a8316ed` | 34 passed | the same 11, with the tracing that classified them |

Run 1 was `cachix/install-nix-action@v27`, which installs nix 2.22.1, whose darwin installer assigns `_nixbld1` the UID 301.
macOS 15 and later reserve 300–304 for Apple's own daemon users, so `dscl . create /Users/_nixbld1 UniqueID 301` failed with `eDSRecordAlreadyExists`.
Upstream fixed it in 2.24.7 by moving the first build UID to 351.
No repository code was implicated, and the pinning commit that followed made the installer a non-issue.

Runs 2 and 3 were the scratch-root refusal that `M9d` exists for, and run 4 is the derived `outside_root` landing.
Runs 4 and 5 are the same eleven failures; run 5 differs only in what the failures say about themselves.

### The instruments are mirror images, and neither platform has both

This is the single most useful finding here, because it decides how three of the four classes can be fixed at all.

| instrument | what it observes | Linux | macOS |
| --- | --- | --- | --- |
| `strace` | denied opens, and reads that succeeded | present, from `flake.nix`'s `lib.optionals isLinux` | **absent**, along with `ltrace dtruss ktrace dtrace sc_usage fs_usage` |
| nono's supervisor trailer | the paths a session was refused, with the operation | **absent**: `No path denials were observed during this session.` | present: `Sandbox denial: N paths blocked. <path> (read); …` |
| nono's capability banner, on the session's stderr | every grant, as mode and path | present | expected present, unmeasured |
| the audit trail | that a session ran, and its exit status | present | present |

The trailer is not compiled out on Linux.
Both strings live in the one Linux binary — `grep -a -c` on nono 0.74.0 finds `paths blocked` once, `No path denials were observed` once, `Sandbox denial` three times — so the reporting exists and Landlock simply does not feed it, while Seatbelt does.
That makes the trailer the darwin counterpart of `strace`, available for exactly the assertions that ask *which paths were refused* and useless for the ones that ask *which paths were read*.

The audit trail was tested as a third option and is not one.
With the denied path kept out of argv and out of the environment, `$XDG_STATE_HOME/nono/audit/<id>/audit-events.ndjson` held two records, `session_started` with the command and `session_ended` with the exit status, and nothing anywhere under the state root named the file that was refused.
`nono audit show <id> --json` offers `command_policy_events`, `network_events`, `tracked_paths` and `merkle_roots`, none of them filesystem denials.

The capability banner was measured on Linux and does carry what two of the checks currently read out of `execve` argv:

```text
  nono v0.74.0
  Capabilities:
    r   /nix/store/… (dir)
    r   …/skillA (dir)
    w   …/skillB (dir)
```

Grants passed on the command line appear there beside the ones the description carries, which is what makes it a candidate replacement.
A check reading it has to drop the `/nix/store/` lines, which are hundreds.

### Class A — three checks assert the Linux word for a denial

`check_r1`, `check_r2`, `check_r8`.
The boundary holds and the assertion does not travel: Landlock surfaces `EACCES`, Seatbelt surfaces `EPERM`, and the checks `grep` for `Permission denied`.

Traced on the runner, with the arm and the errno the check actually saw:

```text
DBG r1 shipped: errno wording: Operation not permitted/
DBG r1 shipped: supervisor denial lines: 1
DBG r8 denial message: cat: /Users/runner/work/_temp/agent-sandbox-r8.B8p6re/secret.txt: Operation not permitted
DBG r8 auth message: HTTP/1.1 401 Unauthorized
```

Both `check_r1` arms behaved correctly otherwise — the planted key read as empty under the shipped description and read back its canary once granted — so the refusal is a wording mismatch and nothing else.
The literal appears at `integration.sh` lines 518, 647, 2879 and once more at 3284, and in three prose comments.

### Class B — four checks need a tracer that darwin does not have

`check_j6_2`, `check_r11`, `check_j8_1`, `check_r9` fail on `substrate_member … strace` before doing any work.
All seven tracer candidates print `absent`, which is by construction: `flake.nix` adds `strace` under `lib.optionals isLinux` so that the darwin devshell keeps evaluating.
`check_substrate_denials` asks for the same thing and escapes only because it is gated on `uname -s = Linux`.

What each site actually observes decides whether it can be salvaged, and the four are not alike:

| site | what it reads out of the trace | darwin substitute |
| --- | --- | --- |
| `check_substrate_denials` (352) | the set of denied paths | the trailer, or keep the existing skip |
| `commit_session` (3444), shared by `check_j6_2` and `check_r11` | that the trace is non-empty, then that the denied set is empty | the trailer, for the assertion; **the non-emptiness control has no substitute** |
| `check_j8_1` (4147), first arm | that a declared surface directory *was opened*, `O_RDONLY` returning a descriptor | none — a positive syscall observation |
| `check_j8_1` (4230) and `check_r9` (4434), grant arms | `--read`/`--allow`/`--write` in the `execve` argv the wrapper built | the capability banner |

The awkward one is `commit_session`'s control.
Its assertion is *no denials*, and an absent instrument satisfies that vacuously, which is why the check first requires the trace to be non-empty.
The trailer can carry the assertion; something else has to carry the control, and the obvious candidate is that the commit itself demonstrably happened, which the check can already see from `git log`.

`check_r9`'s control has the same shape: `grep -qE 'execve\("[^"]*/nono"'` proves the wrapper reached the mechanism at all, and on darwin that has to come from somewhere else — the banner's presence being the natural answer, since only a started session prints it.

### Class C — the fabricated home's mtime moves, and the cause is in the product

`check_j2_1` and `check_j3_1` compare the fabricated home before and after a session, subtract the leak registry, and require nothing to remain.
On macOS one line remains, and it is the home directory itself:

```text
DBG j2_1 home diff: 1c1
<   /Users/runner/work/_temp/agent-sandbox-j2_1.flZnGV/home	128	1787564526.678024061
>   /Users/runner/work/_temp/agent-sandbox-j2_1.flZnGV/home	128	1787564531.437078681
```

Modification time moved, size is identical, and no child differs — `check_j3_1`'s home is empty throughout.
So something was created inside it and removed again within the session.

**The cause is `lib/preflight.sh:35`**, and it was reproduced on Linux rather than inferred:

```sh
canary="${XDG_RUNTIME_DIR:-$HOME}/.agent-sandbox-preflight.$$"
```

Every agent entry point embeds the pre-flight and runs it before starting.
Assertion 2 writes that canary unconfined as a positive control, removes it, and assertion 3 requires the same write to fail under confinement.
With `XDG_RUNTIME_DIR` unset the canary lands in `$HOME`, which on the macOS runner is the check's fabricated home.

Three cases, run against the real pre-flight with a fabricated home:

| `XDG_RUNTIME_DIR` | result | the home afterwards |
| --- | --- | --- |
| unset | `preflight: passed` | **mtime moved, size unchanged, no residue** — the macOS signature, on Linux |
| a directory inside the project | **exit 77**, `confinement is not enforced: a confined process wrote outside the project.` | untouched |
| an ungranted runtime directory | passed | unchanged |

The middle row is the more serious finding, and it was not what the experiment was looking for.
The canary has to be both writable *and* ungranted, or assertion 3's confined write succeeds and the pre-flight refuses to start a session that is perfectly well confined.
`$XDG_RUNTIME_DIR` being unset is therefore not the whole hazard: a consumer who exports it to something inside their project breaks every agent with a message accusing the mechanism.
The product carries the same derivation problem that `outside_root` solved for the harness, one layer down and with a worse failure mode, because the harness fails loudly to the maintainer while this fails loudly to the user.

On macOS the consequence is sharper still.
The floor grants `/private`, `/tmp`, `/var/folders` and `$TMPDIR` is the project, so the only ungranted writable class is under `/Users`.
The `${XDG_RUNTIME_DIR:-$HOME}` fallback is thus not a convenience default on darwin — it is the only location that can work, and it writes into the user's real home on every agent start.
That is a write outside the project, transient but real, and it is neither in the leak registry nor in `P1`'s accepted-leak list.

So `check_j2_1` and `check_j3_1` are **right**, and they are the first checks in this feature to catch the product rather than the fixture.

### Class D — bun cannot read the capture it was handed, and the `M9d` fix caused it

`check_opencode` and `check_pi` redirect the agent's stdout and stderr into files beside the fabricated home, and on macOS both agents die on startup.
nono's trailer names the capture files and every ancestor as refused **reads**:

```text
Sandbox denial: 8 paths blocked. /Users (read); /Users/runner (read); /Users/runner/work (read);
/Users/runner/work/_temp (read); …/agent-sandbox-opencode.5wL1MN (read); …/paths.err (read); …/paths.out (read)
```

The same command with the capture redirected into the granted project exits 0 and answers correctly — `opencode debug paths` printing every root inside the project, `pi auth check` printing `{"status":"ready","authType":"api_key",…}`.
That rerun is what makes this a location problem and not an agent-under-confinement problem.

It is bun-specific.
`claude-code` captures into the same directory in `check_j2_1` and is unaffected, as is every plain `bash` probe in the layer.
Bun evidently resolves the path of its inherited standard descriptors at startup; Seatbelt checks by path and refuses, while Landlock does not re-check an already-open descriptor.
Both agents are bun binaries — `Bun v1.3.14 (macOS arm64)` for `opencode`, `Bun v1.3.13` for `pi`.

The class was **introduced by the `M9d` fix**: the captures used to live under `/tmp`, which `system_read_macos` grants through `/private`, and they now live somewhere granted nothing, which is precisely the property that makes the scratch root usable.

Where a relocated capture may go is constrained, and the constraint is easy to miss.
In these two checks the session's `--workdir` is the fabricated *project*, so that project is the only granted writable place — `$REPO_ROOT` is not granted here.
And `check_opencode:3832` and `check_pi:4002` both carry an anti-vacuity control:

```sh
mapfile -t landed < <(find "$project" -mindepth 1 | sort)
[ ${#landed[@]} -eq 0 ] && fail "the session wrote nothing inside the project, so an unchanged home directory would prove nothing"
```

Capturing straight into the project would make that control true by construction.
A relocation therefore needs its own subdirectory, excluded from that listing and from the home comparison, or a mechanism with no path at all — piping the session's output through an unconfined `cat`, so the child holds a pipe rather than a file, which is unmeasured on darwin.

### What a Linux host cannot close

Four things remain, and each needs the macOS runner rather than more reading.
They are listed here so the next run is designed to answer all four at once rather than one per push.

| id | question | why it matters |
| --- | --- | --- |
| U1 | does the darwin trailer enumerate **write** denials as well as reads, and is it complete rather than truncated at some count | it replaces `trace_denials` in `commit_session` only if it is complete |
| U2 | can *any* positive read observation be made on darwin without disabling SIP — `dtruss` needs it off, `fs_usage` needs root | decides whether `check_j8_1`'s first arm becomes a restructured assertion or a recorded gap |
| U3 | does the capability banner print identically on darwin | it is the substitute for two checks' argv reading |
| U4 | which capture relocation keeps the `landed` control honest | the pipe variant has no measurement at all |

All four are now answered, three of them without the runner that was thought necessary: U1 and U3 from the failing run's own logs, U2 from nono's audit trail on Linux, and U4 from reading what the control actually ranges over.
[M9e](#m9e--the-four-classes-answered-without-a-mac) records each answer and what it changed.

### Method notes worth keeping

- `run_check` prints a check's output **only when it fails or skips**, so diagnostics are invisible on the platform where the check passes.
  That is convenient here and it is also a trap: a `dbg` line proves nothing until the check has been made to fail deliberately.
- A background poller started inside a command substitution hangs the check outright.
  `watcher=$(dbg_watch_start …)` waits for an EOF the backgrounded subshell never sends unless its own output is redirected, and the symptom is a 15-minute run that produces nothing.
- The CI logs carry a `2026-…Z ` prefix on every line; strip it with `sed 's/^2026[^ ]* //'` before reading.
  A macOS log is roughly twice the length of the Linux one for the same suite, because nono prints its whole capability table to each session's stderr and every failure message quotes it.
- `nix build .#nono.src` fails in this environment (`cannot open SQLite database … fetcher-cache-v4.sqlite`), so nono's behaviour was established from its binary and its own subcommands rather than from its source.

______________________________________________________________________

## M9e — The four classes, answered without a Mac

[M9d](#m9d--the-macos-arm-and-the-eleven-failures-behind-it) closed with four questions it said only a macOS runner could answer.
None of them needed one.
Three were already lying in the failing run's own logs, unread because the previous session was looking for a cause rather than for evidence, and the fourth dissolved on reading what the control it threatened actually ranges over.
A fifth thing, which nothing had asked, was found in the same logs and would have broken the class B fix on the next push.

This section records what each answer is, how it was obtained, and what it changed.
The measures themselves are in [tasks.md](tasks.md) § M9e, and a per-check reproduction table is in [debug-macos.md](debug-macos.md).

### The logs were the instrument, and they were already downloaded

The failing run is `a8316ed`, whose logs the previous session fetched to read the `DBG` lines it had planted and then stopped reading.
Everything below comes from those same two files — the darwin job's 1939 lines and the Linux job's 977 — which are not kept in the repository; [debug-macos.md](debug-macos.md) says how to fetch them again.

The lesson generalises past this feature.
The tracing that `M9d` added answered its own question and was then treated as spent, but the *untraced* output around it — nono's banner and its supervisor trailer, printed on every session and quoted in full by every failure message — is what carried three of the four answers.
A macOS log is twice the length of a Linux one for exactly this reason, and that bulk was read as noise.

### U3 — the banner prints identically on darwin

Seven `Capabilities:` blocks in the macOS log, the same `r   /nix/store/… (dir)` shape and the same rule beneath the heading as on Linux.
So the substitution of the banner for `execve` argv reading is safe on both platforms, and `check_j8_1`'s grant arm and `check_r9` need no platform split at all.

The banner's vocabulary is three modes and not two, which a `--read`/`--allow`/`--write` session on Linux shows directly:

```text
   r+w  /home/…/m9e/out/rw (dir)
   r    /home/…/m9e/out/ro (dir)
   w    /home/…/m9e/out/wo (dir)
```

A parse of `^[[:space:]]+(r\+w|r|w)[[:space:]]+(.*) \((dir|file)\)$` with `/nix/store/` dropped is therefore what those two checks need.
An earlier note in `M9d` recorded the vocabulary as `{r, w}`; it is `{r, w, r+w}`, and a check that matched `r` against a read-write grant would have matched nothing.

### U1 — the trailer enumerates writes, and its completeness is self-checkable

Five trailers in the macOS log, headed `2 paths blocked` three times, `8 paths blocked` and `4 paths blocked`.
Writes are enumerated beside reads — `…/home/outside/created.txt (write)` is `check_r2`'s — with seventeen `(read)` and one `(write)` across the run.

There is no truncation marker anywhere, but the stronger finding is that **the trailer states its own count**.
In every one of the five, the header's number equals the number of lines that follow it.
So a check does not have to trust that the enumeration is complete: it compares the count it parsed against the count the header claims and fails when they disagree.
Completeness stops being a property of nono that this repository assumes and becomes an assertion the harness makes, which is the difference between a claim and a check, and it needed no macOS runner to establish.

### The finding nothing asked for — every darwin trailer carries ambient noise

`/Users/runner/.CFUserTextEncoding (read)` appears in all five trailers, including the ones where the boundary behaved exactly as intended.
It is macOS reading a per-user text-encoding hint at process startup, it has nothing to do with the session, and it is denied because the home directory is denied.

`commit_session`'s assertion is that the denied set is **empty**.
On darwin that can never hold, so the class B fix as planned would have failed on its first push and looked like the trailer being unusable rather than like one line of platform noise.

The remedy is not a literal.
A no-op confined session run once per suite produces the platform's ambient denial set, and subtracting that baseline from the session under test leaves what the session itself was refused.
It is self-calibrating, costs one 118 ms invocation, spells no platform-specific path anywhere, and on Linux the baseline is empty and the subtraction is an identity.
This is the property-based form AGENTS.md §4 asks for: *the session added no denial of its own*, rather than *the denied set matches this list*.

Two more trailer features are worth knowing before writing the parser.
A path in a deny group prints as `[permanently restricted]` with a footer naming the profile key that would override it, `filesystem.bypass_protection` — which is the first sight of that key and bears on [M10a](tasks.md#m10a--close-out-status-pending)'s question about fabricating a home under `/private`.
And each trailer prints a `Fix flags:` line spelling the exact `--read`/`--read-file`/`--write` that would grant each blocked path, so a failure message can quote the remedy rather than describe it.

### U2 — no, and the audit trail is where that was settled

There is no positive read observation on darwin.
`dtruss` needs SIP off and `fs_usage` needs root, the trailer records only denials, and the audit trail — the last candidate — records only *grants*.

That last one was measured rather than assumed.
A confined session read `$W/surface/declared.txt` and then `nono audit show <id> --json` was queried: `tracked_paths` holds the project directory and every one of the ~130 `/nix/store` closure roots, and does not hold the file that was read.
It is the granted set under another name, and it is also **mode-blind** — a `--read`, an `--allow` and a `--write` path appear in it identically — so it cannot serve the argv assertions either.
`audit-events.ndjson` holds exactly two events, `session_started` and `session_ended`, wrapped in hash-chain envelopes.

So `check_j8_1`'s positive arm skips on darwin, with the reason named in `docs/HANDBOOK.md`, and the gap is a known one.
Both instruments observe the boundary; neither observes traffic that the boundary permitted.

### U4 — the control was never at risk

`check_opencode`'s anti-vacuity control is `mapfile -t landed < <(find "$project" -mindepth 1 …)`, and the reading that made a capture relocation look dangerous was that the harness's own capture files would satisfy it.
They would, but they are not what satisfies it today: the agents' XDG roots are relocated *into* the project, so the session's own writes populate it.
The risk of capturing into the project is that the control becomes vacuous, not that it breaks — a different and much smaller problem, closed by one dedicated subdirectory excluded from that single listing.

The pipe alternative is rejected, and the reason is worth recording because it looked like the cleaner design.
It cannot be measured from Linux at all: Landlock does not re-check an already-open descriptor, so a Linux run that succeeds says nothing about whether bun resolves the path of a pipe at startup on darwin.
Choosing it would have meant shipping the unverifiable option when the verifiable one was already supported by the logs — the run's own trailers name `paths.err`, `paths.out` and their ancestors as the refused reads, so putting them inside the granted project removes exactly those denials and nothing else.

### Class C — the pre-flight can stop writing outside the project altogether

`M9d` framed the canary as a location problem: find somewhere writable that nothing grants, and if macOS only offers `/Users`, accept a leak.
That framing was wrong, and the way out is that **a denial can be observed by reading**.

A confined read of `$HOME` is refused even when the project sits inside `$HOME`.
Measured here with `HOME=/home/pallon` and the workdir at `/home/pallon/projects/hivemind/agent-sandbox`:

```text
ls: cannot open directory '/home/pallon': Permission denied
```

Granting a descendant does not grant the ancestor.
Darwin needs no separate measurement, because the failing run's trailers already list `/Users`, `/Users/runner`, `/Users/runner/work` and `/Users/runner/work/_temp` as refused reads.
`$HOME` is therefore a probe target with properties no fabricated location has: it always exists, its owner can always read it unconfined, no profile grants it, and it does not have to be found.

One confined invocation carries the whole assertion, reporting through its exit status:

```sh
if ls -A "$H" >/dev/null 2>&1; then exit 10; fi       # read leaked
if ( : > "$H/.probe" ) 2>/dev/null; then exit 11; fi  # write leaked
if [ -e "$H/.probe" ]; then exit 12; fi               # denied but landed
exit 0
```

Against an ungranted path it returns 0; pointed at a granted one it returns 10, which is the false-alarm arm `check_pf` was told to grow, available as a planted violation without writing a fixture.
`127` stays distinguishable as a missing probe command rather than a denial.
Two confined runs cost 236 ms, and the pre-flight already spends two, so nothing about its budget changes and neither a `nix build` nor a `nono why` is needed.

What this removes is larger than the failure it fixes.
In every passing case the pre-flight writes nothing outside the project, so the leak-registry question that `M9e` and `M10a` were both carrying does not have to be answered — there is no leak to enumerate.
The false-alarm case stops being a case to test and becomes structurally impossible, given a cheap guard rejecting `$HOME` empty, equal to `$PWD`, or beneath it.
And because nothing reads an error message, class C stays independent of class A.

### A latent defect the experiment exposed

Assertion 3 of the current pre-flight passes for the wrong reason.

```sh
sh -c ": > \"$canary\""
```

`:` is a POSIX *special builtin*, so a redirection failure on it makes a non-interactive shell exit outright rather than continue with a non-zero status.
The check reads the shell's own abort as the child's denial, and gets the right answer by accident.
Nor does `2>/dev/null` suppress the message, since redirections are applied left to right and `> file` fails before the stderr redirection is installed.
The subshell form `( : > "$path" ) 2>/dev/null` behaves as intended, and this is the form the combined probe uses.

Confined exit-status fidelity was verified separately, since the whole probe design rests on it: `exit 0` arrives as 0 and `exit 7` as 7 through `nono run`.

### Class A — two of the three assertions should be deleted, not made portable

The plan was to have all three checks accept either wording.
Reading them says that two of the three should not be asserting on wording at all.

`check_r1` and `check_r2` each already carry three controls: an unconfined read or write of that exact path before the session, an in-project operation inside the same session proving the session and the probe ran, and a `granted` arm that adds the path to the profile and requires the same probe to *succeed*.
The wording grep exists to exclude one alternative explanation — "the key may simply not have been there" — and controls two and three refute that explanation by reading and writing that very path in the same run.
The assertion is redundant, and deleting it is both smaller and stronger than teaching it a second spelling.

`check_r8` is the one case where a wording is the criterion rather than a proxy: its scenario is that a confinement denial and an authentication failure must not read alike, so it asserts that the denial carries the vocabulary and the auth failure does not.
AGENTS.md §4 permits a literal exactly here, where the literal *is* what a user reads — but it has to be the running platform's phrase.

Deriving it works, and the shape that works keeps nono's own output out of the sample by having the child redirect its own stderr into the granted project:

```sh
nono run … -- sh -c 'ls -A "$1" 2>"$2"' sh "$ungranted" "$capture"
phrase=${line##*: }   # line = last line of "$capture"
```

Two different probe shapes give the same clean phrase — `ls: cannot open directory '…': Permission denied` and `sh: line 1: …: Permission denied` both yield `Permission denied` — and the same extraction on darwin yields `Operation not permitted`, which the failing run shows as `cat: …/secret.txt: Operation not permitted`.
The derivation carries its own control: the path must be proven to exist and be readable unconfined first, or an `ENOENT` phrase would be derived and the assertion would pass on nothing.
One 118 ms invocation, memoised for the suite.

### Class B — four sites, four different answers, and one needs no instrument

The class was diagnosed as "they need `strace`".
One of the four does not touch a trace at all.

`check_r11` reads only the `DEMAND_*` lines its probe prints.
It fails on darwin because it calls `commit_session`, whose first act is to refuse when the substrate has no tracer — one guard in a shared helper, failing a caller that never uses what the guard protects.
Moving the requirement out of the helper and into `check_j6_2`, the one consumer that reads the trace, recovers `check_r11` on darwin with no new instrument and no platform split.

That leaves three real ones, and the answers differ:

| site | what it observes | answer |
| --- | --- | --- |
| `check_j6_2` | the denied set is empty, plus a control that the trace is non-empty | trailer on darwin, with baseline subtraction; the control becomes *nono reported at all* |
| `check_j8_1` grant arm, `check_r9` | `--read`/`--allow`/`--write` in the wrapper's `execve` argv | the capability banner, on both platforms, no split |
| `check_j8_1` first arm | that a declared surface *was read* | nothing observes this on darwin; skip with the reason recorded |

The non-emptiness control was the part `M9d` said had no substitute, and it does have one.
Nono always reports: its stderr carries either an `N paths blocked` header or `No path denials were observed during this session.`, and either sentence proves the supervisor was watching.
That is the same claim `[ -s plain.trace ]` makes on Linux — the instrument was present and produced output — rather than a weaker stand-in like `git log` showing the commit happened, which proves the commit and not the observation.

### Method notes worth keeping

- **A confined agent session cannot use its own `$HOME` as a control.**
  This session is itself confined, so `ls -A "$HOME"` fails for the outer shell too and every positive control needed a stand-in — a path the outer session can read and `nono why` reports as `path_not_granted` for the profile under test.
  A control that is measured from inside the thing being measured is not a control, and the confusion costs more than the substitution.
- **`nono why` answers about the profile, not about the host.**
  It is the right way to establish that a stand-in has the same standing as the real target, and it costs no session.
- The trailer, the banner and the audit trail are three separate views and only two of them are instruments.
  Denials come from the trailer, grants from the banner, and the audit trail restates the grants in a mode-blind form that no assertion here can use.
- `sessionTools` in `flake.nix` carries no `findutils`, yet the harness uses GNU-only `find -printf` and it works on the darwin runner because `nix develop`'s stdenv puts GNU findutils on `PATH` implicitly.
  Meanwhile `outside_root` avoids GNU-only `mktemp -p` for BSD's sake.
  Both cannot be right: under AGENTS.md §3 a tool that resolves incidentally is not available, so either `findutils` is declared or the dependency is recorded as known drift.
