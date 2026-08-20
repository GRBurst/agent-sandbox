# Implementation Plan: Confined agent sessions per project

**Spec**: [spec.md](spec.md) | **Branch**: `001-agent-sandbox` | **Date**: 2026-08-18

## Summary

**Motivation.** The repository keeps its own tools inside the checkout and does nothing to keep an *agent* there. Its only attempt at confinement — a generated devcontainer bind-mounting four host agent directories read-write — shares credentials and session state with every other consumer of that home. This feature replaces it with kernel-enforced host-level confinement.

**Approach.** `flake.nix` exports a devShell whose `PATH` carries one confined entry point per agent. Each entry point is `pkgs.writeShellApplication` that (1) runs a **functional** pre-flight — a confined child that must fail to write outside the project, else exit `77` — and (2) `exec`s `nono run --profile <store path> --workdir "$PWD"`. The confinement description is a JSON profile built by Nix into the store, naming **no parent** and declaring everything it wants, using nono's own `$WORKDIR` expansion so **nothing is generated per project**. Agent state is relocated into `$WORKDIR/.agents/<agent>` via `environment.set_vars`; host variables are filtered default-deny via `environment.allow_vars`. `$WORKDIR` is granted **read and write** explicitly, because `M1g` found `--allow-cwd` grants it read-only by default and a read-only project makes every agent useless. `scripts/validate.sh` is the single entry point and derives its expected reach from `lib/leak-registry.nix` rather than restating it.

**Predicted diff shape.** `devenv.*`, `ai.nix` and the drafts are deleted; `flake.nix` is rewritten around two systems and a `lib/` of four small Nix files; `scripts/validate.sh` and a two-platform CI workflow are new; `docs/` is updated at close-out.

