# Implementation Plan: Confined agent sessions per project

**Spec**: [spec.md](spec.md) | **Branch**: `001-agent-sandbox` | **Date**: 2026-08-18

## Summary

**Motivation.** The repository keeps its own tools inside the checkout and does nothing to keep an *agent* there. Its only attempt at confinement — a generated devcontainer bind-mounting four host agent directories read-write — shares credentials and session state with every other consumer of that home. This feature replaces it with kernel-enforced host-level confinement.

**Approach.** `flake.nix` exports a devShell whose `PATH` carries one confined entry point per agent. Each entry point is `pkgs.writeShellApplication` that (1) runs a **functional** pre-flight — a confined child that must fail to write outside the project, else exit `77` — and (2) `exec`s `nono run --profile <store path> --workdir "$PWD"`. The confinement description is a JSON profile built by Nix into the store, naming **no parent** and declaring everything it wants, using nono's own `$WORKDIR` expansion so **nothing is generated per project**. Agent state is relocated into `$WORKDIR/.agents/<agent>` via `environment.set_vars`; host variables are filtered default-deny via `environment.allow_vars`. `$WORKDIR` is granted **read and write** explicitly, because `M1g` found `--allow-cwd` grants it read-only by default and a read-only project makes every agent useless. `scripts/validate.sh` is the single entry point and derives its expected reach from `lib/leak-registry.nix` rather than restating it.

**Predicted diff shape.** `devenv.*`, `ai.nix` and the drafts are deleted; `flake.nix` is rewritten around two systems and a `lib/` of four small Nix files; `scripts/validate.sh` and a two-platform CI workflow are new; `docs/` is updated at close-out.

