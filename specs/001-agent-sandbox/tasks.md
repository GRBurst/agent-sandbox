# Tasks: Confined agent sessions per project

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Read [plan.md § Read first](plan.md#read-first) before starting `M1a`. One task is one commit. RED before GREEN, every time.

______________________________________________________________________

## M1 — Ground truth: the harness, and the unknowns that block design

The four spikes exist because [D1](plan.md#d1) forks the architecture and the fork cannot be guessed. Each spike ends with a written finding in `research.md`, not with code.

### M1a — The scenario ↔ check bijection (Status: IMPLEMENTED)

The first check written, before any implementation exists. It fails immediately and keeps failing until the last scenario lands, so it is the feature's progress bar.

**Scenario**: SC-3

**RED**: `scripts/validate.sh` does not exist. Create it with `set -euo pipefail`, a `--list` flag and `check_sc3` only. It parses scenario IDs out of `spec.md` and `check_*` function names out of itself, and diffs the sets.

- [x] Check written and seen to FAIL with: `scenario ↔ check bijection broken` listing all 19 missing checks
- [x] `bash scripts/validate.sh --layer unit` runs and reports the 19 as missing without erroring on its own parsing
- [x] Violation planted (delete `check_r5` once stubs exist), seen to FAIL, reverted, recorded in [plan.md](plan.md#planted-violations)
- [x] `shellcheck` and `shfmt -d` clean

**Implemented.** `scripts/validate.sh` is the driver and `scripts/checks/<layer>.sh` holds the checks, one file per layer, `unit component integration e2e` cheapest first. Nothing enumerates the checks: the driver greps `^check_*()` out of each layer file, so a check cannot be added without being run.

Decisions the plan did not anticipate:

- **Checks live in `scripts/checks/<layer>.sh`, not inside `validate.sh`.** The plan's sketch put `check_sc3` in `validate.sh` itself. A single file holding all 19 scenario checks across four layers would not survive M5–M8, and the layer a check belongs to is then implicit. The file *is* the layer declaration. `check_sc3` derives both sides of the bijection from source — scenario IDs by parsing the spec's `## Scenarios` section, check IDs by grepping the layer files — so neither side is a list anyone maintains by hand.
- **Every layer file is sourced even under `--layer`**, because `check_sc3` asserts over the whole suite; running only the unit layer must not make the bijection look satisfied.
- **Three anti-vacuity guards were added and each was proven to bite**, since a bijection between two empty sets holds while testing nothing: a suite that ran no checks exits `2`, a spec that parses to no scenarios fails, and an unrecognised argument exits `2` rather than being ignored (P9).
- The planted violation for `check_r5` needed a green suite to bite, so all 19 checks were stubbed transiently, the deletion was observed to isolate exactly `r5`, and the stubs were removed. The suite is intentionally left RED: `check_sc3` is the feature's progress bar and goes green only when the last scenario lands.

### M1b — Spike: can each agent be pointed at a substituted endpoint? (Status: IMPLEMENTED)

The pivot. Determines whether the leak registry is empty or holds one credential file per agent, per [D1](plan.md#d1).

**Scenario**: none — investigation. Its output is a decision recorded in `plan.md`.

**RED**: not applicable; a spike has no check. It is a task because it is a commit and it blocks `M7`.

- [x] For each of `codex`, `claude-code`, `opencode`, `pi`: record whether the provider base URL is configurable, and by which variable or config key
- [x] Record whether `network.credentials` proxy-side injection reaches each agent, or only `credential_providers` phantom capture
- [x] `research.md` states the finding per agent with its source
- [x] [D1](plan.md#d1) resolved in `plan.md` to (a) or (b), per agent, with the weaker tier named where it applies

**Implementation notes.**

- The spike's premise was wrong and the correction is the finding. `nono` is a TLS-terminating proxy with its own generated CA (`nono proxy --proxy-ca-cert/--proxy-ca-key/--proxy-ca-validity`), so a credential is injected on the way past the real hostname and endpoint substitution is a fallback for clients that cannot be intercepted, not a precondition. `base_url_env_var` is optional on both `CommandCredentialConfig` and `credential_routes`.
- Both mechanisms hold the real secret in the un-sandboxed supervisor, so `credential_providers` is the OAuth **shape**, not a weaker tier. D1 resolves to **(a) for all four agents**, no weaker tier, registry still expected empty.
- All four agents were inspected rather than reasoned about: `claude-code` `ANTHROPIC_BASE_URL`, `opencode` `provider.<id>.options.baseURL`, `pi` `providers.<id>.baseUrl`, `codex` `model_providers.<id>.base_url`. `codex` was built from the pinned nixpkgs to check it; it substituted without compiling.
- Two findings the plan did not anticipate, recorded in `research.md` and carried forward: `nono run --credential __bogus__ --dry-run true` exits 0, so nono does not validate credential service names and the wrapper must; and the shipped `nolabs-ai/claude` pack grants `$HOME/.claude` read-write, which is the leak this feature removes, so that pack cannot be extended unmodified.
- `spec.md` Risk 1 (line 302) asserts "whether each agent's provider endpoint is configurable is what FR-6 actually turns on". That is now falsified. Left unedited: the spec is human-approved, and Risk 1 is retired at close-out in `M10`.

### M1c — Spike: where does `git` get its credential inside the boundary? (Status: IMPLEMENTED)

Journey 6 may be unachievable as written — spec Risk 2, which is a gap in the spec rather than in the research.

**Scenario**: none — investigation blocking Journey 6.

- [x] Establish what a host credential helper, `~/.git-credentials` and the system keychain each do under confinement
- [x] Decide: a registry entry for `git`, routing `git` through substitution, or narrowing Journey 6 to a credential-free toolchain
- [x] `research.md` records the decision; if Journey 6 narrows, `spec.md` is corrected in place rather than annotated

**Implementation notes.**

- All three sources are unreachable, and two of them by a floor no profile can lower: `~/.git-credentials` sits in `deny_credentials` and the keychains in `deny_keychains_{linux,macos}`, all three groups carrying `"required": true`. A helper is not discovered at all, because `~/.gitconfig` is readable only through the `git_config` group, which the plan already declines over `core.hooksPath`.
- **Decision: narrow Journey 6, and give `git` no registry entry.** Routing `git` through substitution was rejected as a shipped default rather than as impossible — it works, but it names one forge and demands a token no requirement asks for. It is recorded in `research.md` as the consumer's extension and in `spec.md` under Out of scope.
- The journey's *purpose* was never authentication. It exists for FR-17, trust in the inspecting authority, and nono propagates that to `git` through `GIT_SSL_CAINFO`. A credential-free exchange tests exactly that property and nothing else; a push would have conflated it with one no requirement supplies.
- `spec.md` was corrected in place, as this task's third criterion directs: Journey 6's When, Then and *Independently verifiable by*, a new Out of scope bullet, and Risk 2 rewritten as resolved by its own stated fallback. This is the sanctioned counterpart to `M1b`, where no criterion authorised a spec edit and none was made.
- One trap for `M8`: nono's `codex_macos` group grants `$HOME/Library/Keychains/login.keychain-db` read **and write**, which would undo `deny_keychains_macos`.
- **Verification gap**: `nono run` cannot execute from this session, because the outer sandbox denies `$HOME` and nono fails to create `~/.local/state/nono/audit/…`. The CA-variable finding is therefore read out of the binary and the profile guide, not observed live. `check_j6_1` observes it for real.

### M1d — Spike: does `pi`'s configuration root actually relocate? (Status: IMPLEMENTED)

The finding reversed once between research rounds, so it is verified before FR-4 leans on it.

**Scenario**: none — investigation blocking `M8c`.

- [x] Set `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR`, run `pi`, observe whether anything is written under `~/.pi`
- [x] Record whether `pi` needs a registry entry, and whether its npm extension install lands inside the project (FR-22)
- [x] `research.md` states the finding; the spec's `pi` edge case is corrected in place to match

**Implementation notes.**

- **It relocates, and `pi` needs no registry entry.** `PI_CODING_AGENT_DIR` is the whole root; the binary resolves it in one place, defaulting to `~/.pi/agent`, and the shipped `quickstart.md` confirms that settings, credentials, sessions and installed packages all live there. Of the five `homedir()`-rooted constructions in the binary, only that one is `pi` state.
- Observed both ways round, which is what makes it a finding rather than a reading. With the override, `pi install` writes only under it. Without it, the same command fails with `EACCES: permission denied, mkdir '/home/pallon/.pi/agent/settings.json.lock'` — the control that fixes the default and shows `pi` writes rather than merely reads there.
- **`PI_CODING_AGENT_SESSION_DIR` does not exist.** The task named it and `docs/environment-variables.md` documents it, but the string is absent from the 112 MB binary, where `PI_CODING_AGENT_DIR` occurs exactly once. Setting it is a no-op. It is dropped from the plan's `stateVars` sketch, with the reason recorded there.
- **FR-22 is not satisfied by relocation.** Relocation puts the npm install inside the project — `$PI_CODING_AGENT_DIR/npm/node_modules/…`, observed — which satisfies FR-4. But `pi` still "installs any missing packages automatically on startup", `pi install` runs a real `npm install` that reached the registry here even under `PI_OFFLINE=1`, and the `package.json` it generates loosens a pinned spec to a caret range. So the environment ships no `pi` packages and sets `PI_OFFLINE`, added to the plan's sketch.
- `spec.md` was corrected in place, as this task's third criterion directs: the `pi` edge case, and the assumption at *Assumptions validated by research* that still described the finding as unverified. The *Assumptions the plan must confirm* checklist was left alone — it is a to-do list retired at close-out, not a statement of fact, and the same reasoning left `M1b`'s counterpart untouched.

### M1e — Spike: is nono's resolved policy machine-readable? (Status: IMPLEMENTED)

`check_sc1` is hermetic only if there is structured output to assert against; spec Risk 15.

**Scenario**: none — investigation blocking `M3c`.

- [x] Compare `nono profile show --format profile`, `nono why --path … --op …` and `nono run --dry-run` for machine-readable output
- [x] Establish which presets exist without any registry pull, via `nono profile list` on a clean `$HOME`
- [x] Confirm `nono profile schema` exports a schema usable by `nono profile validate`
- [x] `research.md` records which command `check_sc1` and `check_component_merge` will use

**Implementation notes**

- The second criterion was written as "confirm the compiled-in presets `codex`, `claude-code`, `opencode` exist", and **its premise is false**. On a clean `$HOME` nono 0.73.0 ships nine built-in profiles and every one is a language runtime: `bun-dev default go-dev java-dev linux-host-compat mise-dev node-dev python-dev rust-dev`. The four agent profiles on the developing machine come from `$XDG_CONFIG_HOME/nono/packages/nolabs-ai/*`, and there is no `codex` profile from any source. The criterion was **rewritten in place to the question it was really asking**, rather than being ticked against a claim that is not true. A spike exists to settle a fork, so a criterion that presumes the answer is the thing that is wrong.
- Consequence, recorded in `plan.md`'s **P8** row: the environment authors its own confinement descriptions extending `default`. That is also what the boundary wants — `M1b` found the `nolabs-ai/claude` pack grants `$HOME/.claude` read-write, so extending it was never going to be viable.
- `nono profile show <name> --format manifest` is the structured output. `--format` takes exactly `profile` and `manifest`; `nono run --dry-run` is human text and `--diagnostics-json` prints only after a run, so neither serves. The manifest is the sandbox-capability view only, so `check_sc1` asserts grants against it while credential wiring is asserted against profile source.
- **`nono why --json` exits 0 whether the verdict is `allowed` or `denied`.** Every refusal check must read `.status`, or it passes vacuously. `nono profile validate` is the opposite and does report its verdict in the exit status, proven on three planted arms.
- Two hermeticity findings that change what the environment must set. nono makes a network update check on almost any invocation and caches it under `$XDG_STATE_HOME/nono`; `NONO_NO_UPDATE_CHECK=1` suppresses it with identical output and zero files written. And nono **silently falls back to the host's `$HOME/.config`** when `XDG_CONFIG_HOME` names a directory that does not exist, warning rather than failing — so the directory must be created before nono runs or the redirection is quietly undone.
- `ai.nix`'s "nono has no general `--env` flag" holds for the command line and not for the profile: `environment.set_vars` / `allow_vars` / `deny_vars` exist, with `$WORKDIR` expansion. This confirms D4 and D6 rather than contradicting them, and it means each agent's relocation variables live in the confinement description rather than in a wrapper. D4's *merge* claims remain unsettled and are `check_component_merge`'s job.

### M1f — Spike: which agent packages exist, and where? (Status: IMPLEMENTED)

Decides whether a `numtide/llm-agents.nix` input is added at all. It is not added speculatively.

**Scenario**: none — investigation blocking `M4b`.

- [x] For each agent, record availability in the pinned `nixpkgs` for **both** `x86_64-linux` and `aarch64-darwin`
- [x] Record which need `allowUnfree`, and scope that to the smallest `pkgs` that needs it
- [x] `research.md` records the source per agent; add the extra input only if something is genuinely missing

**Implementation notes**

- Evaluated against the revision in `flake.lock`, not against the `nixpkgs#` registry alias, which on this machine resolves elsewhere and gives different versions. The alias was used first and its answers were discarded.
- **`pi` is absent from the pinned `nixpkgs` entirely**, on both platforms. That is the "something genuinely missing" the task made the condition, so `numtide/llm-agents.nix` is added rather than declined. It carries all four agents plus `nono`, identically on `x86_64-linux` and `aarch64-darwin`.
- A second reason emerged that the plan did not anticipate: the pinned `nixpkgs` has `nono-0.68.0`, while every finding in `M1b`, `M1c` and `M1e` was observed against `0.73.0`. Taking `nono` from the same input as the agents keeps the confinement descriptions and the binary that reads them on one pin. `plan.md`'s Technical context said 0.71.0, matching neither source; that row was corrected in place.
- **`allowUnfree` is set explicitly for `claude-code` even though the chosen source does not require it.** `llm-agents.nix` labels it `fullName = "Unfree"`, `redistributable = false`, yet sets `free = true`, so the gate never fires; the pinned `nixpkgs` sets `free = false` and it does. Depending on an upstream mislabel to pass a gate is the silent fallback **P9** forbids — it would break on the day the label is corrected, with nothing here having changed. Scoped to a `pkgs` instantiated for that one package.
- **The input is the sole source of all five packages, in the environment and in the checks alike**, confirmed with the user after this task's findings were reported. Its `nixConfig.extra-substituters` for `https://cache.numtide.com` is not inherited by a consumer of this flake, so that substituter and its key `niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=` are re-declared here and passed explicitly in CI; the earlier note treating the cache as a first-run cost for the handbook understated it, and `research.md` was corrected in place. The input also pins its own unstable `nixpkgs`, leaving the `follows`-or-not question to `M4b`, and sets `allow-import-from-derivation = false`, which **P8** wants and nothing here relaxes.
- Upstream `HEAD` moved from `3589c005…` to `c4c6673c…` while `M1` was in flight, so the lock must pin a revision rather than track the branch or the versions recorded here stop describing what is built.
- Availability was established by evaluation, not by building. Nothing was built for `aarch64-darwin`, and no check in this repository can reach that platform.

**Checkpoint**: every architectural fork in `plan.md` is closed. Implementation may begin.

______________________________________________________________________

## M2 — The previous project leaves

Independent of everything else, and it clears the ground. Doing it first means no later check passes because a Kafka leftover happened to satisfy it.

### M2a — No artefact of the prior project remains (Status: PENDING)

**Scenario**: R7

**RED**: write `check_r7`, which evaluates the devShell and asserts no Kafka artefact appears by name in packages, variables or `.gitignore`. It fails against the current `flake.nix`.

- [ ] Check written and seen to FAIL with: `kafka artefact present in devShell: kcat`
- [ ] Remove `kcat kafkactl postgresql lazysql openjdk25 maven` and the six leftover variables from `flake.nix`; remove `materialize/.config/`, `current-context.yml`, `.env` from `.gitignore`
- [ ] `bash scripts/validate.sh --layer unit` passes
- [ ] Violation planted (re-add `kcat`), seen to FAIL, reverted, recorded in plan.md
- [ ] `nixfmt` and `nix flake check` clean

### M2b — The two bootstrap variables are mirrored (Status: PENDING)

P1's bootstrap exception requires a check that parses both files. `flake.nix` claims one exists; it does not.

**Scenario**: P1 mirror

**RED**: write `check_bootstrap_mirror`. It parses `TMPDIR` and `XDG_CACHE_HOME` out of `.envrc` and out of `flake.nix` and compares them byte-for-byte. It must be bash, not zsh, because of `${!v}`.

- [ ] Check written and seen to FAIL with: `bootstrap variables differ between .envrc and flake.nix` after a deliberate edit
- [ ] The stale `flake.nix` comment referencing `.claude/settings.json` and a non-existent `scripts/validate.sh` is corrected to name the real check
- [ ] Violation planted (change `TMPDIR` in `.envrc` only), seen to FAIL, reverted, recorded in plan.md

### M2c — The container and the orphans are deleted (Status: PENDING)

**Scenario**: none — deletion. Verified by the absence of any check that referenced them and by `nix flake check` still passing.

- [ ] Delete `devenv.nix`, `devenv.yaml`, `ai.nix`, `draft1.md`, `draft2.md`
- [ ] Add `/.agents/` to `.gitignore` ([D8](plan.md#d8))
- [ ] `nix flake check` passes; `bash scripts/validate.sh --layer unit` passes

______________________________________________________________________

## M3 — The registry and the confinement description

### M3a — The leak registry is typed and well-formed (Status: PENDING)

**Scenario**: SC-2

**RED**: write `check_registry` asserting the three invariants in [plan.md § Properties](plan.md#properties). It fails because `lib/leak-registry.nix` does not exist.

- [ ] Check written and seen to FAIL with: `lib/leak-registry.nix: no such file`
- [ ] `lib/leak-registry.nix` written with the `submodule` entry type and an **empty** entry list, carrying the comment explaining why `$HOME/.nono` is not an entry ([D2](plan.md#d2))
- [ ] `spec.md` line 272 corrected in place: the mechanism's state root is an accepted leak, not a registry entry
- [ ] `nix eval --json .#leakRegistry` succeeds; `bash scripts/validate.sh --layer unit` passes
- [ ] Both registry violations planted, seen to FAIL, reverted, recorded in plan.md

### M3b — A confinement description is generated and validates (Status: PENDING)

**Scenario**: none directly — this is the artefact SC-1 asserts against. Verified by nono's own schema.

**RED**: write the component check that runs `nono profile validate` on the generated profile. It fails because `lib/confinement.nix` does not exist.

- [ ] Check written and seen to FAIL
- [ ] `lib/agents.nix` and `lib/confinement.nix` written per [plan.md § Implementation shapes](plan.md#implementation-shapes), for `codex` only
- [ ] `nono profile validate` passes on the generated profile
- [ ] Each omitted path carries a comment saying **why it is not granted** (P5)

### M3c — Granted reach is the project directory (Status: PENDING)

**Scenario**: SC-1

**RED**: write `check_sc1`, deriving the expected set from `lib/leak-registry.nix` and never restating it. It fails until the profile is correct.

- [ ] Check written and seen to FAIL with: `granted path outside project and not in registry: …`
- [ ] `bash scripts/validate.sh --layer component` passes
- [ ] Violation planted (`$HOME/.ssh` added to `filesystem.read`), seen to FAIL, reverted, recorded in plan.md

### M3d — nono's merge semantics are what the plan claims (Status: PENDING)

[D4](plan.md#d4) is a boundary contract, and P7 requires a boundary's merge behaviour be written down — and here, asserted.

**Scenario**: D4

**RED**: write `check_component_merge` asserting list union, single-value replacement, sticky-true `network.block` and replacing `open_urls`, against `nono profile show`.

- [ ] Check written and seen to FAIL with a deliberately wrong claim
- [ ] Violation planted (assert `open_urls` unions), seen to FAIL, reverted, recorded in plan.md

______________________________________________________________________

## M4 — Journey 1: one confined agent

The MVP slice. After this group `codex` is confined and could be handed to a consumer even if nothing else lands.

### M4a — The pre-flight refuses an unenforceable host (Status: PENDING)

**Scenario**: R6

**RED**: write `check_r6`, which runs the canary unconfined and asserts exit `77` and a message naming the missing primitive.

- [ ] Check written and seen to FAIL with: no `77` and no message
- [ ] `preflight_or_die` written with **three** assertions, so "nono failed to start" cannot pass as "the child was denied" (P9)
- [ ] `bash scripts/validate.sh --layer integration` passes
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md
- [ ] `shellcheck` clean; the task is under ~50 lines of shell

### M4b — A confined `codex` starts (Status: PENDING)

**Scenario**: Journey 1.1

**RED**: write `check_j1_1` against a `codex` on `PATH` that does not yet exist.

- [ ] Check written and seen to FAIL with: `codex: command not found`
- [ ] `lib/confined-agent.nix` written; the wrapper shadows the agent name and the raw binary is not on `PATH` ([D3](plan.md#d3))
- [ ] `flake.nix` exports `devShells.<system>.default` for **both** systems via `lib.genAttrs` ([D7](plan.md#d7))
- [ ] `bash scripts/validate.sh --layer integration` passes

**Checkpoint**: Journey 1 is independently verifiable by `bash scripts/validate.sh --layer integration`.

______________________________________________________________________

## M5 — The boundary holds

Refusals come immediately after the first working session, because they are what the feature exists to guarantee.

### M5a — A key outside the project is unreadable (Status: PENDING)

**Scenario**: R1

**RED**: `check_r1` plants an SSH key in the fake `$HOME` and reads it from inside.

- [ ] Check written and seen to FAIL
- [ ] Assertion covers both halves: the read fails **and** no key material appears in the output
- [ ] Violation planted (`$HOME/.ssh` in the registry), seen to FAIL, reverted, recorded in plan.md

### M5b — A write outside the project is refused (Status: PENDING)

**Scenario**: R2

**RED**: `check_r2` creates a file in the fake `$HOME` from inside.

- [ ] Check written and seen to FAIL
- [ ] Assertion covers both halves: the attempt fails **and** the file does not exist afterwards
- [ ] Violation planted (`filesystem.allow = ["$HOME"]`), seen to FAIL, reverted, recorded in plan.md

### M5c — No host secret crosses (Status: PENDING)

**Scenario**: R3

**RED**: `check_r3` exports a random canary as `ANTHROPIC_API_KEY` and prints the confined environment.

- [ ] Check written and seen to FAIL with the canary present
- [ ] `environment.allow_vars` written explicitly, default-deny ([D6](plan.md#d6))
- [ ] The canary is generated per run, so the check asserts a property rather than a value
- [ ] Violation planted (remove `allow_vars`), seen to FAIL, reverted, recorded in plan.md

### M5d — An agent cannot widen its own confinement (Status: PENDING)

**Scenario**: R4

**RED**: `check_r4` rewrites `lib/leak-registry.nix` from inside a running session.

- [ ] Check written and seen to FAIL
- [ ] Both halves asserted: the running session's reach is unchanged, **and** a newly started session's reach is unchanged before re-entry
- [ ] Violation planted (wrapper reads the profile from `$PWD`), seen to FAIL, reverted, recorded in plan.md

### M5e — An untrusted repository cannot grant itself paths (Status: PENDING)

**Scenario**: R5

**RED**: `check_r5` places an agent config file in the checkout requesting `$HOME`.

- [ ] Check written and seen to FAIL
- [ ] FR-15's override path is exercised too: widening works from the invocation, and only from there

### M5f — A host-global configuration does not reach the session (Status: PENDING)

**Scenario**: R9

**RED**: `check_r9` populates the fake `$HOME` with a host-global agent configuration.

- [ ] Check written and seen to FAIL
- [ ] Both halves asserted: unreadable from inside, **and** the session still starts rather than failing on its absence (FR-21)
- [ ] Violation planted (`$XDG_CONFIG_HOME/opencode` in the registry), seen to FAIL, reverted, recorded in plan.md

**Checkpoint**: every refusal in the spec except R7, R8 is executable.

______________________________________________________________________

## M6 — State stays, and projects do not cross

### M6a — Agent state lands in the project (Status: PENDING)

**Scenario**: Journey 2.1

**RED**: `check_j2_1` snapshots the fake `$HOME`, runs a session that writes history, and diffs.

- [ ] Check written and seen to FAIL with a non-empty `$HOME` diff
- [ ] `stateVars` wired into `environment.set_vars`; the property `∀ (k,v) ∈ set_vars. v ⊑ "$WORKDIR"` is asserted over the agent table, not per variable
- [ ] Violation planted (drop `CODEX_HOME`), seen to FAIL, reverted, recorded in plan.md

### M6b — Two concurrent projects share nothing (Status: PENDING)

**Scenario**: Journey 3.1

**RED**: `check_j3_1` runs two sessions **genuinely concurrently**, not in sequence — spec Risk 16 is that ports and the shared state directory contend.

- [ ] Check written and seen to FAIL
- [ ] Both halves asserted: the other project directory is unchanged, and neither reach includes the other
- [ ] Violation planted (grant the sibling checkout), seen to FAIL, reverted, recorded in plan.md

______________________________________________________________________

## M7 — Credentials

Gated on `M1b`. Whichever branch of [D1](plan.md#d1) it resolved to, the scenarios below are unchanged; only the mechanism differs.

### M7a — A readable credential is a substitute (Status: PENDING)

**Scenario**: Journey 4.1

**RED**: `check_j4_1` asserts every readable credential value matches the substitute form, using mock credentials.

- [ ] Check written and seen to FAIL
- [ ] The live-rejection half is recorded in the coverage gap, not silently skipped
- [ ] If the resolved branch is (b), the credential file becomes the registry's first entry, with both justification fields written

### M7b — Authenticating once serves every project (Status: PENDING)

**Scenario**: Journey 5.1

**RED**: `check_j5_1` authenticates in checkout A and asserts an authenticated state in checkout B.

- [ ] Check written and seen to FAIL
- [ ] The tension with FR-4 is resolved explicitly: credentials are machine-scoped, all other agent state is project-scoped, and the plan says which is which

### M7c — Authentication failure is not a denial (Status: PENDING)

**Scenario**: R8

**RED**: `check_r8` invalidates the stored substitute and makes a request.

- [ ] Check written and seen to FAIL
- [ ] The assertion is that the two messages **differ** and that the authentication one is identifiable — not that upstream emits a particular string, which is not ours to demand

### M7d — Authenticating twice is harmless (Status: PENDING)

**Scenario**: Rep3

**RED**: `check_rep3` authenticates twice and compares the resulting state.

- [ ] Check written and seen to FAIL

### M7e — The toolchain survives interception (Status: PENDING)

**Scenario**: Journey 6.1

**RED**: `check_j6_1` pushes a commit to a scratch remote over HTTPS from inside a session. Shaped by `M1c`.

- [ ] Check written and seen to FAIL with a certificate error, which is the documented failure mode
- [ ] CA trust propagated to every runtime inside the boundary — Node and Go each need their own variable (FR-17)
- [ ] Violation planted (remove the CA variables), seen to FAIL, reverted, recorded in plan.md

______________________________________________________________________

## M8 — The remaining three agents

### M8a — Extract `mkConfinedAgent` (Status: PENDING)

A refactor, and therefore its own task per P6. No behaviour changes.

**Scenario**: none — refactor.

- [ ] `nix eval --json .#confinement.codex | jq -S .` captured before
- [ ] The codex-specific wrapper generalised to `mkConfinedAgent name`
- [ ] The same eval captured after; **the diff is empty**, which is the definition of preserved behaviour
- [ ] `bash scripts/validate.sh` passes unchanged

### M8b — `claude-code`, including its subagent fallback (Status: PENDING)

**Scenario**: Journey 2.1 extended — spec Risk 12: `CLAUDE_CONFIG_DIR` has documented fallbacks in subagent and lock paths.

- [ ] `check_j2_1` extended to exercise a **subagent** run, not only a plain session
- [ ] Any surviving fallback path is either confined by other means or becomes a registry entry with both justification fields
- [ ] Seen to FAIL before the fix

### M8c — `opencode` (Status: PENDING)

**Scenario**: Journey 2.1 for `opencode`.

- [ ] Its own variables used, never a blanket `XDG_DATA_HOME` (P1)
- [ ] Seen to FAIL before the fix

### M8d — `pi`, and pre-provisioned extensions (Status: PENDING)

**Scenario**: Journey 2.1 for `pi`, plus FR-22.

Shaped by `M1d`. If relocation holds, `pi` needs no registry entry.

- [ ] Extensions provisioned through Nix before the session, never fetched from inside it (FR-22)
- [ ] The path for a consumer who must install an extension — outside the confined entry point — is documented rather than left to be discovered
- [ ] Seen to FAIL before the fix

**Checkpoint**: FR-1 is satisfied; all four agents are confined and `check_sc1` still passes without being edited, which is the property SC-1 asserts.

______________________________________________________________________

## M9 — Consumability, idempotency and CI

### M9a — A stranger reaches a confined agent from the ref (Status: PENDING)

**Scenario**: Journey 1.1 at the end-to-end layer — the layer AGENTS.md names as the one that matters and the one easiest to fake.

**RED**: `check_j1_1` at e2e runs `nix develop <canonical ref>` with `HOME=$(mktemp -d)`, from the pushed ref and never from the working tree.

- [ ] Check written and seen to FAIL
- [ ] FR-19: the canonical reference is `github:GRBurst/agent-sandbox`, named identically in every document; the handbook's current owner and repository are both wrong and are corrected
- [ ] No step depends on the author's configuration (SC-5)

### M9b — Entering and verifying twice change nothing (Status: PENDING)

**Scenario**: Rep1 and Rep2 — two scenarios, so if either needs more than a trivial edit, split this task.

- [ ] `check_rep1`: tracked files unchanged and granted reach byte-identical
- [ ] `check_rep2`: same result, no residue a third run would trip over
- [ ] Violation planted (`validate.sh` writes a log into the checkout), seen to FAIL, reverted, recorded in plan.md

### M9c — The claims are checked on clean machines, per platform (Status: PENDING)

**Scenario**: Journey 7.1

- [ ] `.github/workflows/verify.yml` runs `scripts/validate.sh` on `ubuntu-latest` and `macos-latest`
- [ ] Exit status alone separates a passing commit from a failing one; no human reads the output (SC-4)
- [ ] FR-20 asserted: the resolved reach is compared **across** the two platform jobs and must be equal
- [ ] Planting a registry entry changes the expected set without the check being edited — the third `Then` of Journey 7
- [ ] `AGENTS.md`'s "no CD pipeline" sentence amended to permit non-deploying CI, retaining the prohibition on deployment

**Checkpoint**: `check_sc3` passes for the first time — every scenario has its check, and the bijection is closed.

______________________________________________________________________

## M10 — Documentation

### M10a — Close out (Status: PENDING)

- [ ] `docs/HANDBOOK.md` updated: how to use what landed, the accepted leak `$HOME/.nono` with its justification, and the coverage gap from [plan.md](plan.md#coverage-gap)
- [ ] Known drift entries retired and deleted: Kafka leftovers, `x86_64-linux` hardcoding, the four devcontainer bind mounts, orphaned `ai.nix`, the stray `^`, missing `scripts/validate.sh`, missing `README.md`, absent `shellcheck`/`shfmt`
- [ ] Root `README.md` written: component table taken from the code, one `flowchart LR` for structure, one `sequenceDiagram` per phase including **a refused case of its own** (AGENTS.md §6), checked by eye in both themes
- [ ] The migration path for a consumer with a host-global setup is documented (FR-21)
- [ ] The way to run an agent unconfined — by not invoking the confined entry point — is described rather than concealed (FR-10)
- [ ] Every open question in `spec.md` resolved in place with a one-line outcome
- [ ] `docs/CONSTITUTION.md` P1's accepted-leak list amended to its second entry
- [ ] Touched files formatted and linted per [AGENTS.md](../../AGENTS.md#4-verify-every-change)
- [ ] `scripts/validate.sh` passes