**The pivot, resolved.** `M1b` closed [Decision D1](#d1) by falsifying its premise, and `M1c`–`M1g` closed the rest. `M1g` was the last of them and the one that could have redirected the design: `claude-code`'s configuration root does relocate, through three of thirteen candidate variables, and nothing survives beneath the home directory — but the credential relocates **with** it, so FR-7 is not satisfiable by relocation and needs exactly the supervisor-side injection D1 and [D14](#d14) had already chosen. `claude-code` is the reference case because `opencode` and `pi` take their credential from the session it authenticates (FR-7), so nothing about FR-6 or FR-7 is demonstrable until it works.

## Read first

Read these before writing anything. Do not skim `ai.nix`; it is the working prior art and every non-obvious constraint below came from it.

**In this repository**

| Path | Why |
| --- | --- |
| `specs/001-agent-sandbox/spec.md` | The scenarios are the acceptance criteria. Nothing here overrides them |
| `AGENTS.md` | Artifact contract, verification rules, the four test layers, the diagram rules |
| `docs/CONSTITUTION.md` | P1…P9. The Constitution Check below is a gate against this file |
| `docs/HANDBOOK.md` | Current truth and the Known drift list this feature retires |
| `ai.nix` | The reference implementation of host-side nono confinement, with the hard-won facts as comments |
| `flake.nix`, `.envrc`, `.gitignore` | What is being rewritten; the two bootstrap variables must resolve to the same value in the first two |
| `draft1.md`, `draft2.md` | The option surface proposals. Read for intent; the spec deliberately does not adopt them |
| `devenv.nix`, `devenv.yaml` | What is being deleted, including the four bind mounts that are the leak |
| `specs/templates/tasks.md` | The task shape `tasks.md` instantiates |

**Upstream documentation** — read before `M1`, because every spike below is a question about one of these.

- `https://nono.sh/docs/cli/features/profiles-groups.md` — sections, precedence, the 32 built-in groups
- `https://nono.sh/docs/cli/features/profile-authoring.md` — variable expansion, `extends` merge semantics, `environment` three-state filtering
- `https://nono.sh/docs/cli/features/sandboxed-oauth-logins.md` — `credential_providers`, `credential_routes`, phantom tokens
- `https://nono.sh/docs/cli/clients/quickstart.md` — the supported-client table

## Technical context

| | |
| --- | --- |
| **Languages touched** | Nix, bash, generated JSON |
| **Consumed as** | flake — `nix develop github:GRBurst/agent-sandbox`, and as a flake input by a downstream project |
| **Platforms that must work** | `x86_64-linux`, `aarch64-darwin` |
| **New inputs or tools** | `nono` and all three agent packages from a pinned `numtide/llm-agents.nix` input — `M1f` found `pi` absent from the pinned nixpkgs, and taking `nono` (0.73.0 there, 0.68.0 in nixpkgs) from the same input keeps the binary and the confinement descriptions it reads on one pin; `allowUnfree` scoped to `claude-code` alone; that input's substituter `https://cache.numtide.com` and its key re-declared here, since a `nixConfig` on an input does not reach this flake's consumer; `shellcheck`, `shfmt`, `jq` added to the devShell |
| **Effects introduced** | Shell hook (exports the project-scoped variables, including the one blanket `XDG_CONFIG_HOME` that [C1](#complexity-tracking) tracks, and `mkdir -p` of `.tmp`, `.cache`, `.agents` and `$XDG_CONFIG_HOME` — `M1e` found nono silently falls back to the host's `$HOME/.config` when that directory does not exist, warns, and then reads host profiles); the confined entry point at run time. No build-time effect, no activation script |
| **State written outside the checkout** | `$XDG_STATE_HOME/nono` only — nono's own audit log, session records, per-session interception authority and credential store. Not relocatable *into the project*, and not granted to the sandbox. This is the feature's single new accepted leak, and it is **not** a leak-registry entry (see [D2](#d2)) |

## Constitution Check

| Principle | Verdict | How |
| --- | --- | --- |
| **P1** Isolation is the product | **PASS, one tracked violation** | Agent state is relocated into `$WORKDIR/.agents/<agent>` with each agent's *own* variable. The mechanism itself is the exception and gets a blanket `XDG_CONFIG_HOME`, tracked as [C1](#complexity-tracking) rather than claimed away. Granted reach is `$WORKDIR` ∪ registry with no override in force, asserted by `check_sc1` against `lib/leak-registry.nix`. FR-25's authoring surface reads configuration outside the project and so has to be named here: it is **not** an exception this principle grants, because P1 governs what the environment does on its own and the surface arrives only when the human declares it, by the same FR-15 route as D16's forwarded signing socket. `check_j8_2` is what keeps that claim honest, by asserting the undeclared default is unchanged. One new accepted leak: `$XDG_STATE_HOME/nono`, enumerated and justified in `docs/HANDBOOK.md`, joining the existing `source_up_if_exists`. The two bootstrap variables resolve to the same value in `.envrc` and `flake.nix`, now with a check that runs both and compares what each leaves behind |
| **P2** Test first, prove the check bites | **PASS** | `check_sc3` (scenario ↔ check bijection) goes red first, before any implementation exists. Every check below has a row in [Planted violations](#planted-violations), and every check whose observable is a *failure* carries a positive control in the same session per [D9](#d9), so the failure is attributable to the boundary rather than to a session that never started |
| **P3** Scenarios are the success criteria | **PASS** | One check per scenario, the bijection asserted executably by `check_sc3` rather than by review. This row deliberately states no count: it read "20 scenarios, 20 checks" while the real figure was already 22, and Journey 8 has since made it 24. A number written here is a number that drifts, which is the whole reason the bijection is a check |
| **P4** One step at a time | **PASS** | `tasks.md` is one scenario per task; the two tasks that risk the ~50-line ceiling (`M4a` pre-flight, `M7a` credential profile) are split at their natural seam |
| **P5** Clean code invariants | **PASS** | `mkConfinedAgent`, `mkConfinementDescription`, `preflight_or_die` each do one thing. Comments record *why a path is not granted*: `$XDG_STATE_HOME/nono` (nono refuses overlapping grants), `$XDG_RUNTIME_DIR` (holds keyring and D-Bus), every host git configuration file (a directive in one runs a program inside the boundary — [D11](#d11)) |
| **P6** Refactor as a separate phase | **PASS** | `M8a` is a pure refactor: extract `mkConfinedAgent` from the `claude-code`-specific wrapper. Preservation proven by `nix eval --json .#confinement.claude-code \| jq -S .` diffing empty across it |
| **P7** Ubiquitous language, modelled options | **PASS** | The spec's Vocabulary is used verbatim in Nix attribute names, shell function names and docs. A registry entry is a `submodule` with five typed fields, never `attrsOf str`. nono's boundary merge semantics are written down in [D4](#d4) because they are part of the contract |
| **P8** Purity, effects at the boundary, idempotency | **PASS** | No `builtins.getEnv`, no `--impure`. Confinement descriptions name no parent and declare everything, so nothing is fetched from `registry.nono.sh` at run time and a description cannot inherit a grant a packaged one chooses to make — `M1e` found the mechanism ships no agent preset at all, only language runtimes, and that a description resolves identically whether or not it names the built-in floor. `NONO_NO_UPDATE_CHECK=1` is exported by the entry point so no background network call happens either — `M1e` observed that without it even `nono profile list` calls home, and `M3b` found the description structurally cannot carry it because the `NONO_*` prefix is reserved in `set_vars`. Rep1–Rep3 cover idempotency |
| **P9** Explicit outcomes, no silent fallbacks | **PASS** | `set -euo pipefail` throughout. The pre-flight has **three** assertions, not one, so "nono failed to start" cannot be mistaken for "the child was denied". No bare `or`; the agent table is an `enum`-keyed attrset with an assertion on lookup failure |

### Complexity Tracking

<a id="c1"></a>

| Id | Violation | Why it is necessary | Cheaper alternative rejected because |
| --- | --- | --- | --- |
| **C1** | `flake.nix`'s `shellHook` exports a blanket `XDG_CONFIG_HOME="$PWD/.config"`, which **P1** tells us to avoid in favour of each tool's own variable | nono has no variable of its own for its configuration root. `M1e` found it falls back to the host's `$HOME/.config` when `XDG_CONFIG_HOME` names a directory that does not exist, so without the redirect the host's profiles and packages decide what a confined session may reach — the one thing this feature exists to prevent | `NONO_CONFIG` looks like the specific variable **P1** asks for and is not one. It appears in the binary, and nono's own help text places it among the tokens that expand *inside a profile's path grants*. Measured on nono 0.74.0 with `XDG_CONFIG_HOME` pointed at an absent directory: with `NONO_CONFIG` unset and with it set to a directory that exists, both arms emit the identical `Ignoring invalid XDG_CONFIG_HOME=… falling back to $HOME/.config`. It does not relocate the configuration root, so no narrower variable exists to prefer |

**What the violation costs, stated rather than discounted.** The blanket applies to every program run from the devShell, not only to a confined session, so an unconfined tool started from the project shell reads project configuration instead of the developer's own. That surfaced first as an unrelated GUI editor depositing its caches and local storage into `.config/`, which is why `.gitignore` now denies that directory by default. It is also why the developer's own agent, run unconfined from inside the checkout, loses its host configuration — a consequence of the *scope* of this variable, and not the confinement property that `FR-21` describes.

## Decisions

<a id="d1"></a>

- <a id="d1"></a>**D1 — Credential substitution by proxy-side injection, falling back to a granted phantom store.** Preferred: `network.credentials` / `credential_routes`, where nono holds the real key and injects it at the proxy, so the agent holds *nothing*. Then FR-7 is automatic (the store is machine-wide under the mechanism's own state root) and the leak registry stays **empty**. Fallback: `credential_providers` with `oauth_capture`, where the agent persists a phantom — which must then be machine-scoped to satisfy FR-7, making each agent's credential file a registry entry.
  **This is the architecture's pivot**: option (a) yields an empty registry, option (b) yields ≤4 entries. It turns on whether each agent accepts a substituted API base URL, *not* on the credential's file format. Resolved by spike `M1b` before `M7` starts.
  **Resolved by `M1b` to (a), for all three agents, with no weaker tier.** The fork's premise was wrong: nono is a TLS-terminating proxy with its own generated CA, so a credential is injected on the way past `https://api.anthropic.com` and endpoint substitution is optional rather than required. Both mechanisms keep the real secret in the supervisor, outside the boundary, so neither is the weaker tier — `credential_providers` is the OAuth *shape*, not a degraded fallback. `claude-code` authenticates by token exchange and takes `credential_providers`; `opencode` and `pi` present a key per request and take `network.credentials`. All three agents honour `NODE_EXTRA_CA_CERTS` and all three also expose a base-URL knob as a second route, so no agent is stuck on one mechanism. **The leak registry stays empty**, provided `credential_key` resolves through `env://` or `cmd://` rather than `file://`. Evidence per agent in [research.md](research.md#m1b--credential-substitution-per-agent).

<a id="d2"></a>

- <a id="d2"></a>**D2 — the mechanism's own state root is an accepted leak, not a registry entry.** The spec (line 272) says it is "the registry's first entry". That is wrong and must be corrected in place: nono **refuses to start** when a grant overlaps its own state root, so it cannot be granted. The leak registry enumerates *granted reach* (FR-2/FR-3); the state root is *state written outside the checkout* by the mechanism itself. Two different concerns; the plan keeps them apart. Consequence: the registry carries nothing on the state root's account, and [D15](#d15) later gives it its one entry — the execution substrate. `check_sc1` asserts an **equality** either way: granted reach is the project directory plus whatever the registry justifies, and nothing else.
  The path is `$XDG_STATE_HOME/nono`, observed in `M1c` and `M1e` — not `$HOME/.nono`, which one research round asserted and which the mechanism does not use. It holds the audit log, the session records, the per-session interception authority and the credential store.

<a id="d3"></a>

- <a id="d3"></a>**D3 — Confined entry points shadow the agent name; the raw binary is not on `PATH`.** `claude` inside the devShell is the confined wrapper. The unconfined binary is reachable only by store path, or by the consumer's own global install outside this shell. Chosen over prefixed names (`confined-claude`), which lost because they make *unconfined* the default spelling and a consumer's script calling `claude` would silently escape. Chosen over shell aliases, which lost because they do not survive `nix develop -c` and so cannot be verified non-interactively. **This slightly reinterprets the Q7 answer** ("quoting / not using the alias"): escaping is still deliberate and visible, but the gesture is leaving the shell rather than `\claude`.

<a id="d4"></a>

- <a id="d4"></a>**D4 — Merge behaviour at the nono boundary is written down, per P7.** `M1e` narrowed which merge this environment is actually exposed to. Because a description names no parent ([D10](#d10)), `extends` merge semantics are no longer part of this environment's contract; what remains is the merge of three things nono performs for every session: the built-in floor, the security groups a description includes, and the description's own declarations.
  Within that merge: the floor's grants and denies are always present and cannot be dropped by omission; an included group contributes its grants additively and takes nothing away; a group's `deny` **outranks** any grant, which is why `deny_credentials` and the keychain groups are `"required": true` and cannot be traded away; `environment.set_vars` is a map the description owns outright.
  `M3d` observed the precedence claim and found it holds in a form worth stating exactly, because it is not the obvious one: the resolver does **not** drop the losing grant. A path that a `required` group denies and the description also grants appears in `.filesystem.grants` *and* in `.filesystem.deny` of the same manifest. Precedence is therefore observable as **deny-survival**, not as grant-absence, and the kernel-time consequence is [D15](#d15)'s refusal to start rather than a quiet narrowing. A check that looked for the grant to disappear would have concluded the opposite of the truth.
  **The `allow_vars`/`deny_vars` filter order is not part of this contract, and `M3d` is where that was settled.** `--format manifest` carries only `$schema`, `filesystem`, `network`, `process` and `version` — there is no `environment` key — `--format profile` prints no environment section, and `nono run --dry-run` prints capabilities only. So the order is not observable in any resolved description, and asserting it here would mean asserting from the schema, which the paragraph below forbids. It is also not a contract this environment rests on: [D6](#d6) chose an `allow_vars` allowlist and `lib/confinement.nix` sets no `deny_vars` at all, so there is no interaction to order. What FR-5 actually requires is behavioural, and it is asserted behaviourally by `check_r3` at the integration layer, from inside a session, against a canary.
  For the record, and because a future feature may want it: in `extends`, list fields **union**, single-value fields (`binary`, `allow_gpu`, `workdir`, `security.*`) **replace**, `network.block` is **sticky-true**, `open_urls` **replaces the base entirely**, and `hooks` / `env_credentials` / `custom_credentials` merge as maps with the child winning.
  Everything above that this environment depends on is asserted, not assumed, by `check_component_merge`, which reads the resolved manifest rather than reasoning about the source. `M1e` established that the schema describes fields and not how they combine, so nothing here may be taken from the schema alone.

<a id="d5"></a>

- <a id="d5"></a>**D5 — The pre-flight is functional, not introspective.** It asserts *enforcement* by observing a denial, rather than probing kernel interfaces (`/sys/kernel/security/lsm`, Landlock ABI, cgroup v2). Introspection lost because the probe list is bubblewrap-shaped: nono uses Landlock and needs neither user namespaces nor cgroups v2, so a passing probe would prove the wrong thing, and a functional probe cannot pass for the wrong reason. Cost: two extra `nono` launches per agent start. Accepted unmeasured; if it hurts, cache per boot under `$XDG_RUNTIME_DIR`, which is a later change.
  **"A functional probe cannot pass for the wrong reason" was false as first sketched, and `M4a` corrected it.** The sketch put the canary at `$HOME/.agent-sandbox-preflight.$$` and read a failed write as proof of confinement. A write can fail because it was denied, or because it was never going to succeed — and on a host where `$HOME` is not writable by the user the two are indistinguishable from the outside. This repository's own development sandbox is such a host, which is how the defect was found, but it is not a property of it: the guard would report enforcement on any such machine having observed nothing. So the pre-flight now carries its own positive control, which is [D9](#d9)'s rule applied to shipped code rather than to a check. It **first writes the canary unconfined and requires that to succeed**, and only then reads the confined write's failure as a denial. Where no such path exists the pre-flight refuses with `77` rather than guessing, because "enforcement cannot be demonstrated" and "enforcement is absent" get the same fail-closed answer.
  The canary is therefore chosen by observation rather than fixed: a path outside the project that the pre-flight has just proven it can write, preferring `$XDG_RUNTIME_DIR` over `$HOME` because it is writable on a host whose home is not and is granted by no group. `M4a` measured both here — `$HOME` refuses the unconfined write, `$XDG_RUNTIME_DIR` takes it and a confined child writing there gets exit 1 with no file.

<a id="d6"></a>

- <a id="d6"></a>**D6 — Default-deny environment filtering.** `environment.allow_vars` is written explicitly, so a provider key invented next year is denied without editing anything. Chosen over `deny_vars` with a blocklist of known key names, which lost because it is a value list that rots, where `allow_vars` is a property.
  `M1e` confirmed the key exists and `M1c` measured what it has to cut: an unfiltered session inherits **233** variables, including every `XDG_*` pointing at the host, `NONO_AUTO_MIGRATE=1` picked up from the prior-art module, and the devShell's entire `shellHook` body exported verbatim as a variable. A denylist would have had to anticipate all of that; the allowlist does not have to know it exists.

<a id="d7"></a>

- <a id="d7"></a>**D7 — Two systems by `lib.genAttrs`, not `flake-utils`.** No new input for six lines of code (P4, and the Constitution's preference for deleting complexity).

<a id="d8"></a>

- <a id="d8"></a>**D8 — `.agents/` is gitignored.** Closes the open Q9. Agent state is untracked project state, alongside `.cache/` and `.tmp/`.

<a id="d9"></a>

- <a id="d9"></a>**D9 — A check whose observable is a failure carries a positive control in the same session.** Forced by a defect found in review rather than chosen freely. `check_j6_1` was written twice as "assert exit 0", and exit 0 is what an ordinary tool returns *both* when trust reached it and when no interception happened at all — one observable for two opposite states of the feature, so the check would have passed with the feature deleted. The same hole is latent in every refusal scenario: if a session fails to start, the denied read fails, the canary file is absent and the canary variable is missing, and every assertion passes for the wrong reason.
  The rule: alongside the negative assertion, the same session performs the corresponding *permitted* action and it must succeed. A denied read of `$HOME/.ssh` is paired with a permitted read inside the project; a denied write to `$HOME` with a permitted write to the workdir; an absent `ANTHROPIC_API_KEY` with a present `TERM`. Where the property under test *is* a difference, the control is permanent and lives inside the check rather than being planted and reverted — that is not an exception to P2 but the strongest form of it.
  Second rule, from the same review: **`nono why` reports its verdict in the body and always exits 0**, including `command_policy_unavailable` for a query it could not answer. Any check reading it asserts on `.reason` as well as `.status`, and treats a `*_unavailable` reason as an error rather than as a refusal. `nono profile validate` is the opposite and may be read from its exit status.

<a id="d10"></a>

- <a id="d10"></a>**D10 — A confinement description names no parent and takes what it needs by group inclusion.** `M1e` found the mechanism ships **no agent preset** — nine built-in profiles, all language runtimes — so the original plan to extend a per-agent preset had nothing to extend, and the packaged descriptions that do exist grant the authenticating agent's whole credential directory read-write, which is the leak this feature removes. It also found that a description naming the built-in floor and one naming nothing resolve to **byte-identical** manifests, so naming it buys nothing.
  Chosen over extending a registry pack, which lost on P8 (a run-time fetch), on P1 (an inherited grant nobody here wrote), and on drift (a pack can change under a mechanism upgrade with nothing in this repository changing). Consequence: `/nix/store` is **absent from the floor**, so the execution substrate has to be declared — see [D15](#d15) for how, which is not by group inclusion.

<a id="d11"></a>

- <a id="d11"></a>**D11 — The version-control toolchain is directed at configuration this environment wrote.** Observed, not theorised: a session granted the host's global git configuration read it, found `credential.helper = cache`, and tried to start a **long-lived daemon** writing inside the project. It failed only because that session's workdir happened to be read-only. Read-only grants are no protection here, because the danger is in the directives rather than in the bytes — the same class as `core.hooksPath`, which this plan already declined a grant for, reached through a key that looked harmless.
  So: no host git configuration file is granted, the mechanism's own `git_config` group is **not** included, and `GIT_CONFIG_GLOBAL` is pointed at a project-owned file with `GIT_CONFIG_SYSTEM=/dev/null` via `environment.set_vars`. This is FR-23 and refusal R10.
  Withholding the grant alone was rejected: it stops the read but leaves the effective configuration whatever the machine happens to have, and leaves no commit identity. Directing it makes the configuration identical on every machine, which is what the repetition scenarios ask for. `user.name` and `user.email` are copied out of the host once at setup — they are not credential material, the copy is visible in the file it produces, and a consumer may override.

<a id="d12"></a>

- <a id="d12"></a>**D12 — Interception is per-destination and off by default; trust propagation is asserted as a difference.** `network.tls_intercept` has no on switch. A plain-string `allow_domain` entry is a tunnel and nothing is inspected; an object entry with `endpoints` is inspected, and only then does the mechanism mint a per-session authority and export it as `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE` and `GIT_SSL_CAINFO`. An unfiltered session carries none of those five.
  Two consequences. FR-17 is bounded: trust is propagated for the destinations a description asks to inspect, not universally. And FR-17 cannot be checked by watching an ordinary tool succeed, because `/etc/ssl` and `/etc/pki` are in the floor and the tool validates the real certificate perfectly well with interception switched off — see [D9](#d9) and the three-arm `check_j6_1`.

<a id="d13"></a>

- <a id="d13"></a>**D13 — `HOME` and `XDG_STATE_HOME` are left pointing at the host, deliberately.** Neither is redirected into the project. For `XDG_STATE_HOME` there is no choice: the mechanism anchors its protected state root there and refuses to grant any path overlapping it, so redirecting it into the checkout would make the workdir ungrantable and the session would not start.
  For `HOME` it is a choice, and the case for redirecting is real — it would relocate most tools for free. It lost on P9 and on AGENTS.md §3: the host home is *denied*, so a tool that ignores its own relocation variable **fails outright**, and that failure is the feature. Setting `HOME` into the project would convert every such failure into a silent success writing somewhere nobody declared, and `M1g`'s whole question — whether the reference agent's own variables cover everything it writes — would become unanswerable by observation.

<a id="d14"></a>

- <a id="d14"></a>**D14 — The other agents take their credential from the mediated session, not from the first agent's store.** FR-7 spans agents as well as projects, and there were two ways to reach that. The prior art shares credentials by plugin: one agent shells out to another, or reads its credential file directly, which needs that credential directory granted read-write inside the boundary. This environment instead lets the mechanism capture the token flow into its supervisor-side store and exposes it to every process in the session as an environment variable plus a mediated base URL, picked up by `opencode` through its provider options and by `pi` through its provider base URL and header interpolation.
  This is **forced rather than preferred**: FR-6 and FR-3 together already exclude the alternative, since granting the credential store would put a credential that works outside the boundary inside it, on a justification of convenience rather than of structural impossibility. Sequencing consequence: `opencode` and `pi` depend on the captured credential, so the credential milestone lands before the remaining agents finish.

<a id="d15"></a>

- <a id="d15"></a>**D15 — The execution substrate is granted by path and registered, not inherited from a group.** `M3c` measured what [D10](#d10) had assumed. Three findings, each against `nono` 0.73.0:

  1. `filesystem.read = [ storeDir ]` grants **read only**. `nono why --path /nix/store --op write` answers `denied`, with `Path is covered by '/nix/store', which grants read access from profile but write was requested`. D10's premise that a path grant would make the store writable is false, and the agent table's claim that a group "grants exactly the access it was written for where a path grant gives read and write" is false with it.
  1. The `nix_runtime` group contributes **seven** read grants, not four: the store, two individual store paths, `/nix/var/nix/profiles`, `/etc/profiles/per-user`, and **two paths under `$HOME`** (`$HOME/.nix-defexpr`, `$HOME/.local/state/nix/profiles`). So declaring the store by path is *strictly narrower* than including the group — this decision removes reach rather than adding it, and removes home reach in particular.
  1. There is no middle ground between the two. See the Landlock note below.

  The store is therefore the leak registry's one entry, with `builtins.storeDir` as its path so that the value is derived rather than restated, and `groups` is empty for every agent. The registry already feeds `filesystem.read`, so no second mechanism appears: the grant *is* the entry, which is what makes `check_sc1`'s equality hold by construction and keeps the compromise somewhere a reviewer reads.

  **Provisional, and knowingly so.** FR-3 asks for a structural justification and this entry's is temporal: the store closure of a session cannot be computed before the agent package exists, which is `M4b`. `M4c` replaces the entry with a `closureInfo`-derived grant set. The measurement that makes that worth doing: `strace` over a real session needs **55** store paths where the static closure of the same tool set grants **62**, so the closure is a tight upper bound rather than a guess, and the whole store is tens of thousands of paths of which a few hundred are `*-source` trees belonging to unrelated projects — 67,051 and 251 when last counted, and rising. Read-only cross-project source disclosure is precisely what this repository exists to prevent, so the wholesale grant is a two-milestone compromise and not an end state.

  **What the replacement can be is decided by `PATH`, not by the agent.** `M4c`'s preconditions found that a confined session inherits `PATH` **whole**, host user profile included, although `PATH` is not in `allow_vars`; `set_vars.PATH` is rejected as reserved, and `deny_vars: [ "PATH" ]` has no effect. So the session can name any binary the shell around it could, and the substrate cannot be the *agent's* closure: under the agent's own 17 paths the agent's Bash tool cannot run `ls`. The grant has to cover everything on the session's `PATH`, which makes the honest root set the very list that puts those entries there — one nix list serving both as the devShell's `packages` and as `closureInfo`'s `rootPaths`, so criterion 1's "cannot drift" holds by construction. Its corollary is deliberate and welcome: a tool that resolves only from the host user profile stops working inside a session, which is `AGENTS.md` §3 enforced by the kernel rather than by review.

  **Landlock is allow-only, so a deny cannot carve a hole in a granted parent.** `filesystem.deny = [ "/nix/store/*-source" ]` beside a store grant passes `nono profile validate --strict` and appears verbatim in the resolved manifest, and then the session refuses to start: `Landlock deny-overlap is not enforceable on Linux. Refusing to start with conflicting policy. 1082483 deny rule(s) cannot apply under an allowed parent directory.` An exact-path deny fails identically with one conflict. Two consequences. The narrowing in `M4c` has to be a narrower *grant*, because there is no subtractive option at any granularity. And the Landlock constraint this plan records below is **enforced by the mechanism at initialisation**, not merely assumed by us — which makes a deny-group path inside a project checkout a startup refusal rather than a warning, and that is `M4b`'s risk to clear.

  **`nono why` is not a proxy for enforcement.** It answered `denied` / `filesystem_deny` for exactly the path whose deny the kernel cannot enforce and whose session will not start. This extends D9's second rule: a `why` verdict is a statement about nono's static resolution, so a claim about what the kernel does is an integration-layer claim and can never be made from `why` or from a manifest.

<a id="d16"></a>

- <a id="d16"></a>**D16 — A commit needs no key: unsigned by default, and a signature arrives as a socket rather than a directory.** Demonstrated rather than reasoned. Every commit made while implementing this feature failed the same way — `M3c`, and since then `M3d`, `M4a` and the `M4b` precondition commit — with `gpg: failed to create temporary file '/home/pallon/.gnupg/…': Permission denied`, and `git` then reporting `fatal: failed to write commit object`. That is from a session confined by a different mechanism, but with exactly the denial shape a confined agent session will have. The failure fires on the *first* commit, so it is the first thing a consumer meets rather than an exotic path, and four for four is the evidence that it is the ordinary case rather than a stumble.

  Three parts. The configuration this environment writes ([D11](#d11)) does not ask for a signature, so the default commit is unsigned and reads nothing outside the project. A key directory is not admissible as a registry entry, because FR-3's test is whether the tool can be directed elsewhere and a key can: `ssh` and `gpg` both take theirs from an agent over a socket, so the grant would rest on convenience. And where a consumer does want signatures, the socket is forwarded at invocation under FR-15 — nono carries a family of `--allow-unix-socket` flags for precisely this — which keeps the widening a visible act by the human rather than a property of the repository.

  The one case the environment cannot configure away: git's repository-local configuration outranks the global file this environment writes, so a checkout demanding `commit.gpgsign` demands it inside the session too. That is R11, and **P9** decides its shape — the commit fails and the message names the key, rather than being silently written unsigned. Overriding the checkout's own policy would be the silent fallback P9 forbids, and it would mean this environment quietly producing commits a project has decided it does not accept.

  **Which configuration made the observed failures, measured rather than assumed, and it is the opposite of what the paragraph above describes.** `git config --show-origin commit.gpgsign` names `file:/home/pallon/.gitconfig` — the *global* file. Under D11's redirection, `GIT_CONFIG_GLOBAL` at a project file and `GIT_CONFIG_SYSTEM=/dev/null`, the same query exits 1: the setting is not present anywhere. So the four failures this feature met are the case FR-24 **configures away**, not the case R11 refuses, and the first paragraph must not be read as evidence that a confined session cannot commit. Confirmed end to end in a throwaway checkout with that redirection and no per-invocation override: the commit exited 0, the object was written, and it carried zero `gpgsig` lines with `git verify-commit` silent. D16's mechanism is therefore verified, not merely argued.

  Two consequences. `check_r11` **must plant its demand in the checkout's own `.git/config`**, because a demand set globally is erased by `GIT_CONFIG_GLOBAL` and the check would then assert nothing while appearing to pass — which is why `M7f`'s criterion says *a checkout whose own configuration demands a signature* and why that wording is load-bearing rather than incidental. And developing this repository still needs `git -c commit.gpgsign=false` per commit, because a developer commits from outside a confined session, where nothing sets `GIT_CONFIG_GLOBAL`. That is a fact about working here, not a defect in the product.

<a id="d17"></a>

- <a id="d17"></a>**D17 — The authoring surface is declared outside every project, granted read-only, and pointed at rather than copied.** FR-25 needs three separate answers, and conflating them is what made FR-21 wrong for a whole feature: *who declares it*, *how the grant is shaped*, and *how the agent is then told where to look*.

  **Who declares it: the machine, by the calling-environment half of FR-15.** `.envrc` already calls `source_up_if_exists`, and the plan already accepts that as "a personal, machine-level concern" — the declaration rides the same channel. A consumer sets it once above their checkouts and every project of theirs picks it up; a stranger who clones a project inherits an unset variable and gets the FR-2 default. That satisfies FR-25 and R5 at once without a new mechanism, because the declaration is *by construction* not a file inside any project directory. The alternative rejected: a key in the project's own configuration, which is exactly what R5 refuses and what `check_r5` plants.

  **How the grant is shaped: read-only, and enumerated per location.** FR-25 says the surface is lent rather than handed over, so the grant is a read grant. [D15](#d15) measured that `filesystem.read` really is read-only — `nono why --op write` answers `denied` under a read grant — so this is a property of the mechanism rather than an intention. It also means the grant must name the *authoring* directories individually and must not name an ancestor: `research.md`'s note on `$XDG_CONFIG_HOME/git` and the docs' warning that a grant on `~/.config/nono/` would expose `config.toml` and the installed packages are the same hazard, and for opencode specifically an ancestor grant on `~/.config/opencode` would also hand over `node_modules` and `plugin/`, which FR-26 excludes. `M11a` enumerates before anything is granted.

  **How the agent is told where to look: point, do not copy.** Measured for `opencode` at 1.18.18: the `skills.paths` configuration key takes absolute roots and scans them for `**/SKILL.md`, so the granted host path is named in the configuration this environment writes and no copy exists to go stale. `OPENCODE_CONFIG_DIR` is *not* the answer — the documentation lists agents, commands, modes and plugins as what it covers and skills are absent from that list, so it would cover part of the surface while looking like it covered all of it. The alternative rejected: materialising the surface into `$PWD/.opencode/skills`, which needs no grant at all and is genuinely tempting, but a copy has to be reconciled on every entry and P8's idempotency would then have to be proven over a mutable host directory rather than asserted over a path.

  **One measured hazard this decision exists to contain.** `~/.agents/skills` and `~/.claude/skills` are read `$HOME`-relative rather than through any XDG variable, so they were reachable from a session that declared nothing — observed while diagnosing this, where a session under the blanket `XDG_CONFIG_HOME` still listed nine skills, all of them from `~/.agents/skills`. That is FR-2 broken by accident wearing FR-25's clothes. It is also why `check_j8_2` asserts the *undeclared* case as a set equality rather than trusting that nothing was granted, and why `M11a` is a spike rather than a design step: `claude-code`'s and `pi`'s locations are still unmeasured, and this one was found by observation after being missed by reading.

## Repository layout

```text
.
├── flake.nix                        modified  description, 2 systems, devShell, packages, checks
├── flake.lock                       modified  nono + agent packages pinned
├── .envrc                           comment only the two bootstrap variables resolve alike
├── .gitignore                       modified  Kafka rules out; /.agents/ in
├── README.md                        new       AGENTS.md §6: component table + 2 mermaid diagrams
├── devenv.nix                       deleted   the container and its four bind mounts
├── devenv.yaml                      deleted
├── ai.nix                           deleted   knowledge absorbed into lib/
├── draft1.md                        deleted
├── draft2.md                        deleted
├── lib/
│   ├── agents.nix                   new       the three agents: package, groups, state variables
│   ├── leak-registry.nix            new       FR-3, the single file, expected empty
│   ├── confinement.nix              new       mkConfinementDescription :: agent -> store path
│   └── confined-agent.nix           new       mkConfinedAgent  :: agent -> writeShellApplication
├── scripts/
│   ├── validate.sh                  new       FR-12, the only entry point
│   └── checks/
│       ├── unit.sh                  new       nix eval only; no build, no $HOME
│       ├── component.sh             new       nono profile validate / show / why
│       ├── integration.sh           new       real confined sessions in this checkout
│       └── e2e.sh                   new       from the canonical ref into a clean $HOME
├── .github/workflows/verify.yml     new       FR-13, ubuntu-latest + macos-latest
├── docs/{HANDBOOK,CONSTITUTION}.md  modified  at close-out
└── specs/001-agent-sandbox/
    ├── spec.md                      modified  D2 correction at line 272
    ├── plan.md                      new
    ├── tasks.md                     new
    └── research.md                  new       spike outputs from M1
```

## Implementation shapes

Signatures and structures, laid out so implementation is mechanical. Types in `∷` notation; `w` denotes the literal string `"$WORKDIR"`, expanded by nono at run time and never by Nix or the shell.

### `lib/agents.nix`

The sketch below is the table's final shape, not its first one. `M3b` wrote only `groups` and `stateVars`, and only for `claude-code`, because a field nothing reads is how a table starts lying: `package` and `binary` arrive with `M4`, which builds the entry point that runs them, `credential` with `M7`, which asserts its shape, and the other two agents with `M8`, where the checks that observe them live. The type is a `submodule` evaluated per entry, so each field is enforced from the moment it exists.

```nix
# agent ∷ { package, binary, groups, stateVars, credential }
# The set of agents is closed (FR-1) and keyed by name; P9 forbids a silent
# lookup miss, so callers use `agents.${name} or (throw …)`.
#
# There is no `preset` field: M1e found the mechanism ships no agent preset, so
# every description is authored here (D10). `groups` names the built-in security
# groups it includes — never `git_config`, per D11, and never `nix_runtime`,
# per D15: the store is granted by path from the registry instead.
{ lib }:
{
  claude-code = {
    package   = pkgs: pkgs.claude-code;         # unfree; allowUnfree scoped to this pkgs
    binary    = "claude";
    groups    = [ ];                            # the substrate comes from the registry (D15)
    # M1g observed which of the thirteen candidates govern: three do, and
    # together they cover the whole default home layout. The rest are set by
    # M8b for the paths a one-turn session never reaches. XDG_* is absent
    # because M1g found claude ignores it entirely, despite the strings count.
    stateVars = w: {
      CLAUDE_CONFIG_DIR             = "${w}/.agents/claude";
      CLAUDE_CODE_TMPDIR            = "${w}/.agents/claude/tmp";
      CLAUDE_CODE_REMOTE_MEMORY_DIR = "${w}/.agents/claude/memory";
      DISABLE_AUTOUPDATER           = "1";   # M1g: inherited on the dev host, so P8 needs it set here
    };
    credential = { tokenHost = "platform.claude.com"; apiHost = "api.anthropic.com"; };
  };
  opencode = {
    package   = pkgs: pkgs.opencode;
    binary    = "opencode";
    groups    = [ ];
    # Its own variables, not XDG_DATA_HOME: P1 forbids a blanket XDG override
    # where the tool exposes a specific one.
    stateVars = w: {
      OPENCODE_CONFIG     = "${w}/.agents/opencode/config.json";
      OPENCODE_CONFIG_DIR = "${w}/.agents/opencode";
    };
    credential = { … };                         # from the mediated session, D14
  };
  pi = {
    package   = pkgs: pkgs.pi;
    binary    = "pi";
    groups    = [ ];
    stateVars = w: {
      # The whole root: settings, credentials, sessions and installed packages.
      # PI_CODING_AGENT_SESSION_DIR is documented but absent from the binary — M1d.
      PI_CODING_AGENT_DIR = "${w}/.agents/pi";
      # FR-22: with no packages declared there is nothing to install on startup,
      # and this also stops the update check and the model-catalogue refresh.
      PI_OFFLINE = "1";
    };
    credential = { … };                         # from the mediated session, D14
  };
}
```

### `lib/leak-registry.nix`

```nix
# FR-3. The single file. One entry at landing: the execution substrate (D15).
# entry ∷ { path ∷ str, mode ∷ enum ["read" "readwrite"],
#           agents ∷ listOf agentName, why ∷ str, whyNotNarrower ∷ str }
{ lib }:
{
  entryType = lib.types.submodule { options = { … }; };   # P7: never attrsOf str
  entries = [
    # An entry is admissible only where the tool structurally cannot be directed
    # elsewhere (FR-3). One qualifies: `builtins.storeDir`, read, because a
    # session cannot execute without the substrate its binaries live in and the
    # closure was not computable until M4b packaged them; M4c narrows it and
    # this entry then goes or is rewritten (D15). The mechanism's
    # own state root is NOT an entry: nono refuses any grant overlapping it, so
    # it cannot be granted at all (D2).
  ];
}
```

Invariants asserted by `check_registry` (unit layer, `nix eval`):

- `∀ e ∈ entries. e.why ≠ "" ∧ e.whyNotNarrower ≠ ""`
- `∀ e ∈ entries. ¬ (e.path ⊑ "$WORKDIR")` — an entry inside the project is a mistake, not an exception
- `∀ e ∈ entries. ∀ a ∈ e.agents. a ∈ attrNames agents`

### `lib/confinement.nix`

```nix
# mkConfinementDescription ∷ { agent, name, registry } → derivation (a JSON file)
# Emits one nono profile. Static: $WORKDIR expansion makes it project-independent,
# so nothing is generated per project (P8, and the spec's validated assumption).
{ lib, pkgs, agents, registry }:
name:
let
  a = agents.${name} or (throw "agent-sandbox: unknown agent '${name}'. Known: ${…}");
  w = "$WORKDIR";
  mine = builtins.filter (e: builtins.elem name e.agents) registry.entries;
in
pkgs.writeText "nono-profile-${name}.json" (builtins.toJSON {
  "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";
  # `name` is required — omitting it is a parse error, not a default (M1e).
  meta = { inherit name; version = "1"; description = "agent-sandbox confinement for ${name}"; };
  # No `extends`. D10: there is no agent preset to extend, and naming the
  # built-in floor resolves byte-identically to naming nothing.
  workdir = { access = "readwrite"; };
  # `groups` is { include, exclude } — not a map of names to booleans (M1e).
  groups = { include = a.groups; };
  filesystem = {
    allow = map (e: e.path) (builtins.filter (e: e.mode == "readwrite") mine);
    read  = map (e: e.path) (builtins.filter (e: e.mode == "read")      mine);
    # NOT granted, and each omission is deliberate:
    #   $XDG_STATE_HOME/nono  nono refuses any grant overlapping its state root
    #   $XDG_RUNTIME_DIR      holds gnome-keyring secrets, ssh sockets, the D-Bus bus
    #   any host git config    a directive in one runs a program inside the
    #                          boundary — observed, not theorised (D11). This is
    #                          also why the `git_config` group is not included:
    #                          read-only is no protection when the danger is the
    #                          directive rather than the bytes.
  };
  environment = {
    allow_vars = [ "HOME" "USER" "LOGNAME" "TERM" "LANG" "LC_*" "PWD" "SHELL" "TZ" "COLORTERM" ];
    set_vars   = (a.stateVars w) // {
      # D11 / FR-23. The toolchain is directed, not merely denied, so its
      # effective configuration is the same on every machine.
      GIT_CONFIG_GLOBAL = "${w}/.agents/git/config";
      GIT_CONFIG_SYSTEM = "/dev/null";
    };
  };
  network = { … };            # filled by M7 per D1, D12 and D14
})
```

`set_vars` cannot carry `NONO_NO_UPDATE_CHECK`, and `M3b` found out which way that fails. The prefix is not merely ignored: `validate` rejects the description outright with `Invalid set_vars key 'NONO_NO_UPDATE_CHECK': the NONO_* prefix is reserved`, exit 1, and `PATH` is refused the same way. So the description cannot suppress the update check, and the entry point exports the variable itself before it `exec`s — which is where it belongs anyway, since the call it suppresses is made by the supervisor rather than inside the boundary.

`HOME` is allowed through but **not** rewritten — D13. It reaches the session as the host home, which is denied, so a tool that ignores its own relocation variable fails outright rather than writing somewhere nobody declared. The `XDG_*` variables are absent from `allow_vars` for the same reason in reverse: leaving them pointing at host paths would have a tool fail at a path this environment never chose, where dropping them makes it fall back to its own default under `HOME` and fail there, which is the one denial the pre-flight already proves.

Note the Landlock constraint: granting `$WORKDIR` recursively is safe only because no deny-group path lies inside a project checkout. If one ever does, the session does not start at all — nono checks for deny-overlap before it calls `landlock_restrict_self` and refuses ([D15](#d15)). So this is a condition on every project that consumes the environment, not only on ours, and `check_component_merge` asserts no overlap.

### `lib/confined-agent.nix`

```nix
# mkConfinedAgent ∷ name → writeShellApplication, /bin/${binary}
{ pkgs, agentPkgs, agents, confinement }:
name:
let
  agent = agents.${name}.package agentPkgs;
  binary = agent.meta.mainProgram;              # D3: shadows the agent name
in
pkgs.writeShellApplication {
  name = binary;
  runtimeInputs = [ agentPkgs.nono ];
  text = ''
    mkdir -p "''${XDG_CONFIG_HOME:?…}"          # M1e: absent ⇒ nono falls back to ~/.config
    export NONO_NO_UPDATE_CHECK=1
    PREFLIGHT_PROFILE=${confinement name}
    ${builtins.readFile ../lib/preflight.sh}
    preflight_or_die
    exec nono run \
      --profile ${confinement name} \
      --workdir "$PWD" \
      --allow-cwd \
      -- ${agent}/bin/${binary} "$@"
  '';
}
```

There is no `preflightProfile` parameter. `M4a` found that the pre-flight asserts a property of the *host*, so the profile it tests under may as well be the one the agent is about to run under: a second description whose only consumer is the pre-flight would be another artefact to keep true, and P4 wants no option nothing else exercises. The wrapper therefore sets `PREFLIGHT_PROFILE` to the same store path it passes to `exec`.

There is no `binary` field on the agent either, and no `pkgs`-shaped `package`. Both were in this sketch and `M4b` removed them. `meta.mainProgram` already names the command, so reading it off the package about to be run leaves nothing to drift; and the packages come from llm-agents.nix's own set for the system, so `package` is a function of *that* rather than of `pkgs`, which is also what keeps them the derivations the publisher's cache holds.

`--allow-cwd` is not decoration. `M4b` measured that `workdir.access` in the description sets what the working-directory consent is *worth*, while the flag is the consent: without it a non-interactive session is granted no part of the project at all, and — worse for anyone debugging it — the resolved manifest still says `readwrite`.

### The pre-flight (`lib/preflight.sh`)

It is a file rather than a nix string, because `M4a`'s `check_r6` sources it directly and a string interpolated into a derivation cannot be sourced by a check. `shellcheck` reads it for the same reason.

Assertion 2 is the one the first draft lacked, and [D5](#d5) records why it is not optional. The canary prefers `$XDG_RUNTIME_DIR` because it is writable on a host whose `$HOME` is not, and no group grants it, so a confined write there is denied for the reason the pre-flight is claiming.

```bash
# FR-10 / R6. Functional, not introspective (D5). Four assertions, because P9
# forbids letting "nono could not start" or "the canary was never writable"
# look like "the child was denied".
preflight_or_die() {
  local canary rc
  canary="${XDG_RUNTIME_DIR:-$HOME}/.agent-sandbox-preflight.$$"

  # 1. A confined process can start at all.
  if ! nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" -- true >/dev/null 2>&1; then
    die 77 "cannot start a confined process. nono failed to initialise."
  fi

  # 2. The positive control (D5, D9). Unconfined, this write must succeed, or
  #    its later failure says nothing about confinement. Fail closed: a canary
  #    we cannot write is a pre-flight we cannot run.
  if ! : >"$canary" 2>/dev/null; then
    die 77 "cannot verify confinement: no writable path outside the project to test against."
  fi
  rm -f "$canary"

  # 3. Confined, the same write must be denied.
  nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" \
    -- sh -c ": > \"$canary\"" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$canary"
    die 77 "confinement is not enforced: a confined process wrote outside the project."
  fi

  # 4. And it genuinely did not write it.
  if [ -e "$canary" ]; then
    rm -f "$canary"
    die 77 "confinement is not enforced: the denial was reported but the write landed."
  fi
}

# The exit status is pinned because a caller branches on it (FR-10). The message
# names the missing primitive so the user is not left guessing.
die() {
  printf 'agent-sandbox: %s\n' "$2" >&2
  printf 'agent-sandbox: required: kernel-enforced filesystem confinement (Landlock ≥ 5.13 on Linux, Seatbelt on macOS).\n' >&2
  printf 'agent-sandbox: refusing to start an agent. There is no override.\n' >&2
  exit "$1"
}
```

### `scripts/validate.sh`

```bash
#!/usr/bin/env bash
# FR-12. The only place these assertions live. Layers run cheapest-first so a
# fast failure is a fast failure.
set -euo pipefail
usage: validate.sh [--layer unit|component|integration|e2e] [--list]

# Each scenario in spec.md has exactly one function, named for it (SC-3):
#   check_j1_1 check_j2_1 check_j3_1 check_j4_1 check_j5_1 check_j6_1 check_j7_1
#   check_r1 … check_r10
#   check_rep1 check_rep2 check_rep3
# plus derived-property checks: check_sc1 check_sc2 check_sc3 check_registry
#   check_bootstrap_mirror check_component_merge
```

`check_sc3` is the bijection, and it is the first thing written. It landed in `M1a`; the shape below is the sketch it was built from, and the implementation in `scripts/checks/unit.sh` is the truth. Two things changed on contact: the checks live in `scripts/checks/<layer>.sh` rather than inside the driver, so the file is the layer declaration; and the parser scans only the spec's `## Scenarios` section, because the risk list and the review checklist also number their bullets.

```bash
# RED before anything else exists.
check_sc3() {
  local spec_ids impl_ids
  spec_ids=$(spec_scenario_ids "$SPEC")            # j<N>_<ordinal>, r<N>, rep<N>
  impl_ids=$(suite_scenario_check_ids)             # from scripts/checks/*.sh
  comm -23 … && comm -13 …                         # names the difference in both directions
    || fail "scenario ↔ check bijection broken"
}
```

`check_sc1` derives its expectation from the registry rather than restating it (Journey 7, third `Then`):

```bash
# granted(agent) ∖ floor  =  {$PWD} ∪ {e.path | e ∈ registry, agent ∈ e.agents}
check_sc1() {
  # The floor is subtracted, not listed (D4). Deriving it from the description
  # under test with every capability key stripped means a floor that grows in a
  # later nono release moves the baseline instead of breaking the check.
  jq '{meta}' "$profile" > "$tmp/floor.json"
  # --format manifest, not profile: M1e found `profile` is the human rendering
  # and `manifest` the only JSON one. Its resolved shape is filesystem.grants[],
  # each {access, path, type} — not the source profile's allow/read lists.
  manifest_grants "$profile"        "$cfg" > "$tmp/agent.grants"
  manifest_grants "$tmp/floor.json" "$cfg" > "$tmp/floor.grants"
  registry=$(nix eval --json .#leakRegistry \
             --apply "es: builtins.filter (e: builtins.elem \"$agent\" e.agents) es")

  while IFS=$'\t' read -r access path; do   # ⊆ direction
    under_project "$path" || in_registry "$path" "$registry" \
      || fail "granted path outside project and not in registry: $path ($agent)"
  done < <(comm -13 "$tmp/floor.grants" "$tmp/agent.grants")

  # The ⊇ direction: under_project records that it saw the project's own grant,
  # and every registry entry must appear in agent.grants with its declared mode.
  # That is what makes a stale entry a failure rather than dead text.
}
```

`manifest_grants` runs the resolver from the repository root, because `nono profile show` has no `--workdir` and `$WORKDIR` is therefore its cwd, and normalises `/proc/<pid>` away, because nono grants the resolving process its own `/proc` entry and that differs between two invocations. It must never redirect the resolver's stdout to a file it then compares: nono grants stdout's file `readwrite`, so the comparison would find the comparison's own artefact.

## Dependencies & impact

- **Files touched**: `flake.nix`, `flake.lock`, `.gitignore`, new `lib/` (4 files), new `scripts/` (5 files), new `.github/workflows/verify.yml`, new `README.md`, `docs/HANDBOOK.md`, `docs/CONSTITUTION.md`, `AGENTS.md` (one sentence). Deleted: `devenv.nix`, `devenv.yaml`, `ai.nix`, `draft1.md`, `draft2.md`.
- **Consumers affected**: none exist yet. The devcontainer path disappears; `docs/HANDBOOK.md` currently documents it as unverified, so nothing verified is withdrawn.
- **Inputs added or bumped**: `nixpkgs` re-locked. A pinned `numtide/llm-agents.nix` input is added — `M1f` found `pi` absent from nixpkgs entirely, which was the condition. It is the **sole** source of `nono`, `claude-code`, `opencode` and `pi`, both in the environment a human enters and in every check, so that one pin describes what is verified and what is shipped. Its `nixConfig` is not inherited by a consumer of this flake, so `https://cache.numtide.com` and its key `niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=` are declared here as well and passed explicitly in CI; without that, a clean machine builds every one of them from source.
- **Tools added to the environment**: `nono` (the mechanism), `shellcheck` + `shfmt` (AGENTS.md names them; added to the devShell in `M3a`, having resolved only from a user profile until then), `jq` (checks parse JSON; P9 requires generated JSON be validated rather than eyeballed).
- **Docs to update at close-out**: `docs/HANDBOOK.md` — the Known drift entries for the Kafka leftovers, the four devcontainer bind mounts, the orphaned `ai.nix`, the stray `^`, the missing `scripts/validate.sh` and the absent `shellcheck`/`shfmt` were each retired by the task that falsified them, since a drift entry about code that no longer exists is fiction; what remains for close-out is the missing `README.md` and adding the accepted-leak entry for `$XDG_STATE_HOME/nono` and the coverage gap. `README.md` — new. `AGENTS.md` — the "no CD pipeline" sentence gains "non-deploying CI is permitted". `docs/CONSTITUTION.md` — P1's accepted-leak list gains its second entry.

## Test strategy

| Layer | Where | Needs | Covers |
| --- | --- | --- | --- |
| **Unit** | `nix eval`, `scripts/checks/unit.sh` | nothing — no build, no network, no `$HOME` | Registry invariants; the scenario ↔ check bijection (`check_sc3`); the bootstrap-variable mirror between `.envrc` and `flake.nix`; agent-table totality |
| **Component** | `nono profile validate` / `show` / `why` against generated profiles, `scripts/checks/component.sh` | an evaluator and `nono`, no kernel enforcement | Generated JSON validates against nono's schema; the three-way merge is what D4 claims; granted reach `= $WORKDIR ∪ registry` (`check_sc1`); no deny-group path lies inside a project checkout |
| **Integration** | real confined sessions in this checkout, `scripts/checks/integration.sh` | a build and a real kernel | Every refusal R1–R6 and R8–R10; Journeys 2, 3, 4, 6; the pre-flight; environment filtering. **This is the only layer where kernel enforcement is observed at all** |
| **End to end** | `nix develop github:GRBurst/agent-sandbox` with `HOME=$(mktemp -d)`, `scripts/checks/e2e.sh` | a build and a clean machine | Journeys 1, 5, 7; Rep1, Rep2; SC-5. Run in CI on both platforms from the pushed ref, never from the working tree |

**Why the layer split is load-bearing here.** nono resolves its policy in userspace and only then calls `landlock_restrict_self` / `sandbox_init`. So `nono profile show` and `nono why` work inside a Nix build, and `check_sc1` is hermetic — but they prove what nono *would* grant, not what the kernel *does* enforce. R1 and R2 are therefore fundamentally integration-layer and can never move up. Conversely nono's own tests are skipped inside Nix builds for exactly this reason (`Refusing to grant '/nix' … overlaps protected nono state root`), so `nix flake check` must not be asked to do it.

**Clean-home discipline.** Every integration and e2e check runs under `HOME=$(mktemp -d)`. This is not hygiene, it is correctness: nono derives its protected state root from `$HOME`, so a check that inherits the developer's home is testing a different configuration than CI is.

### Type checking and static analysis

Nix has no typechecker; these are the analogues, run in this order because each is cheaper than the next.

| Stage | Command | Catches |
| --- | --- | --- |
| 1 | `nix eval --json .#leakRegistry` etc. | Submodule type errors — a registry entry missing `whyNotNarrower`, an unknown agent name in `agents` |
| 2 | `nix flake check` | devShell and package evaluation on both systems; `checks.*` (unit + component layers) |
| 3 | `nono profile validate <generated>` | The generated JSON against nono's published schema — P9's rule that generated JSON is validated, never eyeballed |
| 4 | `shellcheck scripts/**/*.sh` + `shfmt -d` | Unquoted expansions, missing `set -euo pipefail`, the `${!v}` bashism that forces bash over zsh |
| 5 | `nixfmt --check`, `statix`, `deadnix` | Formatting and dead code |
| 6 | `scripts/validate.sh` | Everything above plus the behavioural layers |

Run stages 1–2 after every Nix edit, 4 after every shell edit, 6 before every commit.

### Scenario coverage

Every row was audited against one question, after `check_j6_1` was twice written so that it would have passed with the feature deleted: **what would this check observe if the thing it tests were removed?** Where the answer was "the same thing", the row carries a positive control in the same session, per [D9](#d9). The control is named in the row, because a control left implicit is a control nobody writes.

| Scenario | Check | Layer |
| --- | --- | --- |
| Journey 1.1 | `check_j1_1` — enter from the ref into a clean `$HOME`, start `claude`, compare the session's `tracked_paths` to `{project} ∪ registry`. Discriminating because the observable is a *set*, not a verdict: with confinement removed the agent writes no session record, so there is nothing to compare. Read from the session rather than from the resolved manifest, because the manifest reports the project `readwrite` even for a session that was granted none of it | e2e |
| Journey 2.1 | `check_j2_1` — snapshot `$HOME`, run a session that writes history, diff, subtract registry, assert empty. **Control**: the same session's writes are found under `$WORKDIR/.agents`, so "nothing landed in `$HOME`" cannot be satisfied by a session that wrote nothing anywhere | integration |
| Journey 3.1 | `check_j3_1` — two checkouts, two **concurrent** sessions, write in one, assert the other unchanged. **Control**: the write is confirmed present in its own checkout | integration |
| Journey 4.1 | `check_j4_1` — assert every readable credential value matches the substitute form (mock credentials). **Control**: the real value is asserted present in the supervisor's store outside the boundary, so "the agent holds a substitute" is not satisfied by there being no credential at all. Live rejection is a coverage gap | integration |
| Journey 5.1 | `check_j5_1` — authenticate in checkout A, assert authenticated state in checkout B **and** in a second agent without a login of its own (FR-7's two axes). **Control**: a third, unauthenticated identity is asserted *not* to work, so the check cannot pass by treating everything as authenticated | e2e |
| Journey 6.1 | `check_j6_1` — three arms, see below. Narrowed from "push a commit" by [`M1c`](research.md#m1c--git-credentials-inside-the-boundary) | integration |
| Journey 6.2 | `check_j6_2` — commit in a throwaway checkout inside the project; assert the commit object exists, that it carries no signature, and that the configuration this environment wrote does not ask for one. **Control**: `check_r11` runs in the same session, so a session that cannot commit at all cannot satisfy this row | integration |
| Journey 7.1 | `check_j7_1` — `validate.sh` runs unattended per platform and reports success; then plant a registry entry and observe the expected set change **with the check unedited**. The second arm is the discriminator: exit 0 alone would also be produced by a suite that ran nothing, which is why `validate.sh` fails when no check ran | e2e |
| Journey 8.1 | `check_j8_1` — declare an authoring surface in a fake `$HOME`, holding one extension per location `M11a` enumerated; from inside a session, ask the agent to report the extensions it has and assert every planted one is named. **Control**: an extension planted at a location *not* declared is asserted absent in the same session, so "the surface arrived" cannot be satisfied by an agent that reports everything it can imagine. Second arm: the surface is compared before and after and must be byte-identical, which is FR-25's lent-not-handed-over clause | integration |
| Journey 8.2 | `check_j8_2` — the same planted surface with **no** declaration; assert the session's granted reach equals `{project} ∪ registry` exactly, and that the agent starts and reports none of the planted extensions. The set equality is the assertion, not the absence of an error: `$HOME`-relative extension roots were measured reaching a session that declared nothing, so "no grant was added" has to be observed rather than inferred. **Control**: `check_j8_1` in the same suite, so a run in which the declaration mechanism does nothing at all cannot satisfy both rows | integration |
| R1 | `check_r1` — plant an SSH key in the fake `$HOME`, read it from inside, assert the read fails and no key material appears in the output. **Control**: a file inside the project is read successfully in the same session | integration |
| R2 | `check_r2` — create a file in `$HOME` from inside; assert failure **and** non-existence. **Control**: the same write into `$WORKDIR` succeeds and the file exists | integration |
| R3 | `check_r3` — export `ANTHROPIC_API_KEY=<random canary>`, print the environment from inside, assert the canary is absent. **Control**: `TERM` is present, so an empty environment dump cannot pass | integration |
| R4 | `check_r4` — from inside a session, rewrite `lib/leak-registry.nix` to grant `$HOME`; assert reach unchanged now and on the next start before re-entry. **Control**: the edit is confirmed to have landed on disk, so "reach unchanged" is not satisfied by a write that never happened | integration |
| R5 | `check_r5` — place a project-level agent configuration requesting `$HOME`; assert reach unchanged. **Control**: the same session is shown to *read* that file for a benign setting, so the check proves the request was refused rather than the file ignored | integration |
| R6 | `check_r6` — three arms. Plant the violation the pre-flight exists to catch, by putting a passthrough `nono` on `PATH` so the canary runs unconfined; assert exit `77` and that the message names the primitive. A second plant points both `$XDG_RUNTIME_DIR` and `$HOME` at an unwritable directory, so assertion 2 is exercised on a machine where the canary location happens to be writable. **Control**: unplanted, the pre-flight exits 0 on the same machine, so `77` is attributable to the plant and not to a missing mechanism | integration |
| R7 | `check_r7` — grep the evaluated devShell for every Kafka artefact by name; assert none. **Control**: assert a package that *should* be there is found, so an evaluation returning nothing cannot pass | unit |
| R8 | `check_r8` — invalidate the stored substitute, make a request, assert the message is an authentication failure and **differs from** a denial message. The difference is the assertion; a single failure string proves nothing | integration |
| R9 | `check_r9` — a **differential**, in the shape the three-arm `check_j6_1` below and `M4c` both settled on. Populate the fake `$HOME` with a whole host-global agent configuration — stored credentials, conversation history, session state and a confinement description among it — and declare only the authoring surface. Assert that the readable set under the declaration minus the readable set without it is *exactly* the declared surface, so the check bites on anything the declaration drags in with it. Assert separately that no host confinement description took part in deciding reach, by comparing the session's granted paths against a run with the host description removed. **Control**: the session still starts and works, so an agent that read nothing cannot pass | integration |
| R10 | `check_r10` — plant a host git configuration carrying a directive that runs a program; from inside, assert the effective configuration is the one this environment wrote and the directive is absent. **Control**: a setting this environment *did* write is read back, so an empty configuration cannot pass. Second arm: no process was started and nothing was written outside `$WORKDIR` | integration |
| R11 | `check_r11` — a checkout whose *own* configuration demands a signature; assert the commit fails, that the message names the key material that could not be reached, and that no commit object was created. **Control**: `check_j6_2`'s unsigned commit in the same session, so the failure is attributable to the demand rather than to a session that cannot commit | integration |
| Rep1 | `check_rep1` — enter twice; assert tracked files unchanged and granted reach byte-identical | e2e |
| Rep2 | `check_rep2` — run `validate.sh` twice; assert same result and no residue | e2e |
| Rep3 | `check_rep3` — authenticate twice; assert the resulting state is indistinguishable | integration |
| SC-1 | `check_sc1` — the reach property, derived from the registry; `M4c` adds the trace arm that narrows the substrate to the session's own closure | component, then integration |
| SC-2 | `check_registry` — registry invariants | unit |
| SC-3 | `check_sc3` — the scenario ↔ check bijection | unit |
| P1 mirror | `check_bootstrap_mirror` — the bootstrap variables resolve to the same values in `.envrc` and `flake.nix` | unit |
| D4 | `check_component_merge` — the floor, the included groups and the description's own declarations combine as [D4](#d4) claims, read off the resolved manifest | component |
| D9 | `check_controls` — every refusal check invokes a positive control | unit |

Where a refusal is observed through `nono why` rather than by attempting the action, the check reads `.reason` as well as `.status` and treats any `*_unavailable` reason as an error — that command exits 0 for a refusal, for a grant, and for a question it could not answer ([D9](#d9)). And it is never the observer for a refusal the kernel has to enforce, because `why` answers from the resolved policy and will report a deny Landlock cannot apply at all ([D15](#d15)).

#### `check_j6_1`, in three arms

FR-17 is a *difference*, so one observation cannot carry it. Written out because this is the row that produced [D9](#d9):

1. **The mechanism engaged.** Inside a session whose description asks for a destination to be inspected, the five trust-bundle variables are set, and the file they name exists and parses as a certificate. Without this arm the check would pass with interception switched off entirely.
1. **The exchange did its work.** An ordinary credential-free HTTPS exchange with that destination returns the shape it should — matched as a pattern, not pinned to a value, so it survives the remote moving on.
1. **The negative control, in the same session.** Repeat arm 2 with the trust bundle pointed at `/dev/null`, and require failure with a certificate error. This is a **permanent** planted violation living inside the check rather than planted and reverted, because the property under test is precisely the difference between arms 2 and 3.

Arm 1 also has to be asserted rather than assumed: `M1c` first claimed the variables were always set, on the strength of their names appearing together in the binary, and an unfiltered session was then observed carrying **none** of them. Interception is per-destination ([D12](#d12)).

### Properties

Asserted as properties, derived from the system under test, so a new agent or a new registry entry needs no edit to the check.

- `∀ a ∈ agents. ∀ p ∈ granted(a). realpath(p) ⊑ $PWD ∨ p ∈ registry` — SC-1 with no override in force, and with the registry empty it collapses to equality, which is stronger
- `∀ a ∈ agents. granted(a | surface declared) ∖ granted(a) = locations(a)` — FR-25 and SC-9 as a difference over the agent table rather than a list of paths, so an agent whose locations `M11a` enumerates differently needs no edit to the check. Stated as equality in both directions: `⊇` is the surface arriving, `⊆` is nothing arriving with it
- `∀ a ∈ agents. ∀ p ∈ locations(a). ¬writable(p)` — FR-25's lent-not-handed-over clause
- `∀ a ∈ agents. ∀ (k,v) ∈ set_vars(a). v ⊑ "$WORKDIR"` — FR-4 as a property over the agent table, not a list of variable names
- `scenarios(spec.md) = checks(validate.sh)` as sets — SC-3
- `resolve(bootstrap_exports(.envrc)) ≡ resolve(shellHook(flake.nix))` over the names `.envrc` itself exports before handing over to the flake — P1. Comparing resolved values rather than source text, because nix's indented strings escape where a shell does not, so equal text is neither necessary nor sufficient
- `∀ e ∈ registry. e.why ≠ "" ∧ e.whyNotNarrower ≠ "" ∧ ¬(e.path ⊑ "$WORKDIR")` — FR-3
- `∀ a ∈ agents. deny_group_paths ∩ subtree($WORKDIR) = ∅` — the Landlock constraint that a broad grant must not span a deny path
- `granted(a) on linux ≡ granted(a) on darwin` — FR-20, asserted by comparing the two CI jobs' resolved output
- `∀ c ∈ refusal_checks. c invokes a positive control` — [D9](#d9) made enforceable rather than aspirational, by `check_controls` over the suite's own text, in the same spirit as `check_sc3`. It is a proxy: it establishes that a control is *called*, not that the control is apt. That is worth having anyway, because the failure mode being guarded against is forgetting the control entirely, which is what happened

Literals are pinned in exactly two places, and both are criteria rather than values: the exit status `77`, and the pre-flight's user-facing message.

### Planted violations

Mandatory per P2. Tick `Verified` only after seeing red, **and only after confirming the planting actually landed**. `M3b` planted an unknown top-level key with a `sed` whose pattern did not match the file, saw the check pass, and nearly recorded that as a check which does not bite. A planting that never applied and a check that never fires look identical from the outside, so the artefact is inspected for the violation before its absence is believed.

| Check | Violation planted | Must FAIL with | Verified |
| --- | --- | --- | --- |
| `check_sc3` | Delete `check_r5` from `scripts/checks/unit.sh` | `scenario ↔ check bijection broken` naming `r5` | [x] |
| `check_sc3` | Add an orphan `check_r99` to a green suite | `check with no scenario: r99` | [x] |
| `check_sc3` | Point `SPEC` at a file declaring no scenarios | `parsed no scenarios out of …; the parser and the spec have drifted` | [x] |
| `validate.sh` | Select a layer whose file carries no check | `no checks ran; the suite would report success without testing anything`, exit `2` | [x] |
| `validate.sh` | Pass an argument outside the accepted set | `unknown argument: --bogus`, exit `2` | [x] |
| `check_registry` | Add an entry with `whyNotNarrower = ""` | `registry entry '<path>' does not say why a narrower grant fails` | [x] |
| `check_registry` | Add an entry whose `path` is `"$WORKDIR/.agents"` | `registry entry inside the project is not an exception: $WORKDIR/.agents` | [x] |
| `check_registry` | Type `path` as `types.int`, so the type rejects a well-formed entry | `positive control absent: the entry type rejects a well-formed entry, so the rejection below proves nothing` | [x] |
| `check_registry` | Weaken `mode` from `types.enum` to `types.str` | `the entry type accepted a malformed entry: { … mode = "sideways"; … }` | [x] |
| `check_registry` | Give the submodule a `freeformType`, so a fifth key is admitted | `the entry type accepted a malformed entry: { … extra = true; }` | [x] |
| `check_registry` | Add any entry while `.#agents` does not yet exist | `the registry has entries but the agent set does not evaluate` | [x] |
| `check_bootstrap_mirror` | Change `TMPDIR` in `.envrc` only | `bootstrap variables differ between .envrc and flake.nix` | [x] |
| `check_bootstrap_mirror` | Delete both exports from `.envrc`, emptying the bootstrap region | `no exports found before 'use flake' in .envrc; the mirror comparison would be vacuous` | [x] |
| `check_r7` | Re-add `kcat` to the devShell package list | `kafka artefact present in devShell: kcat` | [x] |
| `check_r7` | Remove the positive control `jq` from the devShell | `positive control absent: the devShell declares no jq, so the assertions above hold vacuously` | [x] |
| `check_confinement_validates` | Add an unknown top-level key `not_a_real_key` to the description | `the generated description for claude-code does not validate`, and nono enumerates the whole profile surface | [x] |
| `check_confinement_validates` | Reduce the negative control's mutation to `jq '.'`, so nothing malformed is offered | `negative control absent: validate accepted a profile naming a group that does not exist, so its acceptance above proves nothing` | [x] |
| `check_confinement_validates` | Add `extends = [ "default" ]` | `the description names a parent, but D10 says naming one implies an inheritance that does not happen` | [x] |
| `check_confinement_validates` | Set `meta.name` to something other than the agent's name | `meta.name is something-else, not the agent name claude-code` | [x] |
| `check_confinement_validates` | Point the registry's substrate entry at `/tmp/__planted__`, so nothing grants the store | `filesystem.read does not carry /nix/store, so the session cannot execute from the store` | [x] |
| `check_confinement_validates` | Add `git_config` to the agent's groups | `groups.include carries git_config, which D11 excludes` | [x] |
| `check_confinement_validates` | Drop `CLAUDE_CONFIG_DIR` from the description's `set_vars` but not from the agent table | `set_vars does not carry the agent table entry CLAUDE_CONFIG_DIR=$WORKDIR/.agents/claude` | [x] |
| `check_confinement_validates` | Delete `GIT_CONFIG_GLOBAL` from `set_vars` | `set_vars does not carry GIT_CONFIG_GLOBAL, so the version-control toolchain is undirected` | [x] |
| `check_sc1` | Add `$HOME/.ssh` to `filesystem.read` in `confinement.nix` | `granted path outside project and not in registry: /home/…/.ssh (claude-code)` | [x] |
| `check_component_merge` | Assert that a description's own grant beats a `required` group's `deny` for the same path | `a description grant did not beat the required deny for: /home/…/.1password (claude-code)` — the resolved manifest still denies the path, so the inverted assertion fails. This was also the task's RED. The positive control did **not** fire alongside it, which is what proves the probe grant reached the merge and the deny genuinely outranked it | [x] |
| `check_component_merge` | Point a `filesystem.deny` at a path inside the project (`"${w}/.agents"` in `lib/confinement.nix`) | `deny path inside the project: /home/…/agent-sandbox/.agents (claude-code)`, from the check itself. The built profile was inspected first and did carry the deny, and `nono profile validate --strict` exited **0** on it — so validation cannot be the observer, and the set is | [x] |
| `check_sc1` | Drop a path the session needs from the closure the substrate is derived from (`M4c`) | the trace carries an `EACCES` no probe asked for, naming the dropped path | [ ] |
| `check_r5` | Make the wrapper read the in-checkout agent config when composing the description | the `$HOME` the checkout asked for appears in the resolved reach | [ ] |
| `check_r8` | Collapse both failure paths onto one message in the wrapper | the two messages no longer differ | [ ] |
| `check_j1_1` | Put the unconfined binary on `PATH` under the agent's own name | `expected exactly one confined claude session, found 0` — the session record the comparison reads does not exist, so the reach cannot be compared | [x] |
| every check that runs `nono` | Resolve `nono` from `PATH` rather than from the flake, with a sabotaged `nono` (`exit 3`) first on `PATH` | the three component checks and `check_r6` fail, where with the pinning in place the sabotage is invisible to all of them | [x] |
| `check_j1_1` | Consume the environment from the working tree rather than the pushed ref | the e2e arm passes against local state, so it must fail instead | [ ] |
| `check_j4_1` | Expose the real credential value to the session instead of the substitute | a readable value does not match the substitute form | [ ] |
| `check_j5_1` | Remove the `credential_routes` entry for the second agent | the agent that never authenticated is unauthenticated, so FR-7's across-agents axis fails | [ ] |
| `check_j7_1` | Run only the cheapest layer in the workflow | the suite reports success without having covered every layer | [ ] |
| `check_rep1` | Have the wrapper write a timestamped file into the checkout on entry | the second entry differs from the first | [ ] |
| `check_rep3` | Have authentication record the session it ran in | the two resulting states are distinguishable | [ ] |
| `check_r6` | Delete the `die` from assertion 3, so a confined process that wrote outside the project is not refused | `an unenforceable host was not refused with 77: exit 0`, and `the refusal does not name the missing primitive` | [x] |
| `check_r6` | Delete assertion 2, the pre-flight's own positive control | `a host with nowhere to write the canary was not refused with 77: exit 0`, and `the refusal does not say the canary was unwritable`. This is the defect [D5](#d5) was rewritten for, observed: without the control the pre-flight reports enforcement is fine on a host where the canary was never writable | [x] |
| `check_r1` | Add `$HOME/.ssh` to the registry for `claude-code` | the read succeeds, so the check's assertion of failure fails | [ ] |
| `check_r2` | Set `filesystem.allow = ["$HOME"]` | the file exists afterwards | [ ] |
| `check_r3` | Remove `environment.allow_vars` | the canary value appears in the confined environment | [ ] |
| `check_r4` | Make the wrapper read the profile from `$PWD` rather than the store | reach changes mid-session | [ ] |
| `check_r9` | Widen the declared surface from the enumerated authoring directories to their common ancestor, `$HOME/.config/<agent>` | the difference set gains the credential, history and package-manager paths under that ancestor, so it is no longer *exactly* the surface | [ ] |
| `check_r9` | Grant the host's own confinement description directory | the granted path set differs from the run with the host description removed, so a host description is deciding reach | [ ] |
| `check_j8_1` | Remove the configuration key that points the agent at the granted roots, keeping the grant | the surface is readable and the agent reports none of it, which is the failure a grant alone would hide | [ ] |
| `check_j8_1` | Make the grant read-write instead of read-only | the second arm fails: the surface is no longer byte-identical after a session that writes to it | [ ] |
| `check_j8_2` | Have the wrapper read the declaration from a file inside the project instead of the calling environment | the undeclared run's reach is no longer `{project} ∪ registry`, which is R5 breached through FR-25's own door | [ ] |
| `check_r10` | Include the `git_config` group in the description | the host directive is present in the effective configuration | [ ] |
| `check_r10` | Drop `GIT_CONFIG_SYSTEM` from `set_vars` | a system-level host directive survives into the session | [ ] |
| `check_j2_1` | Drop the state variable from `set_vars` | the `$HOME` diff is non-empty outside the registry | [ ] |
| `check_j3_1` | Grant the sibling checkout in the profile | the other project directory is reachable | [ ] |
| `check_j6_1` | Ask for the destination as a plain-string `allow_domain` instead of an inspected one | arm 1 fails: none of the five trust-bundle variables is set | [ ] |
| `check_j6_2` | Set `commit.gpgsign = true` in the configuration this environment writes | the commit fails for want of a key the session cannot reach, so the default is no longer keyless | [ ] |
| `check_r11` | Grant a key store through the registry, so the demanded signature succeeds | the commit succeeds and the refusal the row asserts is gone | [ ] |
| `check_rep2` | Make `validate.sh` write a log file into the checkout | the second run differs from the first | [ ] |
| `check_controls` | Delete the control call from one refusal check | `refusal check asserts no permitted action: check_r2` | [ ] |
| every refusal check | Point the wrapper at a description that denies the workdir, so no session works at all | each check fails **on its control**, not on its refusal — this is the one planted violation that proves [D9](#d9) across the suite rather than check by check | [ ] |

`check_j6_1`'s third arm is deliberately **absent** from this table. It is not planted and reverted; it is a permanent control inside the check, because the property under test is a difference and a difference needs both sides observed on every run. Removing it would not be a planted violation but a regression.

### Coverage gap

Listed here and copied into `docs/HANDBOOK.md` at close-out, so each gap is known rather than discovered.

- **Live provider rejection** (Journey 4, second `Then`). Needs a real account and a real key; the automated half asserts substitute *shape* against mock credentials. Hand-verified.
- **Live OAuth login** (Rep3, and Journey 5's first `Given`). Needs a browser, and possibly MFA. Hand-verified.
- **A host genuinely unable to enforce confinement** (R6). CI runners all have Landlock, so the automated check plants the violation rather than reproducing the condition. Hand-verified on an older kernel, or accepted as unreproducible and stated as such.
- **Streamed responses through the interception proxy** (Risk 14). Exercised by hand with a long completion; not automated because it needs a real provider.
- **Credential eviction after long disuse** (R8 live case). The automated check invalidates the substitute artificially; the retention-driven case takes months. Hand-verified once, then trusted.
- **macOS enforcement *strength*.** SC-8 asserts both platforms grant the same reach; it cannot assert that Seatbelt's guarantee equals Landlock's. The difference is documented under FR-11, not tested.

Writing "none" was never available here: three of these need a human with an account, and one needs a machine we do not have.

## Complexity tracking

The Constitution Check recorded no violation, so this table is empty and is retained to say so explicitly.

| Principle | Violation | Why it is needed | Simpler alternative, and why it was rejected |
| --- | --- | --- | --- |
| — | — | — | — |