**The pivot, resolved.** `M1b` closed [Decision D1](#d1) by falsifying its premise, and `M1c`–`M1g` closed the rest. `M1g` was the last of them and the one that could have redirected the design: `claude-code`'s configuration root does relocate, through three of thirteen candidate variables, and nothing survives beneath the home directory — but the credential relocates **with** it, so FR-7 is not satisfiable by relocation and needs exactly the supervisor-side injection D1 and [D14](#d14) had already chosen. `claude-code` is the reference case because it is the agent whose credential the injection was measured against, so nothing about FR-6 or FR-7 is demonstrable until it works — **not** because the other two take their credential from the session it authenticates, which `M7b` measured they do not ([D14](#d14)).

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
| **Effects introduced** | Shell hook (exports the project-scoped variables, including the one blanket `XDG_CONFIG_HOME` that [C1](#c1) tracks, and `mkdir -p` of `.tmp`, `.cache`, `.agents` and `$XDG_CONFIG_HOME` — `M1e` found nono silently falls back to the host's `$HOME/.config` when that directory does not exist, warns, and then reads host profiles); the confined entry point at run time. No build-time effect, no activation script |
| **State written outside the checkout** | `$XDG_STATE_HOME/nono` only — nono's own audit log, session records, per-session interception authority and credential store. Not relocatable *into the project*, and not granted to the sandbox. This is the feature's single new accepted leak, and it is **not** a leak-registry entry (see [D2](#d2)) |

## Constitution Check

| Principle | Verdict | How |
| --- | --- | --- |
| **P1** Isolation is the product | **PASS, one tracked violation** | Agent state is relocated into `$WORKDIR/.agents/<agent>` with each agent's *own* variable. The mechanism itself is the exception and gets a blanket `XDG_CONFIG_HOME`, tracked as [C1](#c1) rather than claimed away. Granted reach is `$WORKDIR` ∪ the session's own execution substrate ∪ registry with no override in force, asserted by `check_sc1` against `lib/leak-registry.nix` and against the substrate derivation itself ([D18](#d18)), an equality in every part. FR-25's authoring surface reads configuration outside the project and so has to be named here: it is **not** an exception this principle grants, because P1 governs what the environment does on its own and the surface arrives only when the human declares it, by the same FR-15 route as D16's forwarded signing socket. `check_j8_2` is what keeps that claim honest, by asserting the undeclared default is unchanged. One new accepted leak: `$XDG_STATE_HOME/nono`, enumerated and justified in `docs/HANDBOOK.md`, joining the existing `source_up_if_exists`. The two bootstrap variables resolve to the same value in `.envrc` and `flake.nix`, now with a check that runs both and compares what each leaves behind |
| **P2** Test first, prove the check bites | **PASS** | `check_sc3` (scenario ↔ check bijection) goes red first, before any implementation exists. Every check below has a row in [Planted violations](#planted-violations), and every check whose observable is a *failure* carries a positive control in the same session per [D9](#d9), so the failure is attributable to the boundary rather than to a session that never started |
| **P3** Scenarios are the success criteria | **PASS** | One check per scenario, the bijection asserted executably by `check_sc3` rather than by review. This row deliberately states no count: it read "20 scenarios, 20 checks" while the real figure was already 22, and Journey 8 has since made it 24. A number written here is a number that drifts, which is the whole reason the bijection is a check |
| **P4** One step at a time | **PASS** | `tasks.md` is one scenario per task; the two tasks that risk the ~50-line ceiling (`M4a` pre-flight, `M7a` credential profile) are split at their natural seam |
| **P5** Clean code invariants | **PASS** | `mkEntryPoint` (this row and the sketch below first called it `mkConfinedAgent`; the code that landed named it for what it produces), `mkConfinementDescription`, `preflight_or_die` each do one thing. Comments record *why a path is not granted*: `$XDG_STATE_HOME/nono` (nono refuses overlapping grants), `$XDG_RUNTIME_DIR` (holds keyring and D-Bus), every host git configuration file (a directive in one runs a program inside the boundary — [D11](#d11)) |
| **P6** Refactor as a separate phase | **PASS, and the refactor turned out to be unnecessary** | `M8a` was planned as a pure refactor: extract `mkConfinedAgent` from the `claude-code`-specific wrapper. There was never a `claude-code`-specific wrapper to extract from — `lib/confined-agent.nix` took `name` and looked it up in the table from its first commit at `M4b`, so the extraction had already happened before the task that planned it. The command this row named, `nix eval --json .#confinement.claude-code \| jq -S .`, does not exist either: a description is a built artefact, read with `nix build .#confinement-<name>` and `jq -S`. What `M8a` did instead is prove the generality the refactor was for, by adding a second agent to the table and watching the whole pipeline generate for it with no edit anywhere else — see [research.md § M8a](research.md#m8a--the-refactor-that-had-already-happened) |
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
  **Corrected by `M7a`, and the correction is a simplification: `claude-code` takes `network.credentials` too.** The assignment of the OAuth shape to `claude-code` was made from the agent's login flow rather than from what the mechanism can be made to do. Measured, `credential_providers` sets the mediated base URL but leaves the phantom absent until a token exchange has actually been captured, and the token endpoint must be HTTPS, so the branch can be neither exercised nor mocked unattended — a check written against it asserts the substitute property over nothing at all. What does work is `network.credentials = [ "anthropic" ]`, one of six service names nono ships a policy for: the real value stays in the supervisor, the child reads a 64-hex substitute, and the whole arrangement is one line with no `credential_key`, no `custom_credentials` and no registry entry. So all three agents take the same mechanism, this decision's fork collapses entirely, and `credential_providers` is left for a consumer who needs a provider nono has no policy for. Measured in [research.md § M7a](research.md#m7a--a-readable-credential-is-a-substitute).

<a id="d2"></a>

- <a id="d2"></a>**D2 — the mechanism's own state root is an accepted leak, not a registry entry.** The spec (line 272) says it is "the registry's first entry". That is wrong and must be corrected in place: nono **refuses to start** when a grant overlaps its own state root, so it cannot be granted. The leak registry enumerates *granted reach* (FR-2/FR-3); the state root is *state written outside the checkout* by the mechanism itself. Two different concerns; the plan keeps them apart. Consequence: the registry carries nothing on the state root's account. [D15](#d15) later gave it its one entry, the whole store, and [D18](#d18) took that away again once the execution substrate could be derived, so the registry is empty. `check_sc1` asserts an **equality** throughout: granted reach is the project directory, the session's own execution substrate, and whatever the registry justifies, and nothing else.
  The path is `$XDG_STATE_HOME/nono`, observed in `M1c` and `M1e` — not `$HOME/.nono`, which one research round asserted and which the mechanism does not use. It holds the audit log, the session records, the per-session interception authority and the credential store.

<a id="d3"></a>

- <a id="d3"></a>**D3 — Confined entry points shadow the agent name; the raw binary is not on `PATH`.** `claude` inside the devShell is the confined wrapper. The unconfined binary is reachable only by store path, or by the consumer's own global install outside this shell. Chosen over prefixed names (`confined-claude`), which lost because they make *unconfined* the default spelling and a consumer's script calling `claude` would silently escape. Chosen over shell aliases, which lost because they do not survive `nix develop -c` and so cannot be verified non-interactively. **This slightly reinterprets the Q7 answer** ("quoting / not using the alias"): escaping is still deliberate and visible, but the gesture is leaving the shell rather than `\claude`.

<a id="d4"></a>

- <a id="d4"></a>**D4 — Merge behaviour at the nono boundary is written down, per P7.** `M1e` narrowed which merge this environment is actually exposed to. Because a description names no parent ([D10](#d10)), `extends` merge semantics are no longer part of this environment's contract; what remains is the merge of three things nono performs for every session: the built-in floor, the security groups a description includes, and the description's own declarations.
  Within that merge: the floor's grants and denies are always present and cannot be dropped by omission; an included group contributes its grants additively and takes nothing away; a `deny` is the **absence of a grant** rather than a subtractive rule, because Landlock is allow-only; `environment.set_vars` is a map the description owns outright.
  `M3d` observed the precedence claim and found it holds in a form worth stating exactly, because it is not the obvious one: the resolver does **not** drop the losing grant. A path that a `required` group denies and the description also grants appears in `.filesystem.grants` *and* in `.filesystem.deny` of the same manifest. Precedence is therefore observable as **deny-survival**, not as grant-absence. A check that looked for the grant to disappear would have concluded the opposite of the truth.
  **`M5a` then measured what that survival means at the kernel, and it is the opposite of what this decision first claimed.** An earlier draft said a group's `deny` *outranks* any grant, so `deny_credentials` and the keychain groups being `"required": true` meant they could not be traded away. They can. Granting exactly `$HOME/.ssh` — a path the resolved description denies — starts a session that reads the key material, while the deny sits in the manifest beside the grant. What refuses is a grant on an **ancestor** of denied paths: that is [D15](#d15)'s refusal to start, and it is the only case where a deny wins. So the required deny groups are **not** a backstop behind the leak registry, and `FR-3`'s strictness is the only thing between a session and a host key. `R1` is therefore asserted from inside a live session by `check_r1`, never from a resolved description, and `check_component_merge`'s deny-survival claim records that surviving in the manifest is compatible with the path being readable.
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

- <a id="d9"></a>**D9 — A check whose observable is a failure carries a positive control in the same session.** Forced by a defect found in review rather than chosen freely. `check_j6_1` was written twice as "assert exit 0", and exit 0 is what an ordinary tool returns when trust reached it *and*, on a host whose system trust store the substrate can read, when no interception happened at all — one observable for two opposite states of the feature, so the check would have passed with the feature deleted on any such host. The same hole is latent in every refusal scenario: if a session fails to start, the denied read fails, the canary file is absent and the canary variable is missing, and every assertion passes for the wrong reason.
  The rule: alongside the negative assertion, the same session performs the corresponding *permitted* action and it must succeed. A denied read of `$HOME/.ssh` is paired with a permitted read inside the project; a denied write to `$HOME` with a permitted write to the workdir; an absent `ANTHROPIC_API_KEY` with a present `TERM`. Where the property under test *is* a difference, the control is permanent and lives inside the check rather than being planted and reverted — that is not an exception to P2 but the strongest form of it.
  Second rule, from the same review: **`nono why` reports its verdict in the body and always exits 0**, including `command_policy_unavailable` for a query it could not answer. Any check reading it asserts on `.reason` as well as `.status`, and treats a `*_unavailable` reason as an error rather than as a refusal. `nono profile validate` is the opposite and may be read from its exit status.

<a id="d10"></a>

- <a id="d10"></a>**D10 — A confinement description names no parent and takes what it needs by group inclusion.** `M1e` found the mechanism ships no agent preset *locally* — nine built-in profiles, all language runtimes — so the original plan to extend a per-agent preset had nothing to extend, and the packaged descriptions that do exist grant the authenticating agent's whole credential directory read-write, which is the leak this feature removes. It also found that a description naming the built-in floor and one naming nothing resolve to **byte-identical** manifests, so naming it buys nothing.
  Chosen over extending a registry pack, which lost on P8 (a run-time fetch), on P1 (an inherited grant nobody here wrote), and on drift (a pack can change under a mechanism upgrade with nothing in this repository changing). Consequence: `/nix/store` is **absent from the floor**, so the execution substrate has to be declared — see [D15](#d15) for why not by group inclusion and [D18](#d18) for how it is derived instead.

  **Corrected by `M5e`: "no agent preset" was an artefact of the instrument, and the run-time fetch is not hypothetical.** `nono profile list` reports the nine language runtimes and `nono profile show claude-code` answers `Profile not found`, which is what `M1e` measured. But `nono run --profile claude-code` is served by a different resolver: it pulls `nolabs-ai/claude` from `https://registry.nono.sh` and installs thirteen artefacts into `$XDG_CONFIG_HOME/nono/packages`, then applies a description granting `$HOME/.claude` read-write and including the `git_config` group [D11](#d11) refuses. So an agent preset exists and is one token away; the decision above stands unchanged and its P8 objection is now an observation rather than a prediction. Two consequences the decision did not state: naming a description by **store path** is what keeps a network fetch out of session startup, not merely what makes it reproducible; and the artefacts a pull writes include executable hooks and an authoring-surface skill inside the project directory, which is FR-26's category arriving through a channel no check watches. Measured in [research.md § M5e](research.md#naming-a-description-by-name-fetches-one-off-the-network-and-this-falsifies-part-of-d10).

<a id="d11"></a>

- <a id="d11"></a>**D11 — The version-control toolchain is directed at configuration this environment wrote.** Observed, not theorised: a session granted the host's global git configuration read it, found `credential.helper = cache`, and tried to start a **long-lived daemon** writing inside the project. It failed only because that session's workdir happened to be read-only. Read-only grants are no protection here, because the danger is in the directives rather than in the bytes — the same class as `core.hooksPath`, which this plan already declined a grant for, reached through a key that looked harmless.
  So: no host git configuration file is granted, the mechanism's own `git_config` group is **not** included, and `GIT_CONFIG_GLOBAL` is pointed at a project-owned file with `GIT_CONFIG_SYSTEM=/dev/null` via `environment.set_vars`. This is FR-23 and refusal R10.
  Withholding the grant alone was rejected: it stops the read but leaves the effective configuration whatever the machine happens to have, and leaves no commit identity. Directing it makes the configuration identical on every machine, which is what the repetition scenarios ask for. `user.name` and `user.email` are copied out of the host once at setup — they are not credential material, the copy is visible in the file it produces, and a consumer may override.
  **`M5g` settled where that file comes from, which this decision had left open: the entry point writes it, create-if-absent.** Not the shell hook, because a stranger running `nix run <ref>#<binary>` never enters a shell ([`M9a`](tasks.md#m9a--a-stranger-reaches-a-confined-agent-from-the-ref-status-pending)), and the file has to exist for the first session a machine ever starts. Create-if-absent is what makes three separate requirements one mechanism: FR-23's "once at setup", FR-23's consumer override — whatever the file already says wins over the host, and nothing ever rewrites it — and `M9b`'s idempotency. A host with no identity at all leaves **no file**, so the session fails with git's own `Please tell me who you are` (**P9**) rather than committing under a placeholder, and a host that gains an identity later is still picked up.
  **`M5g` also measured that the group and the variables catch different things**, which is why the criterion's two halves land in two layers. Including `git_config` is inert at the integration layer — the toolchain ignores a readable `~/.gitconfig` while `GIT_CONFIG_GLOBAL` is set — and is caught by `check_confinement_validates` and `check_sc1`. Dropping either variable is caught by `check_r10`, from inside a live session, by the value it observes rather than by the key's presence. So no value assertion was added to the component layer: it would be a third copy of an assertion two layers already make.

<a id="d12"></a>

- <a id="d12"></a>**D12 — Interception is per-destination and off by default; trust propagation is asserted as a difference.** `network.tls_intercept` has no on switch. A plain-string `allow_domain` entry is a tunnel and nothing is inspected; an object entry with `endpoints` is inspected, and only then does the mechanism mint a per-session authority and export it as `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE` and `GIT_SSL_CAINFO`. An unfiltered session carries none of those five.
  Two consequences. FR-17 is bounded: trust is propagated for what a description asks to inspect, not universally — and a credential route asks for it, which is why the shipped sessions are intercepted ones ([`M7e`](research.md#m7e--the-toolchain-survives-interception-and-nothing-else-would-carry-it)). And FR-17 cannot be checked by watching an ordinary tool succeed, because what an unintercepted tool does depends on whether the host's `/etc/ssl` and `/etc/pki` hold certificates the substrate can actually read, which is a property of the machine rather than of the feature — see [D9](#d9) and the three-arm `check_j6_1`.

  **Corrected by `M7a`: a credential route switches interception on too, whatever `allow_domain` says.** The session `M7a` ships asks for no inspected destination at all, and all five of those variables arrive set, pointing at a per-session authority the session reads and parses. So "off by default" is true only of the `allow_domain` half; the mechanism turns inspection on wherever it has to mediate, which a credential route always does. Two consequences for [`M7e`](tasks.md#m7e--the-toolchain-survives-interception-status-pending): arm 1's observable is already present in the shipped description rather than needing a description of its own, and the plant that task names — asking for the destination as a plain-string destination — no longer leaves the five unset while the route is in force, so it must withdraw the route as well or it will not bite.

  **Measured since, at 0.74.0, and it adds two things this decision did not know** ([research](research.md#m7--the-credential-surface-and-interception-measured-rather-than-reasoned)). The banner's network line reads `net outbound allowed` for a tunnel and `net proxy` for an inspected destination, which is a second observable for arm 1 that does not depend on the child's environment at all. And the authority it mints lands at `$XDG_STATE_HOME/nono/sessions/intercept-<pid>-<n>/intercept-ca.pem`, which [D13](#d13) keeps outside the project — yet the session reads it and parses it successfully, while the granted reach and the audit record's `tracked_paths` gain nothing but the project. So arm 1 can assert the file exists and parses from inside, and interception widens no reach, which means `check_j1_1` and `check_sc1` need no exception for it. The directory is removed when the session ends, so the bundle must be read from inside rather than inspected afterwards.

<a id="d13"></a>

- <a id="d13"></a>**D13 — `HOME` and `XDG_STATE_HOME` are left pointing at the host, deliberately.** Neither is redirected into the project. For `XDG_STATE_HOME` there is no choice: the mechanism anchors its protected state root there and refuses to grant any path overlapping it, so redirecting it into the checkout would make the workdir ungrantable and the session would not start.
  For `HOME` it is a choice, and the case for redirecting is real — it would relocate most tools for free. It lost on P9 and on AGENTS.md §3: the host home is *denied*, so a tool that ignores its own relocation variable **fails outright**, and that failure is the feature. Setting `HOME` into the project would convert every such failure into a silent success writing somewhere nobody declared, and `M1g`'s whole question — whether the reference agent's own variables cover everything it writes — would become unanswerable by observation.
  **This applies to the ambient value, not to the child's.** `XDG_STATE_HOME` has to stay on the host for the *supervisor*, which is where the protected-state constraint lives; nothing about that constraint says the confined process must inherit it. An agent that honours the variable therefore resolves a state root the session denies, and fails rather than relocating — measured on `opencode`, whose `state` root followed a redirected `XDG_STATE_HOME` cleanly in a scratch probe while resolving under `$HOME` inside the environment. So the variable is redirected in the session's `set_vars` and left alone in the shell hook. That the two resolutions are independent is the load-bearing assumption, and `M6a` verifies it by observation rather than asserting it here.

<a id="d14"></a>

- <a id="d14"></a>**D14 — The other agents take their credential from the mediated session, not from the first agent's store.** FR-7 spans agents as well as projects, and there were two ways to reach that. The prior art shares credentials by plugin: one agent shells out to another, or reads its credential file directly, which needs that credential directory granted read-write inside the boundary. This environment instead lets the mechanism capture the token flow into its supervisor-side store and exposes it to every process in the session as an environment variable plus a mediated base URL.

  The second half of that sentence is corrected: it said the base URL would be picked up "by `opencode` through its provider options and by `pi` through its provider base URL and header interpolation", so this environment would write a configuration file per agent. It writes none, and `credentialServices` is the only thing any table entry says about the route. But the agents do **not** take it the same way, and `M8e` corrected `M8d` on that: `claude-code` and `opencode` read both `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL` out of the environment, while `pi` reads only the key. `M8d` reasoned from the bundled SDK's constructor defaults, which do read `ANTHROPIC_BASE_URL`; `M8e` measured the running agent and found `pi` passes an explicit `baseUrl` from its own provider registry, overriding that default — with the variable pointed at a dead port, the request still reached the real host and returned the real API's 401. So for `pi` the mediation is nono's intercepting proxy in front of `api.anthropic.com` rather than a redirected base URL. The two are not interchangeable: the proxy route depends on `NODE_EXTRA_CA_CERTS` and on the interception directory that `M1c` recorded nono skipping when it cannot be created. A written configuration file would still have been a second place for the route to be wrong, so the decision stands; what changes is that one agent's correctness rests on interception alone.
  This is **forced rather than preferred**: FR-6 and FR-3 together already exclude the alternative, since granting the credential store would put a credential that works outside the boundary inside it, on a justification of convenience rather than of structural impossibility.

  **Corrected by `M7b`: there is no first agent, and no agent takes anything from another.** The mechanism above is withdrawn, the same way `M7a` withdrew `D1`'s fork and for the same reason — it describes an OAuth capture that cannot be exercised. What was measured instead is that each agent's own description declares the same service name and the supervisor mints it an **independent** substitute: two descriptions differing only in `meta.name`, run in two unrelated checkouts against one supervisor environment, each got a distinct 64-hex value and neither read anything of the other's. So the login belongs to the machine rather than to any agent, and "the other agents obtain what they need from the authenticating one" is not what happens — they need nothing from it.
  The decision's outcome stands and its wording is what changes. **The sequencing consequence is withdrawn too**: nothing about `opencode` or `pi` depends on a credential `claude-code` captured, so `M7` no longer has to land before the remaining agents for that reason. `M7` still comes first because `M8`'s agents will each need the service name in their table entry, and `M7a` is what established what a table entry has to say.

  **Which state is machine-scoped, which is project-scoped, and why that is not FR-4 being bent.** FR-7 wants one login per machine and FR-4 wants agent state inside the project, and the two would collide if the login were state an agent holds. It is not. The division is:

  | Scope | What lives there | Where it is |
  | --- | --- | --- |
  | Machine | the real credential, once | the supervisor's own environment or keychain, **outside** every session's reach — no agent, and no project, can read it |
  | Session | the substitute the agent authenticates with | injected into the child's environment, minted per session, never at rest |
  | Project | everything else an agent writes — configuration, history, caches, memory, the VCS identity | under `$WORKDIR`, which is the property `check_state_vars` asserts over the whole table |

  So no agent-held state is machine-scoped at all, and FR-4 needs no exception: what is shared between projects is a value the projects never see, and what each session holds is a value that is worthless to any other session. `check_j5_1`'s distinctness assertion is what keeps that honest — a substitute shared between two sessions would be machine-scoped state inside the boundary, which is the thing this division exists to prevent.

<a id="d15"></a>

- <a id="d15"></a>**D15 — The execution substrate is granted by path and registered, not inherited from a group.** `M3c` measured what [D10](#d10) had assumed. Three findings, each against `nono` 0.73.0:

  1. `filesystem.read = [ storeDir ]` grants **read only**. `nono why --path /nix/store --op write` answers `denied`, with `Path is covered by '/nix/store', which grants read access from profile but write was requested`. D10's premise that a path grant would make the store writable is false, and the agent table's claim that a group "grants exactly the access it was written for where a path grant gives read and write" is false with it.
  1. The `nix_runtime` group contributes **seven** read grants, not four: the store, two individual store paths, `/nix/var/nix/profiles`, `/etc/profiles/per-user`, and **two paths under `$HOME`** (`$HOME/.nix-defexpr`, `$HOME/.local/state/nix/profiles`). So declaring the store by path is *strictly narrower* than including the group — this decision removes reach rather than adding it, and removes home reach in particular.
  1. There is no middle ground between the two. See the Landlock note below.

  The store was therefore the leak registry's one entry from `M3c` to `M4c`, with `builtins.storeDir` as its path so that the value was derived rather than restated, and `groups` is empty for every agent — which it remains. [D18](#d18) has since taken the entry away again and made the substrate a category of its own, so the registry is empty; the part of this decision that survives is *not by group inclusion*, and the three findings below are why.

  **Provisional, and knowingly so — and the provision has since been spent.** FR-3 asks for a structural justification and this entry's was temporal: the store closure of a session cannot be computed before the agent package exists, which is `M4b`. `M4c` did replace the entry with a `closureInfo`-derived grant set, under [D18](#d18). The measurement that made it worth doing: `strace` over a real session needs **55** store paths where the static closure of the same tool set grants **62**, so the closure is a tight upper bound rather than a guess, and the whole store is tens of thousands of paths of which a few hundred are `*-source` trees belonging to unrelated projects — 67,051 and 251 when last counted, and rising. Read-only cross-project source disclosure is precisely what this repository exists to prevent, so the wholesale grant was a two-milestone compromise and not an end state.

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

  **Measured, and it makes the route concrete rather than argued.** `NONO_ALLOW` is additive to a description pinned with `--profile`, so a calling environment widens one project's reach without touching the profile the wrapper names, and `--extends` does the same for a whole profile. FR-15's widening therefore already exists in the mechanism. What does *not* exist is enforcement of "and only from there": nono cannot tell a variable exported above the checkout from one exported by the checkout's own `.envrc`, so the distinction FR-15 draws is a human one — `direnv allow` on a file the human read — and the usage document has to say so rather than the check pretending to assert it. Recorded in [`research.md`](research.md#m5e--an-untrusted-repository-cannot-grant-itself-paths).

  **How the grant is shaped: read-only, and enumerated per location.** FR-25 says the surface is lent rather than handed over, so the grant is a read grant. [D15](#d15) measured that `filesystem.read` really is read-only — `nono why --op write` answers `denied` under a read grant — so this is a property of the mechanism rather than an intention. It also means the grant must name the *authoring* directories individually and must not name an ancestor: `research.md`'s note on `$XDG_CONFIG_HOME/git` and the docs' warning that a grant on `~/.config/nono/` would expose `config.toml` and the installed packages are the same hazard, and for opencode specifically an ancestor grant on `~/.config/opencode` would also hand over `node_modules` and `plugin/`, which FR-26 excludes. `M8e` enumerated before anything is granted.

  **How the agent is told where to look: point, do not copy.** Measured for `opencode` at 1.18.18: the `skills.paths` configuration key takes absolute roots and scans them for `**/SKILL.md`, so the granted host path is named in the configuration this environment writes and no copy exists to go stale. `OPENCODE_CONFIG_DIR` is *not* the answer — the documentation lists agents, commands, modes and plugins as what it covers and skills are absent from that list, so it would cover part of the surface while looking like it covered all of it. The alternative rejected: materialising the surface into `$PWD/.opencode/skills`, which needs no grant at all and is genuinely tempting, but a copy has to be reconciled on every entry and P8's idempotency would then have to be proven over a mutable host directory rather than asserted over a path.

  **One measured hazard this decision exists to contain.** For `opencode`, `~/.agents/skills` and `~/.claude/skills` are read `$HOME`-relative rather than through any XDG variable, so they were reachable from a session that declared nothing — observed while diagnosing this, where a session under the blanket `XDG_CONFIG_HOME` still listed nine skills, all of them from `~/.agents/skills`. That is FR-2 broken by accident wearing FR-25's clothes. It is also why `check_j8_2` asserts the *undeclared* case as a set equality rather than trusting that nothing was granted, and why enumerating the locations was a spike rather than a design step: this one was found by observation after being missed by reading.

  **`M8e` finished the enumeration, and each agent's undeclared-arrival channel turned out to be a different shape.** `pi` has the same `$HOME`-relative hazard as `opencode`, at `~/.agents/skills` — measured, not inferred. `claude-code` has none of those roots at all, not even `~/.agents`, but probes `CLAUDE.md`, `.claude/rules` and `.mcp.json` at **every ancestor of the working directory up to `/`**, which reaches `$HOME` by a different road and carries an MCP server declaration as well as an authoring surface. Both classes fail closed inside a session, but by the boundary rather than by the agent, so the set equality is what asserts it in all three cases. Recorded in [`research.md`](research.md#m8e--where-each-agent-reads-its-declarative-extensions-from).

  **The "point, do not copy" answer does not generalise, which is the one thing `M8e` cost this decision.** `pi` has an additive mechanism covering every surface — the settings arrays `skills`, `prompts`, `extensions` and `packages`, resolved relative to the settings file. `claude-code` has **no additive mechanism at all**: the only lever is `CLAUDE_CONFIG_DIR`, which *moves* the global root rather than adding to it, so for that agent a declared surface and the agent's own state cannot be pointed at independently. `M8f` and `M8g` therefore cannot assume a uniform "name the extra root" step across the table, and this is the decision's live constraint rather than a detail.

  **`M5f` measured `claude-code`, and the hazard does not transfer — for a reason that makes the set equality more necessary rather than less.** This agent's user-scope skills root follows `CLAUDE_CONFIG_DIR`, which `set_vars` already points inside the project, so a host-global `~/.claude/skills` is not consulted at all: hidden by **redirection, not by denial**, with no denial in stderr and nothing granted either way. So for `claude-code` the reach comparison alone would pass while an extension arrived, and the extension assertion alone would pass on a session granted a host path it happened not to read. Neither half implies the other, and `check_j8_2` asserts both. Measured alongside it: dropping the redirection while granting nothing produces a session that is *indistinguishable from a correct one* — exit 0, `No plugins installed`, no denial — so the variable cannot be what a check watches.

  **`M8f` settled all three answers, and the surface it ships is skills alone.** The declaration is `AGENT_SANDBOX_SKILLS`, a colon-separated list of absolute host directories read by the entry point from the calling environment; a relative entry or a non-directory is refused at 78 rather than silently dropped. The grant is one `--read` per entry on the wrapper's own `nono run` argv — necessarily argv rather than environment, because measured, `--allow` is the only filesystem flag nono gives an environment form, so a read-only grant cannot be declared the way `NONO_ALLOW` can. The pointing is per agent, because `M8e` established there is no common mechanism, and the shape of it is a new `skillSurface` field on the agent table so the three answers stay beside the three entries: `kind = "json-array"` with a jq key path for `opencode` (`.skills.paths`) and `pi` (`.skills`), **merged** into the file so a consumer's other settings survive; `kind = "symlink-children"` for `claude-code`, one symlink per skill directory under `$CLAUDE_CONFIG_DIR/skills`.
  `M9a` had to add a third answer to the *which file* half of that, `skillSurface.owned`, because for `opencode` the file `M8e` picked was the agent's own `opencode.json` and that turned out to be a file this environment cannot write: the agent parses it as JSONC and edits it as JSONC, adding its own `$schema` to it, and an insertion into an empty object leaves a trailing comma that jq then refuses. Merging into a file only one of the two writers writes strictly is not a thing that can be made to work, so `opencode` is pointed at `.agents/opencode/config.json` — a file this environment owns, reached by `OPENCODE_CONFIG`, rewritten whole on every start, and read by the agent *in addition to* the consumer's own configuration rather than instead of it. That last one is the answer to this decision's live constraint, and it is a measurement rather than a guess: `claude-code` reads through a symlink into a read-only root, and keeps its own `manifest.json` and `synced` at the writable level *above* the links, so symlinking the children works where symlinking the directory would have broken the agent's own writes. Withdrawing the declaration prunes the links and deletes the key, leaving the consumer's own file byte-for-byte as it was, which is Journey 8's second scenario for free rather than by a second code path.

  **Skills only, and the rest is named rather than quietly missing.** `pi`'s prompts and themes, `claude-code`'s agents, commands, output styles, rules and workflows, and `opencode`'s agents, commands and modes are **not** carried in. SC-9 permits that on condition the uncovered location is named, and [`HANDBOOK.md`](../../docs/HANDBOOK.md) names them. The reason to stop here rather than generalise is FR-26: past skills the surfaces shade into code that runs — a plugin, a hook, a `.ts` extension loaded through jiti — and one variable set months ago should not be what decides that. A consumer who wants those takes FR-15's larger, deliberate widening.

<a id="d18"></a>

- <a id="d18"></a>**D18 — The execution substrate is a category of its own, derived from the session's own definition, and the leak registry is empty.** [D15](#d15) put the whole store in the registry as an admitted two-milestone compromise. `M4c` computed the closure that replaces it, and the replacement turned out to force a spec change, because a grant set of 128 hash-named paths is not a leak anyone can review.

  **Why not an entry.** FR-3 admits a path only where a tool structurally cannot be directed elsewhere, and every entry owes a `why` and a `whyNotNarrower` that a human writes and a reviewer weighs. The substrate is none of that: it is not host configuration that resisted redirection, it is the programs the session runs — the agent, the shell it spawns, every tool it shells out to. Entries for it would be neither reviewable (128 justifications reading "this is bash") nor stable (every input bump rewrites them). So FR-2 now names three categories and the registry is `[ ]`, which FR-3 states is the healthy condition rather than a sign the file is unused. The two alternatives were rejected on the record: a derived entry kind inside the registry keeps FR-2's sentence intact but destroys the single-file reviewability FR-3 exists for, and abandoning the narrowing leaves the ~251 other-project `*-source` trees readable by every session, which is the disclosure this repository exists to prevent.

  **Why the entry had to go rather than stay as an upper bound.** `M4c`'s criterion 6 licensed either. Measured, only deletion narrows anything: with the store prefix granted *alongside* the 128 paths, an out-of-closure store path answered `OPENDIR_OK`; with it removed, `OPENDIR_DENIED`. Landlock's allow rule on an ancestor subsumes every descendant, so the enumeration beside the prefix was decorative. The probe had to open the path — an earlier arm using `ls -d` reported readable under both arms and was invalid, because Landlock mediates opening and not `stat`. And nono's own floor grants seven specific store *files* (`terminfo`, `hosts`, `nsswitch.conf`, `services`, `os-release`, `locale.conf`, `gai.conf`) and never the store, so the description really is what grants the substrate.

  **How it is derived.** `closureInfo { rootPaths = sessionTools ++ localeRoots ++ [ agent ]; }`, where `sessionTools` is the same nix list the devShell passes to `packages`, so `PATH` and the grants cannot drift — [D15](#d15) is why the roots have to be the session's tools rather than the agent alone. Roots are package attributes, never restated outputs, because `PATH` carries `jq`'s `bin` output while `jq^out` is a different store path. `nono` itself is deliberately **not** a root: the supervisor runs outside the sandbox it builds, so R4 is reinforced by absence rather than argued, and the entry points are absent for the same reason. Exposed as `packages.<system>.substrate-<agent>` so a human reads it with `nix build .#substrate-claude-code && cat result/store-paths` and a check reads it without import-from-derivation — the description is assembled by a `runCommand` merging `store-paths` with `jq`, because `builtins.readFile (closure + "/store-paths")` would build the whole closure during evaluation of `nix flake show`.

  **`LOCALE_ARCHIVE` is part of the decision, not a detail.** glibc's compiled-in default is `/run/current-system/sw/lib/locale/locale-archive`, outside the store and outside every grant, so the variable is set to `glibcLocalesUtf8`'s archive (2 MiB, against `glibcLocales`' 222 MiB) and that package is a closure root. Setting the variable without granting what it names only moves the denial, which the planted violation below demonstrates: dropping the package from the grant produced denials at *both* the archive and the compiled-in fallback.

  **The observer is `strace`, and the assertion is differential.** nono is not an observer here — a session that died for a denied locale archive reported `"denials": []` from `--diagnostics-json`, and no discovery mode exists. A real session denies eleven `/sys` paths (one CPU-topology file, nine cgroup limit files across three slice levels, one tracing marker) **with the whole store granted as well**, so an absolute denial set proves nothing and `check_substrate_denials` compares two arms differing only in the substrate grant, with `[ -s whole.denials ]` as the positive control per [D9](#d9). This is an integration-layer claim by necessity: `nono profile show` proves what nono would grant, only a live session proves what the kernel enforces.

<a id="d19"></a>

- <a id="d19"></a>**D19 — A checkout cannot widen reach, but it can deny itself a session, and that is accepted.** `M5e` measured the three configuration surfaces `R5`'s neighbourhood still owed, and none of them widens: `config.toml`'s `[extensions]` and `[overrides]` sections change nothing, `--bypass-protection` refuses to start without an accompanying grant and adds nothing to one that has it, and a project-level `trust-policy.json` selects which files are verified rather than which paths are reachable.

  **What it can do instead.** `config.toml` lives at `$XDG_CONFIG_HOME/nono/config.toml`, which [C1](#c1)'s blanket puts inside the project, and it *is* read: a malformed file, or a known key with an invalid value, makes the mechanism refuse to start. Through the entry point that refusal arrives as exit `77`, the status `R6` reserves for a host that cannot enforce confinement. So a hostile checkout can make a consumer's machine report itself unable to confine.

  **Why that is accepted rather than fixed.** It is denial of service and misdiagnosis, not disclosure: nothing starts, so nothing leaks, and `FR-2`'s reach is untouched. Fixing it means either taking `XDG_CONFIG_HOME` off the project — which is `C1`'s whole subject and a larger decision than this — or having the entry point distinguish a configuration parse error from a missing primitive, which is a message this feature has no scenario for. What is owed instead is that the failure be *legible*: `R6`'s scenario requires the message name the missing primitive, and a message naming a primitive that is present while a file in the checkout is at fault would be a lie. Recorded here so the next reader of a `77` knows to look in `.config/nono/` before doubting their kernel.

<a id="d20"></a>

- <a id="d20"></a>**D20 — The harness's own outside is an accepted leak, and no better location exists.** `M9d` shipped `outside_root` ahead of the research directive that was to settle where a fabricated home may live. `M10a` reconsidered it with the answer in hand. The mechanism is not in question — deriving the location from the host at run time is better than naming one, because it asks the machine instead of assuming — so what was left was the candidate list, and three questions about it.

  **Is `$HOME/.agent-sandbox` a leak P1 must refuse?** No. It is enumerated as P1's third accepted leak, with the distinction that makes it acceptable stated beside it: nothing a consumer runs writes there, only the verification suite does, and only on a host offering neither `$XDG_RUNTIME_DIR` nor `$RUNNER_TEMP`. A leak on the path that *verifies* the product is a different kind of thing from one on the path a consumer takes, and P1's list now says which is which. Refusing it was the alternative, and it was rejected because it makes the suite unrunnable on the developer macOS FR-11 names as supported — a boundary that cannot be verified on a platform it claims is worse than a boundary with a written-down leak.

  **Is there a macOS location that is neither granted nor under `/Users`, which would remove the question?** Measured, and the answer is more interesting than the directive assumed. `system_read_macos` does **not** grant `/private` wholesale — it grants `/private/etc`, `/private/etc/ssl`, `/private/var/db/dyld`, `/var/db`, `/System/Library`, `/Library` and `/usr/share`, so most of `/private` is ungranted. But it names **`/tmp` outright, resolving it to `/private/tmp`**, which rules out the obvious candidate. The one that survives on paper is macOS's per-user `$TMPDIR`, `/private/var/folders/…`, which no group names. It is unreachable from where `outside_root` runs: this environment's own `shellHook` sets `TMPDIR` to `$PWD/.tmp` before any check executes, so the value a check can see is inside the project and `outside_root` correctly rejects it. Recovering the OS value would mean reading it from somewhere the `shellHook` has not touched, which nothing here provides. So no better candidate is *available*, which is a different statement from none existing, and it is the honest one.

  **Should the directory be removed when the suite finishes?** No. Each check already removes the `mktemp -d` scratch directory it made underneath, so what is left behind is one empty parent. An `rmdir` at the end would race the concurrent checks that share it and would fail confusingly on the run where it lost, in exchange for removing a directory that holds nothing. The handbook says a verification run creates it and that nothing else does, which is the cheaper and more useful answer.

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
│   └── confined-agent.nix           new       mkEntryPoint     :: name -> writeShellApplication
├── scripts/
│   ├── validate.sh                  new       FR-12, the only entry point
│   └── checks/
│       ├── unit.sh                  new       nix eval only; no build, no $HOME
│       ├── component.sh             new       nono profile validate / show / why
│       ├── integration.sh           new       real confined sessions in this checkout
│       └── e2e.sh                   new       from the canonical ref into a clean $HOME
├── .github/workflows/verify.yml     new       FR-13, ubuntu-latest + macos-latest
├── .yamllint.yml                    new       the workflow's lint, checked in so it is the same for a stranger
├── .yamlfmt                         new       retain_line_breaks_single, so a commented workflow survives
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

The sketch below is the table's final shape, not its first one. `M3b` wrote only `groups` and `stateVars`, and only for `claude-code`, because a field nothing reads is how a table starts lying: `package` arrives with `M4`, which builds the entry point that runs it, `credentialServices` with `M7`, which asserts its shape, and the other two agents with `M8`, where the checks that observe them live. The type is a `submodule` evaluated per entry, so each field is enforced from the moment it exists.

Two of the five fields this section first named are gone, and the sketch is corrected rather than annotated. There is no `binary`, because `meta.mainProgram` already names the command and a second copy of it could disagree with the package. And `credential = { tokenHost, apiHost }` is `credentialServices`, a list of service names: `M7a` measured the mechanism taking the service and deriving the rest, so the hosts were a description of something nothing read.

```nix
# agent ∷ { package, groups, credentialServices, stateVars }
# The set of agents is closed (FR-1) and keyed by name; P9 forbids a silent
# lookup miss, so callers use `agents.${name} or (throw …)`.
#
# There is no `preset` field: M1e found the mechanism ships no agent preset, so
# every description is authored here (D10). `groups` names the built-in security
# groups it includes — never `git_config`, per D11, and never `nix_runtime`,
# per D15: the execution substrate is granted by enumerated path instead (D18).
{ lib }:
{
  claude-code = {
    package   = pkgs: pkgs.claude-code;         # unfree; allowUnfree scoped to this pkgs
    groups    = [ ];                            # the substrate is derived, not inherited (D18)
    credentialServices = [ "anthropic" ];
    # M1g observed which of the thirteen candidates govern: three do, and
    # together they cover the whole default home layout. M8b then reached the
    # paths a one-turn session never does — a subagent listing and a background
    # spawn — and found the other ten still receive nothing, so they stay
    # unset: setting one is not free, because CLAUDE_JOB_DIR is an output the
    # agent writes for itself and CLAUDE_SECURESTORAGE_CONFIG_DIR falls back to
    # the home when set empty. XDG_* is absent because M1g found claude ignores
    # it entirely, despite the strings count.
    stateVars = w: {
      CLAUDE_CONFIG_DIR             = "${w}/.agents/claude";
      CLAUDE_CODE_TMPDIR            = "${w}/.agents/claude/tmp";
      CLAUDE_CODE_REMOTE_MEMORY_DIR = "${w}/.agents/claude/memory";
      DISABLE_AUTOUPDATER           = "1";   # M1g: inherited on the dev host, so P8 needs it set here
    };
  };
  opencode = {
    package   = pkgs: pkgs.opencode;
    groups    = [ ];
    credentialServices = [ "anthropic" ];       # from the mediated session, D14
    # Almost empty, and that is M8c's finding. The OPENCODE_CONFIG and
    # OPENCODE_CONFIG_DIR this sketch first named are withdrawn: every root the
    # agent reports is derived from the XDG_* roots and TMPDIR, which the
    # confinement already relocates for every agent, so there is nothing
    # agent-specific left to move.
    stateVars = _w: { OPENCODE_DISABLE_AUTOUPDATE = "1"; };   # P8
  };
  pi = {
    package   = pkgs: pkgs.pi;
    groups    = [ ];
    credentialServices = [ "anthropic" ];       # from the mediated session, D14
    stateVars = w: {
      # The whole root: settings, credentials, sessions and installed packages.
      # PI_CODING_AGENT_SESSION_DIR is documented but absent from the binary — M1d.
      PI_CODING_AGENT_DIR = "${w}/.agents/pi";
      # FR-22: the startup install of any declared package does not happen.
      PI_OFFLINE = "1";
    };
  };
}
```

### `lib/leak-registry.nix`

```nix
# FR-3. The single file. Empty at landing, which is the healthy state (D18).
# entry ∷ { path ∷ str, mode ∷ enum ["read" "readwrite"],
#           agents ∷ listOf agentName, why ∷ str, whyNotNarrower ∷ str }
{ lib }:
{
  entryType = lib.types.submodule { options = { … }; };   # P7: never attrsOf str
  entries = [
    # An entry is admissible only where the tool structurally cannot be directed
    # elsewhere (FR-3). Nothing qualifies. `builtins.storeDir` held the one slot
    # from M3c to M4c, until the closure became computable and FR-2 made the
    # execution substrate a category of its own — an entry owes a justification a
    # human reviews, and a derived path set is neither reviewable nor stable
    # (D18). The mechanism's own state root is NOT an entry either: nono refuses
    # any grant overlapping it, so it cannot be granted at all (D2).
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
# mkEntryPoint ∷ name → writeShellApplication, /bin/${binary}
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

`--allow-cwd` is not decoration. `M4b` measured that `workdir.access` in the description sets what the working-directory consent is *worth*, while the flag is the consent: without it a non-interactive session is granted no part of the project at all, and — worse for anyone debugging it — the resolved manifest still says `readwrite`. `M9a` found the third state, which is worse again: with a terminal on `stdin` nono **asks**, so a wrapper that omits the flag and redirects its output hangs on an invisible question. The pre-flight passes the flag on every confined run for that reason, and `check_r6` arm 4 holds it there.

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
| **Integration** | real confined sessions in this checkout, `scripts/checks/integration.sh` | a build and a real kernel, plus — for `check_j6_1` alone — an HTTPS exchange with the canonical remote | Every refusal R1–R6 and R8–R10; Journeys 2, 3, 4, 5, 6; Rep3; the pre-flight; environment filtering. **This is the only layer where kernel enforcement is observed at all** |
| **End to end** | `nix develop github:GRBurst/agent-sandbox` with `HOME=$(mktemp -d)`, `scripts/checks/e2e.sh` | a build and a clean machine | Journeys 1 and 7; Rep1, Rep2; SC-5. Run in CI on both platforms from the pushed ref, never from the working tree |

**The one exception to "from the pushed ref", and why it is not a loophole.** Rep1 and Rep2 each require a violation planted *in the thing under test*, and a published revision is exactly what cannot carry one. So `check_rep1` and `check_rep2` consume a checkout the layer makes for itself: every tracked path copied out of the working tree, `git init`, one commit, nothing untracked and nothing the environment has already written. `nix flake metadata` reports it as a git tree with a locked revision and no dirt, so what is entered is a reference rather than a developing checkout — the fake this layer exists to prevent is a run that reaches the *live* working tree, and a committed copy of tracked files is not one. `check_j1_1` remains the check that asserts the published reference itself, and it is the only one that may.

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
| Journey 2.1 | `check_j2_1` — snapshot `$HOME`, run a session that writes history, diff, subtract registry, assert empty. The snapshot carries **size and mtime, not paths alone**, because the leak measured under the plant was a file the session rewrote in place, and the home is planted with a prior installation, because an empty home gives the agent no fallback to write to and the arm then passes for the wrong reason. A second session in the same check probes every root the description relocates, since an agent that writes nowhere near one leaves it unobserved. **Control**: the same session's writes are found under `$WORKDIR/.agents`, so "nothing landed in `$HOME`" cannot be satisfied by a session that wrote nothing anywhere | integration |
| Journey 2.1 | `check_confinement_validates` — that every relocated root is *under* the working directory, as a property over the agent table, and that the session redirects every `XDG_*` root the devShell hook exports plus `XDG_STATE_HOME`. Here rather than at the integration layer because `check_j2_1` reads its root set out of the description, so a root removed from both sides of that comparison is invisible to it. "Over the agent table" was drift until [`M8c`](research.md#m8c--opencode-needs-no-variable-of-its-own-and-takes-its-credential-from-the-environment): the check named one agent, so a second would have joined the table unasserted. It now loops the table and names the agent in every failure | component |
| Journey 3.1 | `check_j3_1` — two sibling checkouts, two **concurrent** sessions, twice over: a pair of agent sessions for the state half, and a pair of probe sessions for the reach half, because an agent handed a grant it has no use for does not exercise it. The reach property is stated **over the pair** — each session's audit record must reach exactly one of the two checkouts, and the two must differ — because a record carries no working directory and two sessions with indistinguishable reach is itself the failure. An **ancestor** counts as reaching. The cross-project write is confirmed absent from the host afterwards, not merely reported denied from inside. **Control**: each session's write into its own checkout is confirmed present, so two sessions that did nothing cannot pass as two that did not interfere | integration |
| Journey 4.1 | `check_j4_1` — four sessions. The real value is a per-run canary in the *supervisor's* environment, which is what "authenticated once on the machine" is on a host with no keychain. Assert the substitute is 64 lowercase hex, that no crossed value contains the canary, that the whole project tree is free of it afterwards (SC-6), and that two sessions get different substitutes. **Two controls, because both halves could hold vacuously**: the same canary handed through under a name the route does not claim is read out by the same probe and found by the same tree search, so neither the probe nor the search is blind; and the routed name is asserted non-empty before its form is asserted, so a session handed no credential at all cannot pass. Live rejection is a coverage gap | integration |
| Journey 5.1 | `check_j5_1` — one credential in the calling environment, then a session per checkout and per agent, asserting each is handed a substitute of its own without a login (FR-7's two axes). The across-agents axis is a property over the agent table rather than a named second agent, so it grows when `M8` adds one. **Control**: a second service is declared and left unauthenticated in the same session, and its credential variable must be absent while the authenticated one is present, so the check cannot pass by treating everything as authenticated | integration |
| Journey 6.1 | `check_j6_1` — three arms, see below. Narrowed from "push a commit" by [`M1c`](research.md#m1c--git-credentials-inside-the-boundary) | integration |
| Journey 6.2 | `check_j6_2` — commit in a throwaway checkout inside the project; assert the commit object exists, that it carries no signature, and that the configuration this environment wrote does not ask for one. **Control**: `check_r11` runs in the same session, so a session that cannot commit at all cannot satisfy this row | integration |
| Journey 7.1 | `check_j7_1` — `validate.sh` runs unattended per platform and reports success; then plant a registry entry and observe the expected set change **with the check unedited**. The second arm is the discriminator: exit 0 alone would also be produced by a suite that ran nothing, which is why `validate.sh` fails when no check ran | e2e |
| Journey 8.1 | `check_j8_1` — declare an authoring surface in a fake `$HOME`, holding one extension per location `M8e` enumerated; from inside a session, ask the agent to report the extensions it has and assert every planted one is named. **Control**: an extension planted at a location *not* declared is asserted absent in the same session, so "the surface arrived" cannot be satisfied by an agent that reports everything it can imagine. Second arm: the surface is compared before and after and must be byte-identical, which is FR-25's lent-not-handed-over clause | integration |
| Journey 8.2 | `check_j8_2` — a whole host-global agent configuration planted with **no** declaration: an authoring surface, a stored credential, conversation history, session state and a confinement description of the host's own. Assert the session's granted reach equals `{project} ∪ substrate ∪ registry` exactly, and that the agent starts and reports none of the planted extensions. Both halves, because neither implies the other: the reach equality would pass while an extension arrived through a root read `$HOME`-relative, and the extension assertion would pass on a session granted a host path it happened not to read. **Control**: an extension planted inside the project, in the same session, so "none of the host ones arrived" cannot be satisfied by an agent that enumerates nothing. `check_j8_1` is the declared half and is a separate row rather than this one's control, because a run of it is a different session | integration |
| R1 | `check_r1` — plant an SSH key in the fake `$HOME`, read it from inside, assert the read fails and no key material appears in the output. **Control**: a file inside the project is read successfully in the same session | integration |
| R2 | `check_r2` — create a file in `$HOME` from inside; assert failure **and** non-existence. **Control**: the same write into `$WORKDIR` succeeds and the file exists | integration |
| R3 | `check_r3` — export `ANTHROPIC_API_KEY=<random canary>`, print the environment from inside, assert the canary is absent. **Control**: `TERM` is present, so an empty environment dump cannot pass | integration |
| R4 | `check_r4` — from inside a session, rewrite `lib/leak-registry.nix` to grant `$HOME`; assert reach unchanged now and on the next start before re-entry. **Control**: the edit is confirmed to have landed on disk, so "reach unchanged" is not satisfied by a write that never happened | integration |
| R5 | `check_r5` — place a project-level agent configuration requesting a path outside the project; assert reach unchanged. **Control**: the same file, in the same place, is resolved by name in a second arm and *does* grant that path, so the check proves the request was refused rather than the file ignored. Measured: the file is a nono user profile inside the project, found there because `XDG_CONFIG_HOME` points at the project, and what refuses it is the wrapper naming its description as a command-line argument, which beats `NONO_PROFILE` | integration |
| R6 | `check_r6` — four arms. Plant the violation the pre-flight exists to catch, by putting a passthrough `nono` on `PATH` so the canary runs unconfined; assert exit `77` and that the message names the primitive. A second plant points both `$XDG_RUNTIME_DIR` and `$HOME` at an unwritable directory, so assertion 2 is exercised on a machine where the canary location happens to be writable. **Control**: unplanted, the pre-flight exits 0 on the same machine, so `77` is attributable to the plant and not to a missing mechanism. A fourth arm asserts on the *argv* the pre-flight passes rather than on its outcome, through a logging `nono` on `PATH`: every `nono run` it makes carries `--allow-cwd`. That one is not about enforcement at all but about the pre-flight being startable, and it is argv rather than a session because the thing it guards against is a prompt, which no check running under `</dev/null` can ever see | integration |
| R7 | `check_r7` — grep the evaluated devShell for every Kafka artefact by name; assert none. **Control**: assert a package that *should* be there is found, so an evaluation returning nothing cannot pass | unit |
| R8 | `check_r8` — invalidate the stored substitute, make a request, assert the message is an authentication failure and **differs from** a denial message. The difference is the assertion; a single failure string proves nothing | integration |
| R9 | `check_r9` — a **differential**, in the shape the three-arm `check_j6_1` below and `M4c` both settled on. Populate the fake `$HOME` with a whole host-global agent configuration — stored credentials, conversation history, session state and a confinement description among it — and declare only the authoring surface. Assert that the readable set under the declaration minus the readable set without it is *exactly* the declared surface, so the check bites on anything the declaration drags in with it. Assert separately that no host confinement description took part in deciding reach, by comparing the session's granted paths against a run with the host description removed. **Control**: the session still starts and works, so an agent that read nothing cannot pass | integration |
| R10 | `check_r10` — plant a host git configuration carrying a directive that runs a program; from inside, assert the effective configuration is the one this environment wrote and the directive is absent. **Control**: a setting this environment *did* write is read back, so an empty configuration cannot pass. Second arm: no process was started and nothing was written outside `$WORKDIR` | integration |
| R11 | `check_r11` — a checkout whose *own* configuration demands a signature; assert the commit fails, that the message names the key material that could not be reached, and that no commit object was created. **Control**: `check_j6_2`'s unsigned commit in the same session, so the failure is attributable to the demand rather than to a session that cannot commit | integration |
| Rep1 | `check_rep1` — enter twice; assert tracked files unchanged, granted reach byte-identical, and no residue outside the state roots the environment declares | e2e |
| Rep2 | `check_rep2` — run `validate.sh` three times; assert the same verdict, unchanged tracked files and no residue, the third run being what "residue a third run would trip over" is about | e2e |
| Rep3 | `check_rep3` — authenticate twice; assert the resulting state is indistinguishable | integration |
| SC-1 | `check_sc1` — the reach property, derived from the registry and from the substrate derivation itself, an equality in every part | component |
| SC-1 | `check_substrate_denials` — narrowing the substrate to the session's own closure takes nothing away, as a denial-set equality between two arms differing only in that grant ([D18](#d18)) | integration |
| SC-2 | `check_registry` — registry invariants | unit |
| SC-3 | `check_sc3` — the scenario ↔ check bijection | unit |
| P1 mirror | `check_bootstrap_mirror` — the bootstrap variables resolve to the same values in `.envrc` and `flake.nix` | unit |
| D4 | `check_component_merge` — the floor, the included groups and the description's own declarations combine as [D4](#d4) claims, read off the resolved manifest | component |
| D9 | `check_controls` — every refusal check invokes a positive control | unit |

Where a refusal is observed through `nono why` rather than by attempting the action, the check reads `.reason` as well as `.status` and treats any `*_unavailable` reason as an error — that command exits 0 for a refusal, for a grant, and for a question it could not answer ([D9](#d9)). And it is never the observer for a refusal the kernel has to enforce, because `why` answers from the resolved policy and will report a deny Landlock cannot apply at all ([D15](#d15)).

#### `check_j6_1`, in three arms

FR-17 is a *difference*, so one observation cannot carry it. Written out because this is the row that produced [D9](#d9):

1. **The mechanism engaged.** Inside a session whose description asks for something to be inspected, the five trust-bundle variables are set, the file they name is readable from inside, and its certificate delimiters balance. The supervisor's own banner reading `net proxy` is asserted alongside them, as a second observable that does not come from the child's environment. Without this arm the check would pass with interception switched off entirely.
1. **The exchange did its work.** An ordinary credential-free HTTPS exchange with that destination returns the shape it should — matched as a pattern, not pinned to a value, so it survives the remote moving on.
1. **The negative control, in the same session.** Repeat arm 2 with the trust bundle pointed at `/dev/null`, and require failure with a certificate error. This is a **permanent** planted violation living inside the check rather than planted and reverted, because the property under test is precisely the difference between arms 2 and 3.

Arm 1 also has to be asserted rather than assumed: `M1c` first claimed the variables were always set, on the strength of their names appearing together in the binary, and an unfiltered session was then observed carrying **none** of them. Interception is per-destination ([D12](#d12)).

What asks for inspection here is the **credential route**, not an `allow_domain` entry: `lib/confinement.nix` names no destination at all, and `M7e` measured that declaring a credential service is by itself enough to set all five variables and take the banner to `net proxy`. A session that substitutes a credential is therefore an intercepted session, which is why FR-17 applies to the shipped environment rather than to some opt-in a consumer might add.

### Properties

Asserted as properties, derived from the system under test, so a new agent or a new registry entry needs no edit to the check.

- `∀ a ∈ agents. ∀ p ∈ granted(a). realpath(p) ⊑ $PWD ∨ p ∈ substrate(a) ∨ p ∈ registry` — SC-1 with no override in force, and with the registry empty it collapses to the first two disjuncts, which is stronger
- `∀ a ∈ agents. granted(a) ∩ subtree(storeDir) = substrate(a)` — FR-2's substrate half, an equality rather than a containment, because a per-path test can only ask whether a path *could* belong to the substrate and every path in the store can. `substrate(a)` is read from `packages.<system>.substrate-<a>`, the derivation the description itself is built from, so adding a tool to the session cannot make the check stale ([D18](#d18))
- `∀ a ∈ agents. storeDir ∉ granted(a)` — the same half stated as the failure it guards against, since Landlock's allow rule on the store subsumes every path beneath and the enumeration above would become decorative while still comparing equal
- `denials(session | substrate granted) = denials(session | whole store granted)` — FR-2 narrowed without cost, differential because a real session denies eleven `/sys` paths in both arms
- `∀ a ∈ agents. granted(a | surface declared) ∖ granted(a) = locations(a)` — FR-25 and SC-9 as a difference over the agent table rather than a list of paths, so an agent whose locations `M8e` enumerated differently needs no edit to the check. Stated as equality in both directions: `⊇` is the surface arriving, `⊆` is nothing arriving with it
- `∀ a ∈ agents. ∀ p ∈ locations(a). ¬writable(p)` — FR-25's lent-not-handed-over clause
- `∀ a ∈ agents. ∀ (k,v) ∈ set_vars(a). v ⊑ "$WORKDIR"` — FR-4 as a property over the agent table, not a list of variable names
- `scenarios(spec.md) = checks(validate.sh)` as sets — SC-3
- `resolve(bootstrap_exports(.envrc)) ≡ resolve(shellHook(flake.nix))` over the names `.envrc` itself exports before handing over to the flake — P1. Comparing resolved values rather than source text, because nix's indented strings escape where a shell does not, so equal text is neither necessary nor sufficient
- `∀ e ∈ registry. e.why ≠ "" ∧ e.whyNotNarrower ≠ "" ∧ ¬(e.path ⊑ "$WORKDIR")` — FR-3
- `∀ a ∈ agents. deny_group_paths ∩ subtree($WORKDIR) = ∅` — the Landlock constraint that a broad grant must not span a deny path
- `granted(a) on linux ≡ granted(a) on darwin` — FR-20, asserted by comparing the two CI jobs' resolved output
- `∀ c ∈ refusal_checks. c invokes a positive control` — [D9](#d9) made enforceable rather than aspirational, by `check_controls` over the suite's own text, in the same spirit as `check_sc3`. It is a proxy: it establishes that a control is *called*, not that the control is apt. That is worth having anyway, because the failure mode being guarded against is forgetting the control entirely, which is what happened. `M5h` measured how thin the proxy is and how much it still catches: the marker is looked for **inside** each function body, because a header paragraph explaining the controls survives their deletion, and the plant confirmed that a refusal check stripped of its controls goes on passing while proving nothing

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
| `check_confinement_validates` | Re-add `builtins.storeDir` to the registry, so the store is granted whole beside the enumerated substrate | `the store prefix /nix/store is granted whole, and an allow-only rule on it subsumes every path beneath` | [x] |
| `check_confinement_validates` | Add `git_config` to the agent's groups | `groups.include carries git_config, which D11 excludes` | [x] |
| `check_confinement_validates` | Drop `CLAUDE_CONFIG_DIR` from the description's `set_vars` but not from the agent table | `set_vars does not carry the agent table entry CLAUDE_CONFIG_DIR=$WORKDIR/.agents/claude` | [x] |
| `check_confinement_validates` | Delete `GIT_CONFIG_GLOBAL` from `set_vars` | `set_vars does not carry GIT_CONFIG_GLOBAL, so the version-control toolchain is undirected` | [x] |
| `check_sc1` | Add `$HOME/.ssh` to `filesystem.read` in `confinement.nix` | `granted path outside project, substrate and registry: /home/…/.ssh (claude-code)` | [x] |
| `check_component_merge` | Assert that a description's own grant beats a `required` group's `deny` for the same path | `a description grant did not beat the required deny for: /home/…/.1password (claude-code)` — the resolved manifest still denies the path, so the inverted assertion fails. This was also the task's RED. The positive control did **not** fire alongside it, which is what proves the probe grant reached the merge and the deny genuinely outranked it | [x] |
| `check_component_merge` | Point a `filesystem.deny` at a path inside the project (`"${w}/.agents"` in `lib/confinement.nix`) | `deny path inside the project: /home/…/agent-sandbox/.agents (claude-code)`, from the check itself. The built profile was inspected first and did carry the deny, and `nono profile validate --strict` exited **0** on it — so validation cannot be the observer, and the set is | [x] |
| `check_sc1` | Drop a path the session needs from the substrate grant while a variable still names it — `map(select(test("glibc-locales") \| not))` in `confinement.nix`'s merge (`M4c`) | `the granted substrate is not the substrate this session runs (claude-code)`, the diff naming the dropped path. It also bit `check_j1_1` (`the session reaches more or less than the project, its substrate and the leak registry`) and `check_substrate_denials`, which is the point: one omission is visible at the description, at the live session's own record, and at the kernel | [x] |
| `check_sc1` | Re-add `builtins.storeDir` to the registry | `the store prefix is granted whole: /nix/store (claude-code)` — the substrate equality alone would still hold, since every enumerated path is present and correct | [x] |
| `check_substrate_denials` | The same dropped `glibc-locales` path | `narrowing the substrate denied the session something the whole store did not`, naming **two** paths the whole-store arm did not deny: the archive `LOCALE_ARCHIVE` points at, and `/run/current-system/sw/lib/locale/locale-archive`, glibc's compiled-in fallback denied in turn. That second path is the failure mode this decision's `LOCALE_ARCHIVE` clause exists to prevent, observed rather than argued | [x] |
| `check_substrate_denials` | Change the trace to `-e trace=none`, so neither arm records an `openat` at all | with the control in place, `the whole-store arm was refused nothing, so the trace observed nothing`. With the control then removed, the same plant **passes** — two empty denial sets compare equal — which is [D9](#d9)'s vacuity, and the reason the control rather than the equality is what makes this check mean anything | [x] |
| `check_r5` | Make the wrapper resolve `--profile` by name, or drop the flag so `NONO_PROFILE` decides | the path the checkout asked for is read from inside the session. Both forms were measured reading a canary out, so either bites | [x] |
| `check_r8` | Empty `credentialServices`, so the route does not exist and no base URL crosses | there is no provider request to make, so the authentication failure is not there to compare and both failure paths collapse onto one kind. This row said "in the wrapper", and the wrapper produces neither message — [`M7c`](research.md#m7c--a-stale-substitute-answers-differently-from-a-denied-path) measured the knob to be the agent table's own | [x] |
| `check_j1_1` | Put the unconfined binary on `PATH` under the agent's own name | `expected exactly one confined claude session, found 0` — the session record the comparison reads does not exist, so the reach cannot be compared | [x] |
| every check that runs `nono` | Resolve `nono` from `PATH` rather than from the flake, with a sabotaged `nono` (`exit 3`) first on `PATH` | the three component checks and `check_r6` fail, where with the pinning in place the sabotage is invisible to all of them | [x] |
| `check_j1_1` | Consume the environment from the working tree rather than the pushed ref — `canonical_ref` returning `$REPO_ROOT` | `the canonical reference is not a published github reference: /home/…/agent-sandbox`, before anything is entered. Because the check is red anyway until the reference is pushed, a FAIL alone is not discriminating, so the plant was run a second time with **both** ref-control arms neutralised as well: it reports `1 checks passed`. That is the false green this row predicted, observed — the working tree has the agents, so entering, starting, session selection and the reach comparison all succeed against local state, and the ref control is the only thing standing between them and a green e2e run | [x] |
| `check_j1_1` | Let the caller's `PATH` through the instrument — `PATH=$nixbin:$PATH` in `stranger_env` | `the run inherited the calling shell's PATH`, naming the sentinel. This reproduces the defect research measured: with the caller's `PATH` inherited, `claude` resolves to `/nix/store/…-claude/bin/claude` **from the developing checkout** even though the reference carries no agent at all, so the run goes on to start an agent and find its session record and the reference takes no part. The store-path arm does not catch it, because a leaked wrapper is a store path too; only the sentinel does | [x] |
| `check_j1_1` | Waive purity on the entering invocation — `nix develop --impure …` | `the end-to-end layer overrides an input or waives purity in 1 place(s), so what it enters is not the committed lock`. The guard reads this file's own text, and its first form was written with the flags spelled literally, so it counted its own three occurrences and failed on a clean file. Written as character classes it counts one under the plant and none without it | [x] |
| `check_j4_1` | Withdraw `network.credentials` and add `ANTHROPIC_API_KEY` to `allow_vars`, so the session reads the supervisor's own value | three assertions at once — `the credential the session can read is not of the substitute form: 27 character(s), not 64 lowercase hex`, `the real credential is readable inside the session, carried by: ANTHROPIC_API_KEY`, and `two sessions were handed the same substitute, so one copied out of a session stays valid in the next`. It also takes `check_r3` with it, on both `the host secret crossed into the session` and the routed-name assertion this task added. SC-6's project-tree search does **not** fire: the value crossed in the environment and nothing wrote it at rest, so the two halves are independent and this plant exercises only the first | [x] |
| `check_j4_1` | Add `ANTHROPIC_API_KEY` to `allow_vars` with the route left in place — the widening a consumer would actually reach for | **inert, and that is the finding**: `13 checks passed`. The route overrides the grant, so a widening cannot get behind it, and the new `check_r3` assertion can only be falsified by removing the route | [x] |
| `check_j5_1` | Empty `credentialServices` for one agent in the table | that agent's session is handed no credential, so FR-7's across-agents axis fails. `M7b` measured that there are no `credential_routes` to remove — the criterion's original plant named a mechanism `D14` withdrew. Bit in four places at once: both of that agent's project arms, the count over the table, and the control's positive half | [x] |
| `check_j7_1` | Run only the cheapest layer in the workflow — `run: ./scripts/validate.sh --layer unit`, read back off the file with `yq` before the FAIL was trusted | `the workflow runs one layer rather than the suite, so a green commit says nothing about the layers it skipped: ./scripts/validate.sh --layer unit`. The arm is guarded by first asserting that `validate.sh` still accepts `--layer`, so it forbids something the driver can actually be asked to do rather than something impossible. Nothing else in the repository reads `.github/`, so this plant is invisible to every other check — the workflow is a claim only this check observes | [x] |
| `check_rep1` | Have the wrapper write a timestamped file into the checkout on entry — `date +%s%N >"$PWD/entered-$(date +%s%N)"` in the entry point's body | `entering a second time left residue outside the state roots the environment declares`, quoting `+file … ./entered-1787473805705244595`. It bit **one** arm of three: the file is untracked, so the tracked-content arm and the reach arm both stayed green, which is why the residue arm exists | [x] |
| `check_rep3` | Have the entry point append its pid to `.agents/auth-session` in the project | `authenticating a second time left different state at rest inside the project`, with the two differing sha256 lines for `./.agents/auth-session`. It bit in **one** place, the at-rest half: a file written under the project cannot show up in a crossed environment, which is why both halves are asserted rather than either alone | [x] |
| `check_r6` | Delete the `die` from assertion 3, so a confined process that wrote outside the project is not refused | `an unenforceable host was not refused with 77: exit 0`, and `the refusal does not name the missing primitive` | [x] |
| `check_r6` | Delete assertion 2, the pre-flight's own positive control | `a host with nowhere to write the canary was not refused with 77: exit 0`, and `the refusal does not say the canary was unwritable`. This is the defect [D5](#d5) was rewritten for, observed: without the control the pre-flight reports enforcement is fine on a host where the canary was never writable | [x] |
| `check_r6` | Take `--allow-cwd` off assertion 1, leaving it on assertion 3 — the state the pre-flight shipped in, reproduced rather than synthesised | arm 4, on the argv the pre-flight actually passed: `1 of the pre-flight's 2 confined runs pass --allow-cwd; without it nono asks for the working directory on a stdin the pre-flight has sent to /dev/null, and an interactive terminal hangs on a prompt it cannot see`, quoting both logged `nono run` lines. **Exit status stays 0 and no other check moves**, which is the whole reason this arm exists: the suite pins `stdin` to `/dev/null`, so the hang it is protecting against cannot be reproduced by running the suite at all. Asserting on the argv rather than on the outcome is what makes it observable, and it covers invocations added later | [x] |
| `check_r1` | Add `$HOME/.ssh` to the registry for `claude-code` | all three of `reading a key outside the project exited 0`, `key material appears in the output of the confined session` and `the read did not fail on permission, so the key may simply not have been there`. The built description was inspected first and did carry `$HOME/.ssh` in `filesystem.read` unexpanded, which is also how `$HOME` was confirmed to expand at the boundary rather than only `$WORKDIR`. It bit `check_j1_1` too, for an unrelated reason kept in `research.md`: that check takes the registry side unexpanded from `nix eval` while `tracked_paths` is written expanded, so the first real entry naming a variable will fail it spuriously | [x] |
| `check_r2` | Add the target's own directory, `$HOME/outside`, to the registry read-write for `claude-code` | all three of `a write outside the project succeeded`, `the write did not fail on permission, so the target may simply not have been there` and `the file exists after the refused write, holding OUTSIDE-WRITE-…`. Planting `$HOME` itself, as the task first asked, does **not** do this: nono refuses to start with `Refusing to grant '<home>' … because it overlaps protected nono state root '<home>/.nono'`, every check in the layer fails, and `check_r2` fails on its own control rather than on its refusal — a plant that proves the check runs, not that it bites. It bit `check_j1_1` too, for the reason recorded against `check_r1` | [x] |
| `check_r3` | Remove `environment.allow_vars` from `lib/confinement.nix`, confirmed absent from the built description before the FAIL was trusted | both of `200 variable(s) crossed into the shipped session that no rule in the description sanctions: …` and `the host secret crossed into the session, carried by: ANTHROPIC_API_KEY`. The *granted* arm then fails its control instead of its assertion — `allow_vars += [...]` on a missing key yields a one-element list, stricter than the shipped description, so `TERM` stops crossing. It also fails `check_substrate_denials`, because the host's own `LOCALE_ARCHIVE` crosses and names a `glibc-locales` store path outside the narrowed substrate | [x] |
| `check_r4` | Make the entry point read the description from `$PWD` rather than the store — both `PREFLIGHT_PROFILE=` and the `--profile` it execs with, confirmed present in the built wrapper before the FAIL was trusted | both of `the entry point does not name the description this check probes with, so the session it starts is not the session measured here` and `the entry point takes its description from $PWD/nono-profile.json rather than from the store, so a session could write what its successor starts from`, the second once per occurrence. It does **not** change reach mid-session, as this row first claimed: every session in the check is handed a description path directly, so all four readings are unaffected and the wrapper assertion is the only thing that carries this criterion. It bit `check_j1_1` too, which reports `the agent did not start: exit 77` — the pre-flight finds no description at `$PWD` and refuses, which is fail-closed | [x] |
| `check_r9` | Widen the declared surface to its parent, `--read "$(dirname "$agent_sandbox_dir")"` in `lib/confined-agent.nix` | `declaring the surface also made these readable to <agent>: …/home/skills/gamma/three/SKILL.md`, once per agent — the `⊆` direction, and the only one of the three plants that fires on the difference. The row first predicted the ancestor would drag in credentials and history too; measured, it does not, because a consumer keeps their skills under one parent and that parent is not their home. So the never-declared *sibling* is what makes this plant bite, and the check plants one for exactly that reason | [x] |
| `check_r9` | Grant the host's own confinement description directory, `--read "$HOME/.config/nono"` unconditionally | `the <agent> session read …/home/.config/nono/profiles/host.json in the declared arm`, and again in the `bare` arm — the FR-21 arm. It does **not** fire the grant comparison this row first predicted, and that is the finding: an unconditional grant is byte-identical in both arms, so a host description *reaching* the session and a host description *deciding* the session are two failures needing two plants | [x] |
| `check_r9` | Make the grant depend on the host description, `if [ -f "$HOME/.config/nono/profiles/host.json" ]; then agent_sandbox_reads+=(--read /etc); fi` | `deleting the host confinement description changed what the <agent> session was granted, so configuration outside the boundary decided the boundary: 1d0 < --read /etc`. The third plant, added because the row above turned out to leave the self-referential arm unproven — it fires that arm alone, tripping neither the difference nor FR-21 | [x] |
| `check_j8_1` | Remove the configuration key that points the agent at the granted roots, keeping the grant | the surface is readable and the agent reports none of it, which is the failure a grant alone would hide | [ ] |
| `check_j8_1` | Make the grant read-write instead of read-only | the second arm fails: the surface is no longer byte-identical after a session that writes to it | [ ] |
| `check_j8_2` | Have the wrapper grant `$HOME/.claude/skills`, which is what a wrapper reading the declaration from somewhere the project controls ends up doing | `a home directory full of host-global agent configuration changed the granted reach`, and `the session was granted a path under the host home directory, so configuration outside the boundary decided the boundary`. **`check_j1_1` passes under this plant** — its fake home has no `.claude/skills`, and a grant on a path that does not exist is silent — which is why this check exists beside it | [x] |
| `check_j8_2` | The same grant, plus dropping `CLAUDE_CONFIG_DIR` from the description, so the agent looks at the granted host root | all four assertions at once: `a host-global extension nobody declared reached the session`, the broken control, and both reach failures. Dropping `CLAUDE_CONFIG_DIR` **alone** fires nothing — the session is refused silently, exit 0, `No plugins installed`, no denial anywhere — so the grant is what the extension assertion needs planted alongside it | [x] |
| `check_r10` | Include the `git_config` group in the description | **nothing at the integration layer, and that is the finding.** `check_r10` still passes: `GIT_CONFIG_GLOBAL` makes the toolchain ignore `~/.gitconfig` however readable it is, so the grant alone is not the leak — the *search* is, which is [D11](#d11)'s point made executable. It is caught one layer down instead: `check_confinement_validates` reports `groups.include carries git_config, which D11 excludes`, and `check_sc1` reports `granted path outside project, substrate and registry: ~/.gitconfig` and `~/.config/git/ignore`, plus the host's home-manager gitconfig store path | [x] |
| `check_r10` | The same, **plus** dropping `GIT_CONFIG_GLOBAL` from `set_vars` — the observed real-world incident reconstructed | every assertion but the system scope: both origins outside the project, all four directives (`credential.helper=cache --timeout=99999`, `core.hooksPath`, `commit.gpgsign=true`, `alias.canary`), the canary, `GLOBAL_VAR :: <unset>`, `COMMIT_RC :: 128` with `gpg failed to sign the data`, and — the one that matters — `a program named by the host configuration ran inside the session, leaving HOOK-RAN-129042088` | [x] |
| `check_r10` | Drop `GIT_CONFIG_SYSTEM` from `set_vars` | `the system scope does not resolve to nothing inside the session: SYSTEM_RC :: 128`, `fatal: unable to read config file '/etc/gitconfig'`, and `SYSTEM_VAR :: <unset>`. This host carries no `/etc/gitconfig`, so the variable is load-bearing even here: without it the toolchain *goes looking*, and on a host that has one it would fail this same assertion by content rather than by error. `check_confinement_validates` fails alongside it | [x] |
| `check_j2_1` | Drop `CLAUDE_CONFIG_DIR` from the agent table **and** grant the fallback in the wrapper, as `--allow "$HOME/.claude"` plus `--allow-file "$HOME/.claude.json"` | both halves at once: the control, `the session wrote no state inside the project`, and the row's own observable, `the session changed the home directory outside the leak registry: <home>/.claude.json`. That one line is an **in-place rewrite** of a file the fixture planted, visible only because the snapshot carries size and mtime rather than paths alone. `check_r5` and `check_j8_2` fail alongside it, on the same wrapper grant seen through their own subjects; the component layer passes throughout, so this plant is invisible one layer down | [x] |
| `check_j2_1` | Drop `CLAUDE_CONFIG_DIR` from the agent table **alone** — the row above as this table first wrote it | **the control, and not the diff.** `the session wrote no state inside the project, so an empty home directory would prove nothing`, with the `$HOME` diff empty: without the grant the fallback location is denied, so the agent writes nowhere rather than writing to the home directory. The observable this row originally named cannot be produced by dropping a variable, which is why the plant above grants the fallback as well. `check_j8_2` fails on its own in-project control for the same reason | [x] |
| `check_j2_1` | Drop `XDG_STATE_HOME` from `set_vars` | **nothing at the integration layer**, and that is why criterion 3 lives one layer down: `check_j2_1` reads the root set out of the description, so a dropped root shrinks both sides of its own comparison and it reports `11 checks passed`. The component-layer coverage mirror is the only thing that sees it — `the session does not redirect XDG_STATE_HOME, the one root the devShell cannot redirect, so it is the one a blanket redirection leaves behind` | [x] |
| `check_j3_1` | Append the working directory's parent to `filesystem.allow`, which is how one description grants every sibling checkout | **both halves, in both directions**: `a concurrent session reaches 2 of the two checkouts (alpha beta), not just its own: <tmp>/work` twice, then `the alpha session wrote into the beta checkout` and `the beta checkout gained a file written by the alpha session: …/beta/crossed.txt`, and the mirror pair. Integration `7 of 12`; the component layer passes throughout, so the plant is invisible one layer down. Collateral worth naming: `check_j1_1` and `check_j8_2` fail on their reach set-equality with the repository's own parent added; `check_r5` starts no session at all once its scratch config root's parent is granted; `check_r10` and `check_j2_1` exit `77`, because their scratch project's parent also holds their state directory and the grant overlaps nono's protected state root; and `check_r6` reports `the refusal does not say the canary was unwritable`, so **an unstartable description is indistinguishable to the pre-flight check from an unenforceable host** | [x] |
| `check_j3_1` | The same, appended to `filesystem.read` instead | **the reach half alone**, which is the measured reason both halves are asserted rather than one standing in for the other: `a concurrent session reaches 2 of the two checkouts (alpha beta) … <tmp>/work <tmp>/work/alpha`, while every cross-write assertion stays green because the grant is read-only. Integration `6 of 12`, and `check_r5` passes here where the read-write plant broke it | [x] |
| `check_j6_1` | Empty `credentialServices`, so the description asks for nothing to be inspected. The row first named a plain-string `allow_domain`, which does not exist here — `lib/confinement.nix` declares no destination, and the credential route is what switches interception on ([`M7e`](research.md#m7e--the-toolchain-survives-interception-and-nothing-else-would-carry-it)) | arm 1 fails four ways at once: none of the five trust-bundle variables is set, the banner reads `net outbound allowed`, the authority is unreadable, and arm 2's exchange fails on the certificate. Arm 3 stays quiet under the plant, correctly — it asserts a failure, and the exchange fails either way, which is why arm 2 is its positive control | [x] |
| `check_j6_2` | Set `commit.gpgsign = true` in the configuration this environment writes | `a commit inside the session failed, so committing is not what the environment ships: error: gpg failed to sign the data: / fatal: failed to write commit object`. It bites `check_r11` too, in its control's own words — `the session cannot commit even where nothing demands a signature, so a refused signed commit proves nothing` — which is the control doing exactly its job | [x] |
| `check_r11` | Set `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` in `set_vars` to force `commit.gpgsign = false`, which outranks even a checkout's own file. The row first named granting a key store through the registry, and that plant is **not realisable**: there is no `gpg` in the substrate, so no path this environment could grant would make the demanded signature succeed. The plant that does bite is the temptation FR-24 has to resist — an environment that helpfully overrides the demand rather than letting it survive ([`M7f`](research.md#m7f--a-commit-needs-no-key-and-the-demand-for-one-survives-while-the-key-does-not)) | `a checkout whose own configuration demands a signature committed anyway, so the session either signed with key material it should not reach or ignored the demand`, quoting git's own `[master (root-commit) …] a commit the checkout demands a signature for`. One place, and the check stops there: a commit that succeeded makes every later assertion about the refusal meaningless | [x] |
| `check_opencode` | Empty `credentialServices` on the `opencode` entry | `the agent found no provider credential in its environment, so the mediated route did not reach it`. One place. Note what does **not** move: `0 credentials` still prints, because the store is empty either way — it is the agent's `Environment` block naming `ANTHROPIC_API_KEY` that disappears, which is why the check asserts the two separately | [x] |
| `check_opencode` | Drop `XDG_DATA_HOME` from `set_vars` | `the agent did not answer where it writes (exit 1)`, quoting the agent's own `errno: -13, code: "EACCES"`. Harder than predicted: the roots do not stray to `$HOME` and get caught by the diff, the agent dies before printing anything, because the fallback root is denied. For `opencode` a lost relocation is a refusal, the mirror image of `claude-code`, which escaped only once the plant *also* granted the fallback ([`M8c`](research.md#m8c--opencode-needs-no-variable-of-its-own-and-takes-its-credential-from-the-environment)) | [x] |
| `check_opencode` | Delete `owned = true` from the `opencode` entry's `skillSurface`, so the skill-surface file is merged into rather than rewritten — the state the repository shipped in, reproduced rather than synthesised | `the agent did not answer where it writes (exit 78)`, quoting the entry point's own refusal: `agent-sandbox: cannot point opencode at its skills.` / `file: …/.agents/opencode/config.json` / `reason: it is not valid JSON, and this environment writes that file.` The arm seeds the file with what the agent leaves behind — `{"$schema": …,}`, a trailing comma from a JSONC editor inserting a key into an empty object — because **running a session twice does not reliably reproduce it**: `debug paths` and `providers list` left the file untouched across two runs, `debug skill` mangled it on one occasion and not on another. Seeding the state and asserting on it is what makes the check deterministic, and the final `jq -e .` on the file catches the mirror case where a session leaves it unreadable for the next start | [x] |
| `check_opencode` | Make the `landed` control's after-snapshot a copy of its before-snapshot, so the session appears to have written nothing inside the project | `the session wrote nothing inside the project, so an unchanged home directory would prove nothing`. `M10a` rewrote this control from a *listing* to a *difference*, because a listing counted the skill-surface file the check itself seeds before the session — measured on a real run at 23 entries, one of them the seed, so the control could not fail on that file alone. The difference form counts 24 on the same run and **zero** when the session does nothing, which is what makes it a control. The seed and its parent directories cancel because they are on both sides; `config.json` still appears, because the session genuinely rewrites it | [x] |
| `require_gnu_find` | Make the probe fail, as it would on a `find` without `-printf` | `the manifests this suite compares need GNU find…`, fatal, and observed on both routes into it — `check_pi` through `dir_manifest` and `check_j8_1` through `tree_manifest` | [x] |
| `check_j1_1`'s quota branch | Force the recorded 403 body and a non-zero status | `the GitHub API refused to resolve github:GRBurst/agent-sandbox: its unauthenticated quota of sixty calls an hour for this address is spent, so this says nothing about whether the reference is consumable.` | [x] |
| `check_j1_1`'s quota branch | Force a non-zero status whose text is **not** a 403 — `flake output attribute does not exist` | The generic `the environment could not be entered from …: exit 1`. The counter-plant, because a branch that claimed the quota for every failure would be worse than the one it replaced: it would explain away a genuinely broken end-to-end path | [x] |
| `check_r9`'s `nohost` arm | Point `XDG_CONFIG_HOME` back at the uncreated `$outside/cfg`, which is where `M9e` left it | **The arm goes vacuous, and it already was.** Measured over three cases with uniquely-named profiles: a plant under `$XDG_CONFIG_HOME` is found; a plant under `$HOME/.config` is found only when `$XDG_CONFIG_HOME` does *not exist*; with `$XDG_CONFIG_HOME` existing and empty, the `$HOME/.config` plant is **not** found. The entry point runs `mkdir -p "$XDG_CONFIG_HOME"` before `nono run`, so the third case applied and the planted host description was outside nono's search path — deleting it could not change anything. Pointed at `$home/.config`, `nono profile list` lists the plant, so the arm now observes a description nono can see and ignores on purpose | [x] |
| the `platforms` job | Point the producer's `nix eval` at an attribute that does not exist, in the old `for a in $(…)` form | **exit 0**, `reach.json` containing `null`, five bytes. Reproduced rather than reasoned about: a command substitution cannot trip `set -e`, so the loop iterates nothing and `jq -s add` over no input writes `null`. In the `mapfile` form the same failure gives `no agent evaluated, so there is no description to compare` and exits 1 | [x] |
| the `platforms` job | Hand the comparison two `null` artefacts, and guard them with the old `[ ! -s "$r" ]` | **The old guard passed, having compared two nulls.** The new guard refuses with `carries no description (null)`. Both artefacts from run 10 pass it, each an object of three agents, so the guard is not merely stricter — it admits the real thing | [x] |
| `require_gnu_find` | Remove the guard **and** make `dir_manifest` produce nothing, which is the state before `M10a` | **`check_pi` exits 0.** This is the counter-plant and the important one: it reproduces the silent pass rather than the loud failure, the home comparison agreeing because both sides are empty. It is the evidence that the guard protects something, since a guard whose absence changes no outcome protects nothing | [x] |
| `check_confinement_validates` | Add `OPENCODE_PLANTED_ROOT = "/tmp/opencode"` to the **second** agent's `stateVars` | `the agent table points OPENCODE_PLANTED_ROOT at /tmp/opencode for opencode, which is not under the working directory`. Planted on the agent the check was never written for, which is the point: it proves the loop reaches an entry added to the table with no edit here, and that the failure says which agent it belongs to | [x] |
| `check_pi` | Write the check before the table entry exists | `the confinement for pi does not build`, `nix build` reporting `does not provide attribute 'packages.x86_64-linux.confinement-pi'`. This was the task's RED, and it is the only one available: nothing else about a third agent can fail while the third agent is not in the table | [x] |
| `check_pi` | Drop `PI_CODING_AGENT_DIR` from `stateVars` | `pi could not report its credential state (exit 2)`, quoting the agent's own `{"status":"invalid","provider":"anthropic","reason":"invalid_state"}`. As with `opencode`, a lost relocation is a refusal rather than a stray write — the fallback `$HOME/.pi/agent` is denied and the agent cannot reach its own credential store, so the plant never gets far enough to make the home diff fire | [x] |
| `check_pi` | Empty `credentialServices` on the `pi` entry | `pi holds no anthropic credential`, quoting `{"status":"not_ready","provider":"anthropic","reason":"credentials_not_configured"}` at exit 1. The two plants above are distinguishable by that payload alone, which is why the check asserts `.status` and `.authType` rather than the exit status | [x] |
| `check_pi` | Pre-create `$PI_CODING_AGENT_DIR/npm/node_modules/left-pad`, which is what a startup install leaves behind | `the relocated root carries an installed package tree: …/proj/.agents/pi/npm/node_modules`. The plant on the artefact rather than on the code, because FR-22 is the absence of a fetch and the fetch is what the shipped environment does not do — this is the only way to watch the assertion that would catch one | [x] |
| `check_pi` | Drop `PI_OFFLINE` from `stateVars` | `pi could not list its packages (exit 1)`, the agent crashing in its own `runNpmCommand`. **Only observable because the check declares a package**: with no `packages` array in the settings file there is nothing to install on startup and the variable is inert, which is how [`M1d`](research.md#m1d--pis-configuration-root) came to record it as unobservable. Inside the boundary the same plant is stopped twice — the substrate carries no `npm`, so the spawn fails with `EACCES: permission denied, posix_spawn 'npm'` — and the crash is that second guard reporting itself | [x] |
| `check_j8_1` | Neutralise the pointing while leaving the grant, by writing the surface to `s.path "$PWD" + ".planted"` in `lib/confined-agent.nix` — one edit that disables both `skillSurface` kinds | six failures, two per agent: `the <agent> session never read the declared surface at … so it did not arrive`. And the discrimination the plant exists for: the grant arm **still passed**, so a session that is given the surface and never told about it is distinguishable from one that is told and not given it | [x] |
| `check_j8_1` | Widen the grant to read-write, `--read` → `--allow` on the wrapper's `nono run` argv | bites three ways per agent, which is what makes the read-only half of the property real rather than assumed: `the <agent> session was granted  but the consumer declared …` (the grant arm reads the flags off the wrapper's own `execve` line, and `--read` is gone), `the grant the <agent> entry point passes let a session write to the declared surface (WROTE), so the surface is handed over rather than lent`, and the surface's own manifest changing digest afterwards. Watching this plant is also what showed the write arm had to parse `--read`, `--allow` and `--write` alike: built from the `--read` flags alone it degenerated under the plant into a run with no grant at all, denied for the wrong reason | [x] |
| `validate.sh`'s own list guard | Take `</dev/null` off `run_check`, so a check inherits the loop's stdin again | `validate.sh: 23 checks were found and 22 ran; the suite stopped short of its own list`, exit non-zero. This is the plant that reproduces the defect the guard was written for rather than a synthetic one: `check_j8_1` starts agents in print mode, they read stdin for a prompt, and the process substitution feeding the name loop is what they drain. Without the guard the same run prints `1 of 30 checks failed` and is *green* on the check that never ran. Planted twice, because the counter was rewritten after the first: again at the unit layer against a draining check appended beside a trivial one, `7 checks were found and 6 ran`, which is seconds rather than a quarter of an hour and is the form to reach for if this is ever re-verified | [x] |
| `check_rep2` | Make `validate.sh` write a log file into the checkout — `printf 'run at %s\n' "$(date +%s%N)" >>"$REPO_ROOT/validate.log"` at the top of `main` | `verification run 2 left residue outside the state roots the environment declares`, and the same for run 3, each quoting a different sha256 for `./validate.log`. The plant was chosen for the blind spot it lands in: `git check-ignore -v validate.log` answers `.gitignore:8:*.log`, so `git status` stays empty through all three runs and only the environment-derived root list sees it | [x] |
| `check_controls` | Delete `check_r2`'s two control arms, comments and code together, as a careless hand would leave them | `refusal check asserts no permitted action: check_r2 (integration.sh)`, verbatim. And the finding that justifies the check: with its controls gone `check_r2` still **passed**, the integration layer reporting `10 checks passed`, so nothing but `check_controls` said the refusal now proved nothing | [x] |
| `outside_root` | Reduce the candidate list to `$TMPDIR`, which the devShell points inside the checkout — the shape a `mktemp -d` with no candidate list at all would take | `no location on this host can hold a fabricated home, so nothing can be planted beyond the reach of a session:` followed by `  …/agent-sandbox/.tmp: inside the checkout, which the session is granted`, and the check stops before it starts a session. Observed on `check_r1`; every check that fabricates a home takes the same route into the helper | [x] |
| `outside_root` | Reduce the candidate list to `/tmp`, the fallback the checks carried before `M9d` | the same refusal, with `  /tmp: insufficient_access` — the floor's `system_write_linux` grants `/tmp` write and the question is asked read-write. This is the row that makes the verdict rather than a started session the criterion: on Linux a session rooted in `/tmp` **does** start, by that partial grant alone, and on macOS the same location is read-granted through `/private` and refuses | [x] |
| every refusal check | `workdir.access = "none"` in `lib/confinement.nix`, which withholds the project from every session the suite starts | `8 of 10 checks failed` at the integration layer, three of them in the control's own words: `the shipped arm never read the file inside the project, so it observed no session (exit 126)` (`check_r1`), the same for `check_r2`'s write, and `it is inert and arm 1 proves nothing` (`check_r5`). Two passed, both principled rather than uncontrolled: `check_r6` starts no session, and `check_r3`'s subject is the environment, which the workdir grant does not touch | [x] |

`check_j6_1`'s third arm is deliberately **absent** from this table. It is not planted and reverted; it is a permanent control inside the check, because the property under test is a difference and a difference needs both sides observed on every run. Removing it would not be a planted violation but a regression.

### Coverage gap

Listed here and copied into `docs/HANDBOOK.md` at close-out, so each gap is known rather than discovered.

- **Live provider rejection** (Journey 4, second `Then`). Needs a real account and a real key; the automated half asserts substitute *shape* against mock credentials. Hand-verified. `M7a` narrowed the gap without closing it: the substitute is the session's own proxy token, minted per session and observed differing between two runs, so it is not a credential the provider has ever seen and it stops working the moment the session ends. That is an argument, not an observation of a provider refusing it.

- **Live OAuth login** (Rep3). Needs a browser, and possibly MFA. Hand-verified. `M7b` removed Journey 5's first `Given` from this gap: authenticating once on the machine is a value in the calling environment, which `check_j5_1` sets, so both of that scenario's axes are observed unattended.

- **A host genuinely unable to enforce confinement** (R6). CI runners all have Landlock, so the automated check plants the violation rather than reproducing the condition. Hand-verified on an older kernel, or accepted as unreproducible and stated as such.

- **Streamed responses through the interception proxy** (Risk 14). Exercised by hand with a long completion; not automated because it needs a real provider.

- **Credential eviction after long disuse** (R8 live case). The automated check invalidates the substitute artificially; the retention-driven case takes months. Hand-verified once, then trusted.

- **A provider request that succeeds** (R8's positive half). `M7c` measured the proxy answering a stale substitute locally, with none of the upstream's headers, and forwarding a valid one — so a request carrying the session's own substitute leaves the machine and cannot be part of an unattended check. `check_r8` runs a second session with no credential in the calling environment instead, and asserts only that what comes back is *outside* the authentication family — which shows the port does not answer 401 to everything, but not that it ever answers 200. Hand-verified whenever a real session works at all.

- **macOS enforcement *strength*.** SC-8 asserts both platforms grant the same reach; it cannot assert that Seatbelt's guarantee equals Landlock's. The difference is documented under FR-11, not tested.

- **The substrate denial-set equality on macOS** (SC-1's integration half). `strace` is Linux-only, so `check_substrate_denials` reports `SKIP` there rather than passing — the harness has a skip status precisely so this gap is visible in the run instead of being asserted away ([D18](#d18)). What macOS still gets is the component-layer equality in `check_sc1`, which reads the description rather than the kernel. Closing it needs the same differential written against a macOS tracer. `M9c` decided to leave it open: the runner now exists in the workflow, but whether a hosted macOS runner permits a tracer at all — and how one behaves under it — is not measurable from a Linux checkout, and a differential written blind would be an unverified check rather than a closed gap. So the gap stays stated, and what closes it is named: a `darwin` differential written against a `darwin` machine.

- **A runner accepting the workflow** (Journey 7.1's own `When`). `check_j7_1` asserts that `.github/workflows/verify.yml` *describes* the run FR-13 requires — the platforms, the one command, no conditional and no human — and it executes the one step whose output another job consumes. What it cannot assert is that GitHub parses the file, that `cachix/install-nix-action` installs on both images, or that `macos-latest` completes the suite at all. Only a push settles that, and the same push settles `check_j1_1`, which is red until the reference carries an agent.

- **The pre-flight outside the devShell.** `lib/preflight.sh` execs its probe by bare name, so it depends on `PATH` resolving that name inside the granted substrate. On a host carrying `/run/current-system/sw/bin/true`, `M5a` observed nono exiting `127` with `its directory is not readable inside the sandbox`, which the pre-flight then reports as `77` — fail-closed, but naming the wrong cause. The integration layer is therefore run as `nix develop -c bash scripts/validate.sh --layer integration`, and `check_r6` covers the pre-flight only under that `PATH`. A user always enters through the devShell, so this is a gap in the check's reach rather than in the product's, and closing it means resolving the probe from the substrate the way the checks already do.

- **nono's remaining configuration surfaces** (R5's neighbourhood). All six are now measured — profiles, `NONO_PROFILE`, `NONO_ALLOW`, `--extends`, `config.toml` and `--bypass-protection` — and none widens a pinned description, which is [D19](#d19). What remains a gap is that `check_r5` asserts over the two channels a checkout controls, the in-project profile and the in-project `config.toml`, and not over the four that arrive at the invocation: `--extends` and `--bypass-protection` are flags the wrapper does not pass, and their absence is asserted by `check_r4`'s reading of the wrapper text rather than by a session. A project-level `trust-policy.json` is uncovered on purpose: it selects which files are verified against which keys, so it belongs to trust enforcement, which this feature has no scenario for and does not enable.

- **A reviewer waving through a registry entry that names a host path** (`M5f`). The plant the task's criterion named — the wrapper reading the declaration from a file inside the project — has a faithful rendering in this repository as an entry in `lib/leak-registry.nix`, and it fails **no** check: the registry appears on both sides of every reach comparison by design, and for `claude-code` the redirection hides the surface anyway. That is the boundary of what the checks cover rather than a hole in them. The registry is this repository's own reviewed content, pinned by the ref a consumer names and not a file a consumer's checkout carries; `check_r4` covers a session editing it and `check_r5` a checkout shipping a description of its own. What is left is a human gate, and it is written down as one.

  Two further gaps in the same neighbourhood, both named by `M5e`. **FR-15's "and only from there" is not assertable**: `check_r5` asserts that a widening supplied at the invocation works and adds exactly what it names, but a checkout's own `.envrc` is part of the calling environment once a human has run `direnv allow`, so the line FR-15 draws is a human decision and belongs in [the handbook](../../docs/HANDBOOK.md) rather than in a check. And **the registry pull is uncovered**: naming a description by name fetches one from `registry.nono.sh` and writes executable hooks and a skill into `$XDG_CONFIG_HOME/nono/packages`, which is inside the project under [C1](#c1). Nothing this repository ships names a description by name, so no session reaches it, and `check_r4`'s wrapper assertion plus `check_r5`'s set equality are what keep it that way — but no check asserts that a pack was *not* fetched.

Writing "none" was never available here: four of these need a human with an account, and the macOS pair needs a machine we do not have.

## Complexity tracking

The one tracked violation is [C1](#c1), recorded beside the Constitution Check it qualifies rather than repeated here.
