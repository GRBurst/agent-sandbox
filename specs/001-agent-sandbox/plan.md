# Implementation Plan: Confined agent sessions per project

**Spec**: [spec.md](spec.md) | **Branch**: `001-agent-sandbox` | **Date**: 2026-08-18

## Summary

**Motivation.** The repository keeps its own tools inside the checkout and does nothing to keep an *agent* there. Its only attempt at confinement — a generated devcontainer bind-mounting four host agent directories read-write — shares credentials and session state with every other consumer of that home. This feature replaces it with kernel-enforced host-level confinement.

**Approach.** `flake.nix` exports a devShell whose `PATH` carries one confined entry point per agent. Each entry point is `pkgs.writeShellApplication` that (1) runs a **functional** pre-flight — a confined child that must fail to write outside the project, else exit `77` — and (2) `exec`s `nono run --profile <store path> --workdir "$PWD"`. The confinement description is a JSON profile built by Nix into the store, `extends`ing nono's compiled-in preset, using nono's own `$WORKDIR` expansion so **nothing is generated per project**. Agent state is relocated into `$WORKDIR/.agents/<agent>` via `environment.set_vars`; host variables are filtered default-deny via `environment.allow_vars`. `scripts/validate.sh` is the single entry point and derives its expected reach from `lib/leak-registry.nix` rather than restating it.

**Predicted diff shape.** `devenv.*`, `ai.nix` and the drafts are deleted; `flake.nix` is rewritten around two systems and a `lib/` of four small Nix files; `scripts/validate.sh` and a two-platform CI workflow are new; `docs/` is updated at close-out.

**The pivot.** One unresolved question determines the architecture, not merely a detail — see [Decision D1](#d1) and spike `M1b`.

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
| `flake.nix`, `.envrc`, `.gitignore` | What is being rewritten; the two bootstrap variables must stay byte-identical across the first two |
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
| **New inputs or tools** | `nono` and all four agent packages from a pinned `numtide/llm-agents.nix` input — `M1f` found `pi` absent from the pinned nixpkgs, and taking `nono` (0.73.0 there, 0.68.0 in nixpkgs) from the same input keeps the binary and the confinement descriptions it reads on one pin; `allowUnfree` scoped to `claude-code` alone; that input's substituter `https://cache.numtide.com` and its key re-declared here, since a `nixConfig` on an input does not reach this flake's consumer; `shellcheck`, `shfmt`, `jq` added to the devShell |
| **Effects introduced** | Shell hook (`mkdir -p` of `.tmp`, `.cache`, `.agents`); the confined entry point at run time. No build-time effect, no activation script |
| **State written outside the checkout** | `$HOME/.nono` only — nono's own audit log, session records and credential store. Not relocatable, not granted to the sandbox. This is the feature's single new accepted leak, and it is **not** a leak-registry entry (see [D2](#d2)) |

## Constitution Check

| Principle | Verdict | How |
| --- | --- | --- |
| **P1** Isolation is the product | **PASS** | Agent state is relocated into `$WORKDIR/.agents/<agent>` with each agent's *own* variable, never a blanket `XDG_CONFIG_HOME`. Granted reach is `$WORKDIR` ∪ registry, asserted by `check_sc1` against `lib/leak-registry.nix`. One new accepted leak: `$HOME/.nono`, enumerated and justified in `docs/HANDBOOK.md`, joining the existing `source_up_if_exists`. The two bootstrap variables stay byte-identical in `.envrc` and `flake.nix`, now with a check that parses both |
| **P2** Test first, prove the check bites | **PASS** | `check_sc3` (scenario ↔ check bijection) goes red first, before any implementation exists. Every check below has a row in [Planted violations](#planted-violations) |
| **P3** Scenarios are the success criteria | **PASS** | 19 scenarios, 19 checks, bijection asserted executably by `check_sc3` rather than by review |
| **P4** One step at a time | **PASS** | `tasks.md` is one scenario per task; the two tasks that risk the ~50-line ceiling (`M4a` pre-flight, `M7a` credential profile) are split at their natural seam |
| **P5** Clean code invariants | **PASS** | `mkConfinedAgent`, `mkConfinementDescription`, `preflight_or_die` each do one thing. Comments record *why a path is not granted*: `$HOME/.nono` (nono refuses overlapping grants), `$XDG_RUNTIME_DIR` (holds keyring and D-Bus), `~/.config/git` (an agent could set `core.hooksPath`) |
| **P6** Refactor as a separate phase | **PASS** | `M8a` is a pure refactor: extract `mkConfinedAgent` from the codex-specific wrapper. Preservation proven by `nix eval --json .#confinement.codex \| jq -S .` diffing empty across it |
| **P7** Ubiquitous language, modelled options | **PASS** | The spec's Vocabulary is used verbatim in Nix attribute names, shell function names and docs. A registry entry is a `submodule` with five typed fields, never `attrsOf str`. nono's boundary merge semantics are written down in [D4](#d4) because they are part of the contract |
| **P8** Purity, effects at the boundary, idempotency | **PASS** | No `builtins.getEnv`, no `--impure`. Confinement descriptions extend `default`, the only preset `M1e` found to be genuinely compiled in, so nothing is fetched from `registry.nono.sh` at run time and the descriptions are versioned with the pinned `nono`. `NONO_NO_UPDATE_CHECK=1` is set so no background network call happens either — `M1e` observed that without it even `nono profile list` calls home. Rep1–Rep3 cover idempotency |
| **P9** Explicit outcomes, no silent fallbacks | **PASS** | `set -euo pipefail` throughout. The pre-flight has **three** assertions, not one, so "nono failed to start" cannot be mistaken for "the child was denied". No bare `or`; the agent table is an `enum`-keyed attrset with an assertion on lookup failure |

Complexity tracking is empty: the gate passed cleanly.

## Decisions

<a id="d1"></a>

- **D1 — Credential substitution by proxy-side injection, falling back to a granted phantom store.** Preferred: `network.credentials` / `credential_routes`, where nono holds the real key and injects it at the proxy, so the agent holds *nothing*. Then FR-7 is automatic (the store is machine-wide under `$HOME/.nono`) and the leak registry stays **empty**. Fallback: `credential_providers` with `oauth_capture`, where the agent persists a phantom — which must then be machine-scoped to satisfy FR-7, making each agent's credential file a registry entry.
  **This is the architecture's pivot**: option (a) yields an empty registry, option (b) yields ≤4 entries. It turns on whether each agent accepts a substituted API base URL, *not* on the credential's file format. Resolved by spike `M1b` before `M7` starts.
  **Resolved by `M1b` to (a), for all four agents, with no weaker tier.** The fork's premise was wrong: nono is a TLS-terminating proxy with its own generated CA, so a credential is injected on the way past `https://api.anthropic.com` and endpoint substitution is optional rather than required. Both mechanisms keep the real secret in the supervisor, outside the boundary, so neither is the weaker tier — `credential_providers` is the OAuth *shape*, not a degraded fallback. `claude-code` and `codex` authenticate by token exchange and take `credential_providers`; `opencode` and `pi` present a key per request and take `network.credentials`. All four agents honour `NODE_EXTRA_CA_CERTS` and all four also expose a base-URL knob as a second route, so no agent is stuck on one mechanism. **The leak registry stays empty**, provided `credential_key` resolves through `env://` or `cmd://` rather than `file://`. Evidence per agent in [research.md](research.md#m1b--credential-substitution-per-agent).

<a id="d2"></a>

- **D2 — `$HOME/.nono` is an accepted leak, not a registry entry.** The spec (line 272) says it is "the registry's first entry". That is wrong and must be corrected in place: nono **refuses to start** when a grant overlaps its own state root, so it cannot be granted. The leak registry enumerates *granted reach* (FR-2/FR-3); `$HOME/.nono` is *state written outside the checkout* by the mechanism itself. Two different concerns; the plan keeps them apart. Consequence: the registry is expected to be empty at landing, which makes `check_sc1` strictly stronger — granted reach **equals** the project directory.

<a id="d3"></a>

- **D3 — Confined entry points shadow the agent name; the raw binary is not on `PATH`.** `codex` inside the devShell is the confined wrapper. The unconfined binary is reachable only by store path, or by the consumer's own global install outside this shell. Chosen over prefixed names (`confined-codex`), which lost because they make *unconfined* the default spelling and a consumer's script calling `codex` would silently escape. Chosen over shell aliases, which lost because they do not survive `nix develop -c` and so cannot be verified non-interactively. **This slightly reinterprets the Q7 answer** ("quoting / not using the alias"): escaping is still deliberate and visible, but the gesture is leaving the shell rather than `\codex`.

<a id="d4"></a>

- **D4 — Merge behaviour at the nono boundary is written down, per P7.** In `extends`: list fields **union**; single-value fields (`binary`, `allow_gpu`, `workdir`, `security.*`) **replace**; `network.block` is **sticky-true**; `open_urls` **replaces the base entirely**; `hooks`, `env_credentials` and `environment.set_vars` merge as maps with the child winning; `allow_vars`/`deny_vars` are additive. The built-in `default` profile is always merged in even when `extends` is absent. These are asserted, not assumed, by `check_component_merge`.

<a id="d5"></a>

- **D5 — The pre-flight is functional, not introspective.** It asserts *enforcement* by observing a denial, rather than probing kernel interfaces (`/sys/kernel/security/lsm`, Landlock ABI, cgroup v2). Introspection lost because the probe list is bubblewrap-shaped: nono uses Landlock and needs neither user namespaces nor cgroups v2, so a passing probe would prove the wrong thing, and a functional probe cannot pass for the wrong reason. Cost: two extra `nono` launches per agent start. Accepted unmeasured; if it hurts, cache per boot under `$XDG_RUNTIME_DIR`, which is a later change.

<a id="d6"></a>

- **D6 — Default-deny environment filtering.** `environment.allow_vars` is written explicitly, so a provider key invented next year is denied without editing anything. Chosen over `deny_vars` with a blocklist of known key names, which lost because it is a value list that rots, where `allow_vars` is a property.

<a id="d7"></a>

- **D7 — Two systems by `lib.genAttrs`, not `flake-utils`.** No new input for six lines of code (P4, and the Constitution's preference for deleting complexity).

<a id="d8"></a>

- **D8 — `.agents/` is gitignored.** Closes the open Q9. Agent state is untracked project state, alongside `.cache/` and `.tmp/`.

## Repository layout

```text
.
├── flake.nix                        modified  description, 2 systems, devShell, packages, checks
├── flake.lock                       modified  nono + agent packages pinned
├── .envrc                           unchanged the two bootstrap variables stay byte-identical
├── .gitignore                       modified  Kafka rules out; /.agents/ in
├── README.md                        new       AGENTS.md §6: component table + 2 mermaid diagrams
├── devenv.nix                       deleted   the container and its four bind mounts
├── devenv.yaml                      deleted
├── ai.nix                           deleted   knowledge absorbed into lib/
├── draft1.md                        deleted
├── draft2.md                        deleted
├── lib/
│   ├── agents.nix                   new       the four agents: package, preset, state variables
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

```nix
# agent ∷ { package, binary, preset, stateVars, credential }
# The set of agents is closed (FR-1) and keyed by name; P9 forbids a silent
# lookup miss, so callers use `agents.${name} or (throw …)`.
{ lib }:
{
  codex = {
    package   = pkgs: pkgs.codex;
    binary    = "codex";
    preset    = "codex";                        # compiled-in; never a registry pack (P8)
    stateVars = w: { CODEX_HOME = "${w}/.agents/codex"; };
    credential = { tokenHost = "platform.openai.com"; apiHost = "api.openai.com"; };
  };
  claude-code = {
    package   = pkgs: pkgs.claude-code;         # unfree; allowUnfree scoped to this pkgs
    binary    = "claude";
    preset    = "claude-code";
    stateVars = w: { CLAUDE_CONFIG_DIR = "${w}/.agents/claude"; };
    credential = { tokenHost = "platform.claude.com"; apiHost = "api.anthropic.com"; };
  };
  opencode = {
    package   = pkgs: pkgs.opencode;
    binary    = "opencode";
    preset    = "opencode";
    # Its own variables, not XDG_DATA_HOME: P1 forbids a blanket XDG override
    # where the tool exposes a specific one.
    stateVars = w: {
      OPENCODE_CONFIG     = "${w}/.agents/opencode/config.json";
      OPENCODE_CONFIG_DIR = "${w}/.agents/opencode";
    };
    credential = { … };
  };
  pi = {
    package   = pkgs: pkgs.pi-coding-agent;
    binary    = "pi";
    preset    = null;                           # no compiled-in preset; authored from groups
    stateVars = w: {
      # The whole root: settings, credentials, sessions and installed packages.
      # PI_CODING_AGENT_SESSION_DIR is documented but absent from the binary — M1d.
      PI_CODING_AGENT_DIR = "${w}/.agents/pi";
      # FR-22: with no packages declared there is nothing to install on startup,
      # and this also stops the update check and the model-catalogue refresh.
      PI_OFFLINE = "1";
    };
    credential = { … };
  };
}
```

### `lib/leak-registry.nix`

```nix
# FR-3. The single file. Expected to evaluate to [] at landing (D2).
# entry ∷ { path ∷ str, mode ∷ enum ["read" "readwrite"],
#           agents ∷ listOf agentName, why ∷ str, whyNotNarrower ∷ str }
{ lib }:
{
  entryType = lib.types.submodule { options = { … }; };   # P7: never attrsOf str
  entries = [
    # Empty. An entry is admissible only where the tool structurally cannot be
    # directed elsewhere (FR-3). $HOME/.nono is NOT an entry: nono refuses any
    # grant overlapping its own state root, so it cannot be granted at all (D2).
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
pkgs.writeText "nono-profile-${name}.json" (builtins.toJSON ({
  "$schema" = "https://nono.sh/schemas/nono-profile.schema.json";
  meta = { inherit name; version = "1"; description = "agent-sandbox confinement for ${name}"; };
  workdir = { access = "readwrite"; };
  filesystem = {
    allow = map (e: e.path) (builtins.filter (e: e.mode == "readwrite") mine);
    read  = map (e: e.path) (builtins.filter (e: e.mode == "read")      mine);
    # NOT granted, and each omission is deliberate:
    #   $HOME/.nono          nono refuses any grant overlapping its state root
    #   $XDG_RUNTIME_DIR     holds gnome-keyring secrets, ssh sockets, the D-Bus bus
    #   $XDG_CONFIG_HOME/git an agent could set core.hooksPath and fire host code later
  };
  environment = {
    allow_vars = [ "HOME" "USER" "LOGNAME" "TERM" "LANG" "LC_*" "PWD" "SHELL" "TZ" "COLORTERM" ];
    set_vars   = (a.stateVars w) // { NONO_NO_UPDATE_CHECK = "1"; };
  };
  network = { … };            # filled by M7 per D1
} // lib.optionalAttrs (a.preset != null) { extends = [ a.preset ]; }))
```

Note the Landlock constraint: granting `$WORKDIR` recursively is safe only because no deny-group path lies inside a project checkout. If one ever does, Linux emits warnings and the grant is wrong — `check_component_merge` asserts no overlap.

### `lib/confined-agent.nix`

```nix
# mkConfinedAgent ∷ name → writeShellApplication, /bin/${a.binary}
{ pkgs, agents, confinement, preflightProfile }:
name:
let a = agents.${name}; in
pkgs.writeShellApplication {
  name = a.binary;                              # D3: shadows the agent name
  runtimeInputs = [ pkgs.nono (a.package pkgs) ];
  text = ''
    ${preflightSh}
    preflight_or_die
    exec nono run \
      --profile ${confinement name} \
      --workdir "$PWD" \
      --allow-cwd \
      -- ${a.package pkgs}/bin/${a.binary} "$@"
  '';
}
```

### The pre-flight (`preflightSh`)

```bash
# FR-10 / R6. Functional, not introspective (D5). Three assertions, because
# P9 forbids letting "nono could not start" look like "the child was denied".
preflight_or_die() {
  local canary rc
  canary="$HOME/.agent-sandbox-preflight.$$"

  # 1. A confined process can start at all.
  if ! nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" -- true >/dev/null 2>&1; then
    die 77 "cannot start a confined process. nono failed to initialise."
  fi

  # 2. A confined process cannot write outside the project. On success nothing
  #    is written; only the failure path leaves a file, which we then remove.
  nono run --profile "$PREFLIGHT_PROFILE" --workdir "$PWD" \
    -- sh -c ": > \"$canary\"" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$canary"
    die 77 "confinement is not enforced: a confined process wrote outside the project."
  fi

  # 3. And it genuinely did not write it.
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
#   check_r1 … check_r9
#   check_rep1 check_rep2 check_rep3
# plus derived-property checks: check_sc1 check_sc2 check_sc3 check_registry
#   check_bootstrap_mirror check_component_merge
```

`check_sc3` is the bijection, and it is the first thing written:

```bash
# RED before anything else exists.
check_sc3() {
  local spec_ids impl_ids
  spec_ids=$(grep -oE '^1\. \*\*(R|Rep)[0-9]+|^### Journey [0-9]+' "$SPEC" | normalise | sort -u)
  impl_ids=$(grep -oE '^check_(j[0-9]+_[0-9]+|r[0-9]+|rep[0-9]+)\(\)' "$0" | normalise | sort -u)
  diff <(echo "$spec_ids") <(echo "$impl_ids") \
    || fail "scenario ↔ check bijection broken; the difference is above"
}
```

`check_sc1` derives its expectation from the registry rather than restating it (Journey 7, third `Then`):

```bash
# ∀ agent. ∀ p ∈ granted(agent). p ⊑ $PWD ∨ p ∈ registry
check_sc1() {
  local registry granted
  registry=$(nix eval --json .#leakRegistry --apply 'r: map (e: e.path) r.entries')
  for agent in $(nix eval --json .#confinedAgentNames | jq -r '.[]'); do
    # --format manifest, not profile: M1e found `profile` is the human rendering
    # and `manifest` the only JSON one. Its resolved shape is filesystem.grants[],
    # each {access, path, type} — not the source profile's allow/read lists.
    granted=$(nono profile show "$(profile_path "$agent")" --format manifest \
              | jq -r '.filesystem.grants[].path')
    while read -r p; do
      is_under "$p" "$PWD" || in_registry "$p" "$registry" \
        || fail "granted path outside project and not in registry: $p ($agent)"
    done <<< "$granted"
  done
}
```

## Dependencies & impact

- **Files touched**: `flake.nix`, `flake.lock`, `.gitignore`, new `lib/` (4 files), new `scripts/` (5 files), new `.github/workflows/verify.yml`, new `README.md`, `docs/HANDBOOK.md`, `docs/CONSTITUTION.md`, `AGENTS.md` (one sentence). Deleted: `devenv.nix`, `devenv.yaml`, `ai.nix`, `draft1.md`, `draft2.md`.
- **Consumers affected**: none exist yet. The devcontainer path disappears; `docs/HANDBOOK.md` currently documents it as unverified, so nothing verified is withdrawn.
- **Inputs added or bumped**: `nixpkgs` re-locked. A pinned `numtide/llm-agents.nix` input is added — `M1f` found `pi` absent from nixpkgs entirely, which was the condition. It is the **sole** source of `nono`, `codex`, `claude-code`, `opencode` and `pi`, both in the environment a human enters and in every check, so that one pin describes what is verified and what is shipped. Its `nixConfig` is not inherited by a consumer of this flake, so `https://cache.numtide.com` and its key `niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=` are declared here as well and passed explicitly in CI; without that, a clean machine builds five agents from source.
- **Tools added to the environment**: `nono` (the mechanism), `shellcheck` + `shfmt` (AGENTS.md names them and they are absent — Known drift), `jq` (checks parse JSON; P9 requires generated JSON be validated rather than eyeballed).
- **Docs to update at close-out**: `docs/HANDBOOK.md` — retires the Known drift entries for the Kafka leftovers, the `x86_64-linux` hardcoding, the four devcontainer bind mounts, the orphaned `ai.nix`, the stray `^`, the missing `scripts/validate.sh`, the missing `README.md` and the absent `shellcheck`/`shfmt`; adds the accepted-leak entry for `$HOME/.nono` and the coverage gap. `README.md` — new. `AGENTS.md` — the "no CD pipeline" sentence gains "non-deploying CI is permitted". `docs/CONSTITUTION.md` — P1's accepted-leak list gains its second entry.

## Test strategy

| Layer | Where | Needs | Covers |
| --- | --- | --- | --- |
| **Unit** | `nix eval`, `scripts/checks/unit.sh` | nothing — no build, no network, no `$HOME` | Registry invariants; the scenario ↔ check bijection (`check_sc3`); the bootstrap-variable mirror between `.envrc` and `flake.nix`; agent-table totality |
| **Component** | `nono profile validate` / `show` / `why` against generated profiles, `scripts/checks/component.sh` | an evaluator and `nono`, no kernel enforcement | Generated JSON validates against nono's schema; `extends` merge semantics are what D4 claims; granted reach `⊆ $WORKDIR ∪ registry` (`check_sc1`); no deny-group path lies inside a project checkout |
| **Integration** | real confined sessions in this checkout, `scripts/checks/integration.sh` | a build and a real kernel | Every refusal R1–R9; Journeys 2, 3, 6; the pre-flight; environment filtering. **This is the only layer where kernel enforcement is observed at all** |
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

| Scenario | Check | Layer |
| --- | --- | --- |
| Journey 1.1 | `check_j1_1` — enter from the ref into a clean `$HOME`, start `codex`, compare granted reach to registry | e2e |
| Journey 2.1 | `check_j2_1` — snapshot `$HOME`, run a session that writes history, diff, subtract registry, assert empty | integration |
| Journey 3.1 | `check_j3_1` — two checkouts, two **concurrent** sessions, write in one, assert the other unchanged | integration |
| Journey 4.1 | `check_j4_1` — assert every readable credential value matches the substitute form (mock credentials); live rejection is a coverage gap | integration |
| Journey 5.1 | `check_j5_1` — authenticate in checkout A, assert authenticated state in checkout B | e2e |
| Journey 6.1 | `check_j6_1` — run a credential-free `git` HTTPS exchange with a remote from inside a session; assert exit 0, which holds only if the interception CA reached `git` via `GIT_SSL_CAINFO`. Narrowed from "push a commit" by [`M1c`](research.md#m1c--git-credentials-inside-the-boundary) | integration |
| Journey 7.1 | `check_j7_1` — `validate.sh` exits 0 unattended per platform; plant a registry entry and observe the expected set change with the check unedited | e2e |
| R1 | `check_r1` — plant an SSH key in the fake `$HOME`, read it from inside, assert failure and absence of key material in output | integration |
| R2 | `check_r2` — create a file in `$HOME` from inside; assert failure **and** non-existence | integration |
| R3 | `check_r3` — export `ANTHROPIC_API_KEY=<random canary>`, print the environment from inside, assert the canary is absent | integration |
| R4 | `check_r4` — from inside a session, rewrite `lib/leak-registry.nix` to grant `$HOME`; assert reach unchanged now and on the next start before re-entry | integration |
| R5 | `check_r5` — place `.opencode.json` / `.claude/settings.json` requesting `$HOME`; assert reach unchanged | integration |
| R6 | `check_r6` — run the pre-flight with the canary executed unconfined; assert exit `77` and that the message names the primitive | integration |
| R7 | `check_r7` — grep the evaluated devShell for every Kafka artefact by name; assert none | unit |
| R8 | `check_r8` — invalidate the stored substitute, make a request, assert the message is an authentication failure and differs from a denial message | integration |
| R9 | `check_r9` — populate the fake `$HOME` with a host-global agent config; assert unreadable from inside **and** that the session still starts | integration |
| Rep1 | `check_rep1` — enter twice; assert tracked files unchanged and granted reach byte-identical | e2e |
| Rep2 | `check_rep2` — run `validate.sh` twice; assert same result and no residue | e2e |
| Rep3 | `check_rep3` — authenticate twice; assert the resulting state is indistinguishable | integration |
| SC-1 | `check_sc1` — the reach property, derived from the registry | component |
| SC-2 | `check_registry` — registry invariants | unit |
| SC-3 | `check_sc3` — the scenario ↔ check bijection | unit |
| P1 mirror | `check_bootstrap_mirror` — the two bootstrap variables byte-identical in `.envrc` and `flake.nix` | unit |
| D4 | `check_component_merge` — nono's merge semantics are what D4 claims | component |

### Properties

Asserted as properties, derived from the system under test, so a new agent or a new registry entry needs no edit to the check.

- `∀ a ∈ agents. ∀ p ∈ granted(a). realpath(p) ⊑ $PWD ∨ p ∈ registry` — SC-1, and with the registry empty it collapses to equality, which is stronger
- `∀ a ∈ agents. ∀ (k,v) ∈ set_vars(a). v ⊑ "$WORKDIR"` — FR-4 as a property over the agent table, not a list of four variable names
- `scenarios(spec.md) = checks(validate.sh)` as sets — SC-3
- `bootstrap_vars(.envrc) ≡ bootstrap_vars(flake.nix)` byte-for-byte — P1
- `∀ e ∈ registry. e.why ≠ "" ∧ e.whyNotNarrower ≠ "" ∧ ¬(e.path ⊑ "$WORKDIR")` — FR-3
- `∀ a ∈ agents. deny_group_paths ∩ subtree($WORKDIR) = ∅` — the Landlock constraint that a broad grant must not span a deny path
- `granted(a) on linux ≡ granted(a) on darwin` — FR-20, asserted by comparing the two CI jobs' resolved output

Literals are pinned in exactly two places, and both are criteria rather than values: the exit status `77`, and the pre-flight's user-facing message.

### Planted violations

Mandatory per P2. Tick `Verified` only after seeing red.

| Check | Violation planted | Must FAIL with | Verified |
| --- | --- | --- | --- |
| `check_sc3` | Delete `check_r5` from `scripts/checks/unit.sh` | `scenario ↔ check bijection broken` naming `r5` | [x] |
| `check_sc3` | Add an orphan `check_r99` to a green suite | `check with no scenario: r99` | [x] |
| `check_sc3` | Point `SPEC` at a file declaring no scenarios | `parsed no scenarios out of …; the parser and the spec have drifted` | [x] |
| `validate.sh` | Select a layer whose file carries no check | `no checks ran; the suite would report success without testing anything`, exit `2` | [x] |
| `validate.sh` | Pass an argument outside the accepted set | `unknown argument: --bogus`, exit `2` | [x] |
| `check_registry` | Add an entry with `whyNotNarrower = ""` | `registry entry '<path>' does not say why a narrower grant fails` | [ ] |
| `check_registry` | Add an entry whose `path` is `"$WORKDIR/.agents"` | `registry entry inside the project is not an exception` | [ ] |
| `check_bootstrap_mirror` | Change `TMPDIR` in `.envrc` only | `bootstrap variables differ between .envrc and flake.nix` | [ ] |
| `check_r7` | Re-add `kcat` to the devShell package list | `kafka artefact present in devShell: kcat` | [ ] |
| `check_sc1` | Add `$HOME/.ssh` to `filesystem.read` in `confinement.nix` | `granted path outside project and not in registry: …/.ssh` | [ ] |
| `check_component_merge` | Assert `open_urls` unions instead of replaces | mismatch against `nono profile show` output | [ ] |
| `check_r6` | Run the canary directly instead of under `nono` | exit `77`, `confinement is not enforced` | [ ] |
| `check_r1` | Add `$HOME/.ssh` to the registry for `codex` | the read succeeds, so the check's assertion of failure fails | [ ] |
| `check_r2` | Set `filesystem.allow = ["$HOME"]` | the file exists afterwards | [ ] |
| `check_r3` | Remove `environment.allow_vars` | the canary value appears in the confined environment | [ ] |
| `check_r4` | Make the wrapper read the profile from `$PWD` rather than the store | reach changes mid-session | [ ] |
| `check_r9` | Add `$XDG_CONFIG_HOME/opencode` to the registry | the host-global config is readable from inside | [ ] |
| `check_j2_1` | Drop `CODEX_HOME` from `set_vars` | the `$HOME` diff is non-empty outside the registry | [ ] |
| `check_j3_1` | Grant the sibling checkout in the profile | the other project directory is reachable | [ ] |
| `check_j6_1` | Remove the CA trust variables from `set_vars` | the push fails with a certificate error, not a denial | [ ] |
| `check_rep2` | Make `validate.sh` write a log file into the checkout | the second run differs from the first | [ ] |

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
