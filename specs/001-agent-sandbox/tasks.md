# Tasks: Confined agent sessions per project

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Read [plan.md § Read first](plan.md#read-first) before starting `M1a`. One task is one commit. RED before GREEN, every time.

______________________________________________________________________

## M1 — Ground truth: the harness, and the unknowns that block design

The spikes exist because [D1](plan.md#d1) forks the architecture and the fork cannot be guessed. Each spike ends with a written finding in `research.md`, not with code.

`M1a` through `M1f` have landed. `M1g` was added after them, because closing `M1b` and `M1c` moved `claude-code` from one agent among several to the reference case and the credential source for the other two, and nothing in `M1` had established that its configuration root relocates. It is the first task of the implementing session.

### M1a — The scenario ↔ check bijection (Status: DONE)

The first check written, before any implementation exists. It fails immediately and keeps failing until the last scenario lands, so it is the feature's progress bar.

**Scenario**: SC-3

**RED**: `scripts/validate.sh` does not exist. Create it with `set -euo pipefail`, a `--list` flag and `check_sc3` only. It parses scenario IDs out of `spec.md` and `check_*` function names out of itself, and diffs the sets.

- [x] Check written and seen to FAIL with: `scenario ↔ check bijection broken` listing all 19 missing checks
- [x] `bash scripts/validate.sh --layer unit` runs and reports the 19 as missing without erroring on its own parsing
- [x] Violation planted (delete `check_r5` once stubs exist), seen to FAIL, reverted, recorded in [plan.md](plan.md#planted-violations)
- [x] `shellcheck` and `shfmt -d` clean

**Implemented.** `scripts/validate.sh` is the driver and `scripts/checks/<layer>.sh` holds the checks, one file per layer, `unit component integration e2e` cheapest first. Nothing enumerates the checks: the driver greps `^check_*()` out of each layer file, so a check cannot be added without being run.

Decisions the plan did not anticipate:

- **Checks live in `scripts/checks/<layer>.sh`, not inside `validate.sh`.** The plan's sketch put `check_sc3` in `validate.sh` itself. A single file holding every scenario check across four layers would not survive M5–M8, and the layer a check belongs to is then implicit. The file *is* the layer declaration. `check_sc3` derives both sides of the bijection from source — scenario IDs by parsing the spec's `## Scenarios` section, check IDs by grepping the layer files — so neither side is a list anyone maintains by hand.
- **Every layer file is sourced even under `--layer`**, because `check_sc3` asserts over the whole suite; running only the unit layer must not make the bijection look satisfied.
- **Three anti-vacuity guards were added and each was proven to bite**, since a bijection between two empty sets holds while testing nothing: a suite that ran no checks exits `2`, a spec that parses to no scenarios fails, and an unrecognised argument exits `2` rather than being ignored (P9).
- The planted violation for `check_r5` needed a green suite to bite, so all 19 checks were stubbed transiently, the deletion was observed to isolate exactly `r5`, and the stubs were removed. The suite is intentionally left RED: `check_sc3` is the feature's progress bar and goes green only when the last scenario lands.
- **The baseline is now 20, not the 19 recorded above.** `R10` was added to the spec after this task landed, and `check_sc3` picked it up with no edit to the parser or to any list — which is the property the check was written for. A run today reports `j1_1 j2_1 j3_1 j4_1 j5_1 j6_1 j7_1 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 rep1 rep2 rep3`, `1 of 1 checks failed`, exit 1. That set is the baseline every later task compares against: the failing set shrinks by exactly the scenarios the task covers, and nothing else moves.

### M1b — Spike: can each agent be pointed at a substituted endpoint? (Status: DONE)

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
- All four agents were inspected rather than reasoned about: `claude-code` `ANTHROPIC_BASE_URL`, `opencode` `provider.<id>.options.baseURL`, `pi` `providers.<id>.baseUrl`, `codex` `model_providers.<id>.base_url`. `codex` was built from the pinned nixpkgs to check it; it substituted without compiling. `codex` was subsequently dropped from this feature, and its findings stay in `research.md` as the follow-up's head start rather than being deleted — the work is done and re-doing it would cost a build.
- Two findings the plan did not anticipate, recorded in `research.md` and carried forward: `nono run --credential __bogus__ --dry-run true` exits 0, so nono does not validate credential service names and the wrapper must; and the shipped `nolabs-ai/claude` pack grants `$HOME/.claude` read-write, which is the leak this feature removes, so that pack cannot be extended unmodified.
- `spec.md` Risk 1 asserted "whether each agent's provider endpoint is configurable is what FR-6 actually turns on". That is falsified, and the risk has since been **rewritten in place as resolved** with its premise named wrong, rather than waiting for close-out. What remains of it sits under FR-7 and is narrower: not whether an endpoint can be substituted, but where the other two agents obtain the credential ([D14](plan.md#d14)).

### M1c — Spike: where does `git` get its credential inside the boundary? (Status: DONE)

Journey 6 may be unachievable as written — spec Risk 2, which is a gap in the spec rather than in the research.

**Scenario**: none — investigation blocking Journey 6.

- [x] Establish what a host credential helper, `~/.git-credentials` and the system keychain each do under confinement
- [x] Decide: a registry entry for `git`, routing `git` through substitution, or narrowing Journey 6 to a credential-free toolchain
- [x] `research.md` records the decision; if Journey 6 narrows, `spec.md` is corrected in place rather than annotated

**Implementation notes.**

- All three sources are unreachable, and two of them by a floor no profile can lower: `~/.git-credentials` sits in `deny_credentials` and the keychains in `deny_keychains_{linux,macos}`, all three groups carrying `"required": true`. A helper is not discovered at all, because `~/.gitconfig` is readable only through the `git_config` group, which the plan already declines over `core.hooksPath`.
- **Decision: narrow Journey 6, and give `git` no registry entry.** Routing `git` through substitution was rejected as a shipped default rather than as impossible — it works, but it names one forge and demands a token no requirement asks for. It is recorded in `research.md` as the consumer's extension and in `spec.md` under Out of scope.
- The journey's *purpose* was never authentication. It exists for FR-17, trust in the inspecting authority. A credential-free exchange tests that and nothing else; a push would have conflated it with a requirement no FR supplies.
- **The trust-propagation half of this task was got wrong first and corrected afterwards, and the correction is the more valuable finding.** It was recorded here as "nono propagates trust to `git` through `GIT_SSL_CAINFO`", inferred from a contiguous run of variable names in the binary. A plain `nono run -- env` then carried 233 variables into a child and not one of them was a CA variable. The truth is conditional: interception has no on switch of its own, and the five trust-bundle variables appear only when a destination is asked for in the form that inspects it. So the credential-free exchange alone proves nothing — it succeeds identically with interception off, because the system trust store is in the floor. That is what forced [D9](plan.md#d9) and the three-arm `check_j6_1`, and `research.md` keeps all three stages rather than only the answer.
- `spec.md` was corrected in place, as this task's third criterion directs: Journey 6's When, Then and *Independently verifiable by*, a new Out of scope bullet, and Risk 2 rewritten as resolved by its own stated fallback. This is the sanctioned counterpart to `M1b`, where no criterion authorised a spec edit and none was made.
- One trap kept for the `codex` follow-up: nono's `codex_macos` group grants `$HOME/Library/Keychains/login.keychain-db` read **and write**, which would undo `deny_keychains_macos`.
- **Verification gap, since closed by hand.** `nono run` cannot execute from an agent session in this repository, because the outer sandbox denies `$HOME` and nono fails to create its own audit directory under `$XDG_STATE_HOME/nono`. Anything needing a live session is therefore run by a human, or by the checks on a machine where `$HOME` is writable. Both live runs behind the correction above were run that way.

### M1d — Spike: does `pi`'s configuration root actually relocate? (Status: DONE)

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

### M1e — Spike: is nono's resolved policy machine-readable? (Status: DONE)

`check_sc1` is hermetic only if there is structured output to assert against; spec Risk 15.

**Scenario**: none — investigation blocking `M3c`.

- [x] Compare `nono profile show --format profile`, `nono why --path … --op …` and `nono run --dry-run` for machine-readable output
- [x] Establish which presets exist without any registry pull, via `nono profile list` on a clean `$HOME`
- [x] Confirm `nono profile schema` exports a schema usable by `nono profile validate`
- [x] `research.md` records which command `check_sc1` and `check_component_merge` will use

**Implementation notes**

- The second criterion was written as "confirm the compiled-in presets `codex`, `claude-code`, `opencode` exist", and **its premise is false**. On a clean `$HOME` nono 0.73.0 ships nine built-in profiles and every one is a language runtime: `bun-dev default go-dev java-dev linux-host-compat mise-dev node-dev python-dev rust-dev`. The four agent profiles on the developing machine come from `$XDG_CONFIG_HOME/nono/packages/nolabs-ai/*`, and there is no `codex` profile from any source. The criterion was **rewritten in place to the question it was really asking**, rather than being ticked against a claim that is not true. A spike exists to settle a fork, so a criterion that presumes the answer is the thing that is wrong.
- Consequence, recorded in `plan.md`'s **P8** row and since promoted to [D10](plan.md#d10): the environment authors its own confinement descriptions. That is also what the boundary wants — `M1b` found the `nolabs-ai/claude` pack grants `$HOME/.claude` read-write, so extending it was never going to be viable. This note first said the descriptions extend `default`; they name **no** parent at all, because a description was subsequently observed to resolve byte-identically with and without `extends: ["default"]`. The floor is the floor either way, and naming it implies an inheritance that is not what is happening.
- `nono profile show <name> --format manifest` is the structured output. `--format` takes exactly `profile` and `manifest`; `nono run --dry-run` is human text and `--diagnostics-json` prints only after a run, so neither serves. The manifest is the sandbox-capability view only, so `check_sc1` asserts grants against it while credential wiring is asserted against profile source.
- **`nono why --json` exits 0 whether the verdict is `allowed` or `denied`.** Every refusal check must read `.status`, or it passes vacuously. Sharpened afterwards: it must read `.reason` as well, because a query nono cannot answer at all — `--command` with no profile in context — still reports `denied`, with reason `command_policy_unavailable`. Any `*_unavailable` reason is an error, not a refusal. `nono profile validate` is the opposite and does report its verdict in the exit status, proven on three planted arms.
- Two hermeticity findings that change what the environment must set. nono makes a network update check on almost any invocation and caches it under `$XDG_STATE_HOME/nono`; `NONO_NO_UPDATE_CHECK=1` suppresses it with identical output and zero files written. And nono **silently falls back to the host's `$HOME/.config`** when `XDG_CONFIG_HOME` names a directory that does not exist, warning rather than failing — so the directory must be created before nono runs or the redirection is quietly undone.
- `ai.nix`'s "nono has no general `--env` flag" holds for the command line and not for the profile: `environment.set_vars` / `allow_vars` / `deny_vars` exist, with `$WORKDIR` expansion. This confirms D4 and D6 rather than contradicting them, and it means each agent's relocation variables live in the confinement description rather than in a wrapper. D4's *merge* claims remain unsettled and are `check_component_merge`'s job.

### M1f — Spike: which agent packages exist, and where? (Status: DONE)

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

### M1g — Spike: does `claude-code`'s configuration root relocate? (Status: PENDING)

The last open fork, and the one the rest of the feature now rests on. `M1d` asked this of `pi` because a research round had contradicted itself; nobody asked it of `claude-code`, when it was one agent among four. It is now the reference case (FR-1) **and** the credential source the other two draw from ([D14](plan.md#d14)), so FR-4 and FR-7 both stand on the answer.

A first look at the payload counts thirteen candidate variables rather than one — `CLAUDE_CONFIG_DIR` most often, `CLAUDE_SECURESTORAGE_CONFIG_DIR` where the credential plausibly comes to rest, and eleven more for jobs, plugins, skills, memory, logs and temporary files. A count establishes that a name is read somewhere. It does not establish that it governs what it appears to: `M1d` found a documented variable that the binary does not contain at all, so the evidentiary standard is observation, not occurrence.

**Scenario**: none — investigation blocking `M4b` and `M7a`.

**RED**: not applicable; a spike has no check. It is a task because it is a commit and it blocks two milestones.

- [ ] Set the candidate variables into the project, run `claude`, and record what is written under each — and whether anything at all is written under `$HOME`
- [ ] Run the **control**: the same invocation with nothing set, so the default is fixed by observation and the override is shown to be what moved it, as `M1d` did for `pi`
- [ ] Establish where the credential comes to rest, since FR-7 reads it from there and `M7a` asserts its form
- [ ] Record whether any surviving path needs a registry entry (FR-3), with both justification fields drafted if so
- [ ] `research.md` states the finding per variable with its evidence; `plan.md`'s `lib/agents.nix` sketch and `spec.md`'s relocation assumption are corrected in place to match

A live `claude` cannot run from an agent session here, for the reason `M1c` recorded. Either a human runs it, or it runs on a machine where `$HOME` is writable.

**Checkpoint**: every architectural fork in `plan.md` is closed. Implementation may begin.

______________________________________________________________________

## M2 — The previous project leaves

Independent of everything else, and it clears the ground. Doing it first means no later check passes because a Kafka leftover happened to satisfy it.

### M2a — No artefact of the prior project remains (Status: PENDING)

**Scenario**: R7

**RED**: write `check_r7`, which evaluates the devShell and asserts no artefact of the prior project appears by name in packages, variables or `.gitignore`, **and** that a package the environment does need is found — the positive control [D9](plan.md#d9) requires, without which the check passes against an empty devShell.

- [ ] Check written and seen to FAIL with: `kafka artefact present in devShell: kcat`
- [ ] FR-18 satisfied: remove the packages `kcat kafkactl postgresql lazysql openjdk25 maven nodejs zellij` and the six variables `KCAT_CONFIG KAFKA_CTL_CONFIG PSQLRC PSQL_HISTORY MAVEN_ARGS MAVEN_OPTS` from `flake.nix`; correct `description` from `"Hivemind Kafka Playground"`; remove `materialize/.config/`, `current-context.yml`, `.env` from `.gitignore`
- [ ] `bash scripts/validate.sh --layer unit` passes
- [ ] Violation planted (re-add `kcat`), seen to FAIL, reverted, recorded in plan.md
- [ ] `nixfmt` and `nix flake check` clean

The leftovers are not only a tidiness matter. A live session was observed inheriting `JAVA_HOME` and an `XDG_DATA_DIRS` carrying openjdk, postgresql, zellij and nodejs store paths, so they are on the boundary this feature is drawing, not beside it. Formatting is `nixfmt`, per [AGENTS.md](../../AGENTS.md#4-verify-every-change); an `alejandra`-formatted `flake.nix` was discarded once already.

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
- [ ] Delete the `.devenv*`, `devenv.local.nix` and `devenv.local.yaml` entries from `.gitignore`, which have nothing left to ignore
- [ ] Add `/.agents/` to `.gitignore` ([D8](plan.md#d8))
- [ ] `nix flake check` passes; `bash scripts/validate.sh --layer unit` passes

`ai.nix` is the prior art and it earned its keep during `M1`: its comment "nono has no general `--env` flag" turned out true of the command line and false of the confinement description, which is how [D4](plan.md#d4) and [D6](plan.md#d6) came to be confirmed rather than guessed, and its `~/.claude` read-write grants are the arrangement [D14](plan.md#d14) rejects. All of that is now in `research.md` with its evidence, so deleting the file here — before `M8` reaches the agents it configured — loses nothing that `M8` will need.

______________________________________________________________________

## M3 — The registry and the confinement description

### M3a — The leak registry is typed and well-formed (Status: PENDING)

**Scenario**: SC-2

**RED**: write `check_registry` asserting the three invariants in [plan.md § Properties](plan.md#properties). It fails because `lib/leak-registry.nix` does not exist.

- [ ] Check written and seen to FAIL with: `lib/leak-registry.nix: no such file`
- [ ] `lib/leak-registry.nix` written with the `submodule` entry type and an **empty** entry list, carrying the comment explaining why the mechanism's own state root is not an entry ([D2](plan.md#d2)). That root is `$XDG_STATE_HOME/nono`, not `$HOME/.nono` — one research round claimed the latter and `M1c` observed the former
- [ ] The spec's assumption about the mechanism's state root reads as an accepted leak rather than a registry entry, corrected in place if it does not
- [ ] `nix eval --json .#leakRegistry` succeeds; `bash scripts/validate.sh --layer unit` passes
- [ ] Both registry violations planted, seen to FAIL, reverted, recorded in plan.md

An empty list is the expected outcome, not a placeholder: `M1b` resolved [D1](plan.md#d1) to the branch where no agent needs a credential file granted, and [D14](plan.md#d14) closed the one route that would have added one. The check must therefore hold over an empty list without passing vacuously — `check_registry` asserts the entry *type* rejects a malformed entry, which is a property of the type and does not need an instance.

### M3b — A confinement description is generated and validates (Status: PENDING)

**Scenario**: none directly — this is the artefact SC-1 asserts against. Verified by nono's own schema.

**RED**: write the component check that runs `nono profile validate` on the generated profile. It fails because `lib/confinement.nix` does not exist.

- [ ] Check written and seen to FAIL
- [ ] `lib/agents.nix` and `lib/confinement.nix` written per [plan.md § Implementation shapes](plan.md#implementation-shapes), for `claude-code` only
- [ ] The description names **no parent** and takes what it needs by group inclusion ([D10](plan.md#d10)); `meta.name` is set, because nono refuses the profile without it
- [ ] `groups.include` carries `nix_runtime`, and does **not** carry `git_config` ([D11](plan.md#d11))
- [ ] `environment.set_vars` carries the relocation variables `M1g` established, plus `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`
- [ ] `nono profile validate` passes on the generated profile
- [ ] Each omitted path carries a comment saying **why it is not granted** (P5)

`nix_runtime` is not optional cosmetics: `/nix/store` is absent from the floor, and a session without it exits 127 before the agent runs. It is included as a group rather than granted by path, because the group grants read and a path grant would give read **and** write to the store.

### M3c — Granted reach is the project directory (Status: PENDING)

**Scenario**: SC-1

**RED**: write `check_sc1`, deriving the expected set from `lib/leak-registry.nix` and never restating it. It fails until the profile is correct.

- [ ] Check written and seen to FAIL with: `granted path outside project and not in registry: …`
- [ ] The resolved reach is read from `nono profile show <name> --format manifest`, as `M1e` established, and the paths from `.filesystem.grants[].path`
- [ ] The set asserted is FR-2's: the project directory plus leak-registry entries, and nothing else — an equality, not a containment
- [ ] The grants the floor supplies unconditionally are excluded by deriving them from a description that declares nothing, not by listing them ([D4](plan.md#d4))
- [ ] `bash scripts/validate.sh --layer component` passes
- [ ] Violation planted (`$HOME/.ssh` added to the description's grants), seen to FAIL, reverted, recorded in plan.md

The manifest is the sandbox-capability view only. Credential wiring does not appear in it, so nothing about `network.credentials` or `credential_routes` can be asserted here; `M7` asserts those against the description's own source.

### M3d — the merge is what the plan claims (Status: PENDING)

[D4](plan.md#d4) is a boundary contract, and P7 requires a boundary's merge behaviour be written down — and here, asserted. The schema does not settle it: it describes what fields exist, not how they combine.

**Scenario**: D4

**RED**: write `check_component_merge` asserting the three claims [D4](plan.md#d4) actually rests on, against `nono profile show --format manifest`: that a group's `deny` outranks a grant the description makes for the same path, that the floor's grants are present whether or not a parent is named, and that the environment filter applies `deny_vars` before `allow_vars`.

- [ ] Check written and seen to FAIL with a deliberately wrong claim
- [ ] Nothing is asserted from the schema alone; every claim is observed against a resolved description
- [ ] Violation planted (assert a description's grant beats a required group's `deny`), seen to FAIL, reverted, recorded in plan.md

This task no longer asserts `extends` semantics. [D10](plan.md#d10) means no description this environment ships names a parent, so how `extends` combines two descriptions is not a contract anything here depends on. What is still a contract is the merge of the floor, the included groups and the description's own declarations — and the first of those three claims is the one the boundary rests on, because it is what makes a `required` deny group unable to be undone by a mistake elsewhere.

______________________________________________________________________

## M4 — Journey 1: one confined agent

The MVP slice. After this group `claude-code` is confined and could be handed to a consumer even if nothing else lands. It is the reference case not because it is the easiest — `M1g` exists precisely because it is not — but because `opencode` and `pi` obtain their credential from the session it authenticates, so nothing about FR-6 or FR-7 can be shown until it works.

### M4a — The pre-flight refuses an unenforceable host (Status: PENDING)

**Scenario**: R6

**RED**: write `check_r6`, which runs the canary unconfined and asserts exit `77` and a message naming the missing primitive.

- [ ] Check written and seen to FAIL with: no `77` and no message
- [ ] `preflight_or_die` written with **three** assertions, so "nono failed to start" cannot pass as "the child was denied" (P9)
- [ ] The positive control is that the same pre-flight exits 0 on the machine running the suite, so a pre-flight that refuses every host cannot pass this check ([D9](plan.md#d9))
- [ ] `bash scripts/validate.sh --layer integration` passes
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md
- [ ] `shellcheck` clean; the task is under ~50 lines of shell

### M4b — A confined `claude` starts (Status: PENDING)

**Scenario**: Journey 1.1

**RED**: write `check_j1_1` against a `claude` on `PATH` that does not yet exist.

- [ ] Check written and seen to FAIL with: `claude: command not found`
- [ ] `lib/confined-agent.nix` written; the wrapper shadows the agent name and the raw binary is not on `PATH` ([D3](plan.md#d3))
- [ ] `flake.nix` exports `devShells.<system>.default` for **both** systems via `lib.genAttrs` ([D7](plan.md#d7))
- [ ] `numtide/llm-agents.nix` added as the sole source of `nono`, `claude-code`, `opencode` and `pi`, pinned to a revision rather than a branch, with `allowUnfree` scoped to the `pkgs` instantiated for `claude-code` ([M1f](#m1f--spike-which-agent-packages-exist-and-where-status-done))
- [ ] `nixConfig` declares `https://cache.numtide.com` and the key `niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=`, because an input's own `nixConfig` is not inherited by a consumer and a clean machine would otherwise build every agent from source
- [ ] The `inputs.nixpkgs.follows` question decided either way, with the reason written down rather than left to the default
- [ ] Violation planted (the unconfined binary on `PATH` under the agent's own name), seen to FAIL, reverted, recorded in plan.md
- [ ] `bash scripts/validate.sh --layer integration` passes

The wrapper creates `$XDG_CONFIG_HOME` before invoking nono. `M1e` observed that nono **silently falls back to the host's `$HOME/.config`** when that directory does not exist, warning rather than failing — so the redirection is undone by exactly the condition a fresh checkout is in.

**Checkpoint**: Journey 1 is independently verifiable by `bash scripts/validate.sh --layer integration`.

______________________________________________________________________

## M5 — The boundary holds

Refusals come immediately after the first working session, because they are what the feature exists to guarantee.

Every task in this group is subject to [D9](plan.md#d9): a check whose observable is a failure carries a positive control in the same session, because a session that never started, a binary that is missing and a boundary that works all produce the same failure. The control is named in each task below and is not optional.

### M5a — A key outside the project is unreadable (Status: PENDING)

**Scenario**: R1

**RED**: `check_r1` plants an SSH key in the fake `$HOME` and reads it from inside.

- [ ] Check written and seen to FAIL
- [ ] Assertion covers both halves: the read fails **and** no key material appears in the output
- [ ] **Control**: a file inside the project is read successfully in the same session, so a session that failed to start cannot pass
- [ ] Violation planted (`$HOME/.ssh` in the registry), seen to FAIL, reverted, recorded in plan.md

### M5b — A write outside the project is refused (Status: PENDING)

**Scenario**: R2

**RED**: `check_r2` creates a file in the fake `$HOME` from inside.

- [ ] Check written and seen to FAIL
- [ ] Assertion covers both halves: the attempt fails **and** the file does not exist afterwards
- [ ] **Control**: a write inside the workdir succeeds in the same session and the file is there afterwards, so a read-only session cannot pass
- [ ] Violation planted (`filesystem.allow = ["$HOME"]`), seen to FAIL, reverted, recorded in plan.md

### M5c — No host secret crosses (Status: PENDING)

**Scenario**: R3

**RED**: `check_r3` exports a random canary as `ANTHROPIC_API_KEY` and prints the confined environment.

- [ ] Check written and seen to FAIL with the canary present
- [ ] `environment.allow_vars` written explicitly, default-deny ([D6](plan.md#d6)) — the mechanism FR-5 rests on
- [ ] The canary is generated per run, so the check asserts a property rather than a value
- [ ] **Control**: a variable the session is meant to inherit — `TERM` — is present in the same output, so an empty environment cannot pass
- [ ] Violation planted (remove `allow_vars`), seen to FAIL, reverted, recorded in plan.md

The measured starting point is 233 variables crossing into a child, `HOME` and every `XDG_*` among them, and the devShell's whole `shellHook` body exported verbatim as a variable of its own. `HOME` and `XDG_STATE_HOME` stay as they are, deliberately and for different reasons ([D13](plan.md#d13)).

### M5d — An agent cannot widen its own confinement (Status: PENDING)

**Scenario**: R4

**RED**: `check_r4` rewrites `lib/leak-registry.nix` from inside a running session.

- [ ] Check written and seen to FAIL
- [ ] Both halves asserted, which together are FR-9: the running session's reach is unchanged, **and** a newly started session's reach is unchanged before re-entry
- [ ] **Control**: the edit is confirmed to have landed on disk, so a write that silently failed cannot pass as a boundary holding
- [ ] Violation planted (wrapper reads the profile from `$PWD`), seen to FAIL, reverted, recorded in plan.md

### M5e — An untrusted repository cannot grant itself paths (Status: PENDING)

**Scenario**: R5

**RED**: `check_r5` places an agent config file in the checkout requesting `$HOME`.

- [ ] Check written and seen to FAIL
- [ ] **Control**: the same file is read for a benign setting, so a file nothing reads cannot pass as a request refused
- [ ] FR-15's override path is exercised too: widening works from the invocation, and only from there
- [ ] Violation planted (the wrapper reads the in-checkout config when composing the description), seen to FAIL, reverted, recorded in plan.md

### M5f — A host-global configuration does not reach the session (Status: PENDING)

**Scenario**: R9

**RED**: `check_r9` populates the fake `$HOME` with a host-global agent configuration.

- [ ] Check written and seen to FAIL
- [ ] Both halves asserted: unreadable from inside, **and** the session still starts and works rather than failing on its absence (FR-21) — which is this check's control as well as its second half
- [ ] Violation planted (`$XDG_CONFIG_HOME/opencode` in the registry), seen to FAIL, reverted, recorded in plan.md

### M5g — A host tool configuration does not direct the session (Status: PENDING)

**Scenario**: R10

R9's counterpart for the ordinary toolchain, and the sharper case, because this one was observed happening rather than reasoned about. A live session read `credential.helper = cache` out of the host `~/.gitconfig` and tried to start a daemon; it failed only because that session's workdir happened to be read-only, and in the shipped arrangement it is not. The danger is not the file being readable but the directives in it, so a read-only grant is no protection — the same class as `core.hooksPath`, arriving through a key that looked harmless.

**RED**: `check_r10` places a configuration in the fake `$HOME` carrying a directive that runs a program, and inspects the toolchain's effective configuration from inside.

- [ ] Check written and seen to FAIL with the host directive present in the effective configuration
- [ ] `groups.include` does not carry `git_config`; `GIT_CONFIG_GLOBAL` points at a file this environment wrote and `GIT_CONFIG_SYSTEM` is `/dev/null` ([D11](plan.md#d11))
- [ ] Second arm: no process started and nothing was written outside `$WORKDIR`
- [ ] **Control**: a setting this environment *did* write is read back from the effective configuration, so a toolchain with no configuration at all cannot pass
- [ ] `user.name` and `user.email` are copied from the host once at setup and a consumer can override them (FR-23)
- [ ] Both violations planted (include `git_config`; drop `GIT_CONFIG_SYSTEM`), each seen to FAIL, reverted, recorded in plan.md

### M5h — Every refusal check has a control (Status: PENDING)

**Scenario**: none directly — this enforces [D9](plan.md#d9) over the suite, which is why it comes last in this group, when there are refusal checks to enforce it over.

**RED**: write `check_controls`, which reads the suite's own text and asserts that every `check_r*` invokes a control.

- [ ] Check written and seen to FAIL against a refusal check with its control removed
- [ ] Suite-wide violation planted — point the wrapper at a description that denies the workdir, so every refusal check fails **on its control** rather than on its subject — seen to FAIL, reverted, recorded in plan.md

This is a proxy and is written down as one: it establishes that a control is *called*, not that the control is apt. The failure mode it exists for is forgetting one entirely, which is what happened to `check_j6_1` twice, and a proxy catches that. The suite-wide plant is what raises it above bookkeeping: it demonstrates the controls bite together, not merely that they are present.

**Checkpoint**: every refusal in the spec except R7 and R8 is executable, and each one is known to fail for the reason it claims.

______________________________________________________________________

## M6 — State stays, and projects do not cross

### M6a — Agent state lands in the project (Status: PENDING)

**Scenario**: Journey 2.1

**RED**: `check_j2_1` snapshots the fake `$HOME`, runs a session that writes history, and diffs.

- [ ] Check written and seen to FAIL with a non-empty `$HOME` diff
- [ ] `stateVars` wired into `environment.set_vars`; the property `∀ (k,v) ∈ set_vars. v ⊑ "$WORKDIR"` is asserted over the agent table, not per variable
- [ ] **Control**: the writes are found where they were redirected to, under `$WORKDIR`, so an agent that wrote nothing at all cannot pass as state landing in the project ([D9](plan.md#d9))
- [ ] Violation planted (drop the state variable), seen to FAIL, reverted, recorded in plan.md

### M6b — Two concurrent projects share nothing (Status: PENDING)

**Scenario**: Journey 3.1

**RED**: `check_j3_1` runs two sessions **genuinely concurrently**, not in sequence — spec Risk 16 is that ports and the shared state directory contend.

- [ ] Check written and seen to FAIL
- [ ] Both halves asserted, which together are FR-8: the other project directory is unchanged, and neither reach includes the other
- [ ] **Control**: each session's write into its *own* checkout is present afterwards, so two sessions that both did nothing cannot pass as two sessions that did not interfere ([D9](plan.md#d9))
- [ ] Violation planted (grant the sibling checkout), seen to FAIL, reverted, recorded in plan.md

______________________________________________________________________

## M7 — Credentials

Gated on `M1b` and `M1g`. [D1](plan.md#d1) resolved to the branch where the real secret never enters the boundary, so no credential file is granted and the registry stays empty. This group lands **before** `M8` finishes, because [D14](plan.md#d14) makes `opencode` and `pi` draw their credential from the session `claude-code` authenticates — there is nothing for them to draw from until the arrangement below exists.

### M7a — A readable credential is a substitute (Status: PENDING)

**Scenario**: Journey 4.1

**RED**: `check_j4_1` asserts every readable credential value matches the substitute form, using mock credentials.

- [ ] Check written and seen to FAIL
- [ ] **Control**: the real value is present in the supervisor's store in the same run, so a run in which no credential was captured at all cannot pass as one where the substitution held ([D9](plan.md#d9))
- [ ] The wrapper validates the credential service name itself, because `nono run --credential __bogus__` exits 0 and yields an unauthenticated session rather than an error (P9)
- [ ] SC-6 is asserted over the whole project directory rather than only the agent's own state: a value that authenticates from outside the boundary, at rest anywhere inside the checkout, fails the check
- [ ] The live-rejection half is recorded in the coverage gap, not silently skipped
- [ ] The registry stays empty; if `M1g` found a path that forces an entry, it carries both justification fields
- [ ] Violation planted (expose the real value to the session instead of the substitute), seen to FAIL, reverted, recorded in plan.md

### M7b — Authenticating once serves every project, and every agent (Status: PENDING)

**Scenario**: Journey 5.1

Two axes in one scenario. Across projects is the original claim; across agents is [D14](plan.md#d14), and it is not a convenience — FR-6 and FR-3 together **exclude** the alternative, because letting `opencode` and `pi` read `claude-code`'s credential store would put a credential that works outside the boundary inside it, on a grant resting on convenience rather than structural impossibility.

**RED**: `check_j5_1` authenticates in checkout A and asserts an authenticated state in checkout B, and for an agent that never authenticated.

- [ ] Check written and seen to FAIL
- [ ] `credential_providers` captures the token flow and `credential_routes` exposes it to the session, so the other agents are pointed at the mediated route rather than at the first agent's store
- [ ] **Control**: a third identity that has *not* been authenticated must **not** work in the same session, so a route that authenticates everything cannot pass as a route that authenticates the right thing ([D9](plan.md#d9))
- [ ] The tension with FR-4 is resolved explicitly: credentials are machine-scoped, all other agent state is project-scoped, and the plan says which is which
- [ ] Violation planted (remove the route for the second agent), seen to FAIL, reverted, recorded in plan.md

### M7c — Authentication failure is not a denial (Status: PENDING)

**Scenario**: R8

**RED**: `check_r8` invalidates the stored substitute and makes a request.

- [ ] Check written and seen to FAIL
- [ ] FR-16: the assertion is that the two messages **differ** and that the authentication one is identifiable — not that upstream emits a particular string, which is not ours to demand. That difference is itself the control: two identical messages fail, and so does one message with nothing to compare it to
- [ ] Violation planted (collapse both failure paths onto one message), seen to FAIL, reverted, recorded in plan.md

### M7d — Authenticating twice is harmless (Status: PENDING)

**Scenario**: Rep3

**RED**: `check_rep3` authenticates twice and compares the resulting state.

- [ ] Check written and seen to FAIL
- [ ] **Control**: the state compared is non-empty and contains the captured credential, so two absent states cannot pass as two indistinguishable ones ([D9](plan.md#d9))
- [ ] Violation planted (authentication records the session it ran in), seen to FAIL, reverted, recorded in plan.md

### M7e — The toolchain survives interception (Status: PENDING)

**Scenario**: Journey 6.1

Shaped by `M1c`, and rewritten twice after the first two shapes were found to prove nothing. Interception is **per-destination and off by default** ([D12](plan.md#d12)): a plain-string destination is tunnelled untouched, and only a destination asked for in the form that inspects it causes the five trust-bundle variables to be exported. So an ordinary exchange succeeding is not evidence — it succeeds identically with interception off, because the system trust store is in the floor. Only the *difference* between trusting and not trusting is evidence.

**RED**: `check_j6_1` in three arms, per [plan.md § check_j6_1](plan.md#check_j6_1-in-three-arms).

- [ ] Arm 1, the mechanism engaged: `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE` and `GIT_SSL_CAINFO` are set in the child, and the file they name exists and parses as a certificate (FR-17)
- [ ] Arm 2, the exchange did its work: the output is matched as a **shape** rather than pinned to a value
- [ ] Arm 3, the negative control, in the same session: repeat with the trust bundle pointed at `/dev/null` and require failure with a certificate error
- [ ] Arm 3 is **permanent** and lives inside the check, not planted and reverted, because the property under test *is* a difference — removing it would be a regression rather than a plant, which is why it is deliberately absent from the planted-violations table
- [ ] Violation planted (ask for the destination as a plain-string destination instead), seen to FAIL **on arm 1**, reverted, recorded in plan.md

The exchange is credential-free and no requirement asks otherwise: `M1c` established that every store a credential could come from sits in a deny group the mechanism marks `required`, and authenticating the version-control toolchain is out of scope. FR-17 is about trust in the inspecting authority, and that is all this checks.

______________________________________________________________________

## M8 — The remaining agents

`claude-code` is already confined, from `M4b`. What is left is its own awkward corners, then the two agents that depend on it. The order is `claude-code` → `opencode` → `pi`, and it is the order [D14](plan.md#d14) forces rather than a preference.

### M8a — Extract `mkConfinedAgent` (Status: PENDING)

A refactor, and therefore its own task per P6. No behaviour changes.

**Scenario**: none — refactor.

- [ ] `nix eval --json .#confinement.claude-code | jq -S .` captured before
- [ ] The `claude-code`-specific wrapper generalised to `mkConfinedAgent name`
- [ ] The same eval captured after; **the diff is empty**, which is the definition of preserved behaviour
- [ ] `bash scripts/validate.sh` passes unchanged

### M8b — `claude-code`'s subagent and lock fallbacks (Status: PENDING)

**Scenario**: Journey 2.1 extended — spec Risk 12: `CLAUDE_CONFIG_DIR` has documented fallbacks in subagent and lock paths, and `M1g` counted thirteen candidate variables rather than one.

- [ ] `check_j2_1` extended to exercise a **subagent** run, not only a plain session
- [ ] Every variable `M1g` found to govern something is set, and any it found to be documented but absent from the binary is **not** set — `M1d` found one of those on `pi`, and setting it would look like coverage while doing nothing
- [ ] Any surviving fallback path is either confined by other means or becomes a registry entry with both justification fields
- [ ] Seen to FAIL before the fix

### M8c — `opencode` (Status: PENDING)

**Scenario**: Journey 2.1 for `opencode`.

- [ ] Its own variables used, never a blanket `XDG_DATA_HOME` (P1)
- [ ] It takes its credential from the mediated route, and no grant on `claude-code`'s state is added to make it work ([D14](plan.md#d14))
- [ ] Seen to FAIL before the fix

`opencode`'s base URL is a config key rather than a variable — `provider.<id>.options.baseURL`, with config winning over the environment — so pointing it at the mediated route is a file this environment writes, not a variable it exports.

### M8d — `pi`, and pre-provisioned extensions (Status: PENDING)

**Scenario**: Journey 2.1 for `pi`, plus FR-22.

Shaped by `M1d`: relocation holds through the single variable `PI_CODING_AGENT_DIR`, so `pi` needs no registry entry. `PI_CODING_AGENT_SESSION_DIR` does not exist and is not set.

- [ ] Extensions provisioned through Nix before the session, never fetched from inside it (FR-22)
- [ ] `PI_OFFLINE` is set, because `pi` installs missing packages automatically on startup, and its own install path reached the registry even under that variable — which disables startup operations only
- [ ] It takes its credential from the mediated route, via `providers.<id>.baseUrl` in the file this environment writes ([D14](plan.md#d14))
- [ ] The path for a consumer who must install an extension — outside the confined entry point — is documented rather than left to be discovered
- [ ] Seen to FAIL before the fix

**Checkpoint**: FR-1 is satisfied; all three agents are confined and `check_sc1` still passes without being edited, which is the property SC-1 asserts.

______________________________________________________________________

## M9 — Consumability, idempotency and CI

### M9a — A stranger reaches a confined agent from the ref (Status: PENDING)

**Scenario**: Journey 1.1 at the end-to-end layer — the layer AGENTS.md names as the one that matters and the one easiest to fake.

**RED**: `check_j1_1` at e2e runs `nix develop <canonical ref>` with `HOME=$(mktemp -d)`, from the pushed ref and never from the working tree.

- [ ] Check written and seen to FAIL
- [ ] FR-19: the canonical reference is `github:GRBurst/agent-sandbox`, named identically in every document; the handbook's current owner and repository are both wrong and are corrected
- [ ] No step depends on the author's configuration (SC-5)
- [ ] The clean `$HOME` is created before the run and `$XDG_CONFIG_HOME` inside it exists before the mechanism is invoked, or the mechanism silently reads the real home instead ([M1e](research.md#m1e--machine-readable-resolved-policy))
- [ ] The binary cache is reachable by the stranger too: this repository's own `nixConfig` declares `https://cache.numtide.com` and its key, because an input's `nixConfig` is not inherited ([M4b](#m4b--a-confined-claude-starts-status-pending))
- [ ] Nothing is passed `--impure`, and the lock is the committed one (P8)
- [ ] Violation planted (consume from the working tree rather than the pushed ref), seen to FAIL, reverted, recorded in plan.md — `M4b` already planted the confinement arm, and this task adds the arm that is specifically about consuming from the ref

This check needs no positive control, and the reason is worth writing down rather than leaving as an omission: its observable is a *set* — the granted reach compared against the registry — and a set is already discriminating, because with confinement removed there is no manifest to read at all. [D9](plan.md#decisions) binds the checks whose observable is a *failure*.

### M9b — Entering and verifying twice change nothing (Status: PENDING)

**Scenario**: Rep1 and Rep2 — two scenarios, so if either needs more than a trivial edit, split this task.

- [ ] `check_rep1`: tracked files unchanged and granted reach byte-identical
- [ ] `check_rep2`: same result, no residue a third run would trip over — SC-7 stated as a property of the suite rather than of one run
- [ ] Both carry the control an equality assertion needs: the reach compared is **non-empty and contains the workdir**, and the second run is confirmed to have actually run rather than short-circuited — two empty outputs are byte-identical too
- [ ] Two violations planted, one per check — `validate.sh` writes a log into the checkout for `check_rep2`, the wrapper writes a timestamped file on entry for `check_rep1` — each seen to FAIL, reverted, recorded in plan.md

An assertion that two things are equal is the shape most easily satisfied by nothing happening at all, which is why the control here is about the *content* of what is compared rather than about a failure. This is the same reasoning [D9](plan.md#decisions) applies to the refusal checks, reaching a different arm of the same problem.

### M9c — The claims are checked on clean machines, per platform (Status: PENDING)

**Scenario**: Journey 7.1

**RED**: `check_j7_1` at e2e asserts the suite ran unattended and reported success, then plants a registry entry and asserts the expected set changed with the check unedited.

- [ ] Check written and seen to FAIL
- [ ] `.github/workflows/verify.yml` runs `scripts/validate.sh` on `ubuntu-latest` and `macos-latest`, unattended, on a machine with no prior agent state (FR-13)
- [ ] Exit status alone separates a passing commit from a failing one; no human reads the output (SC-4)
- [ ] FR-20 and SC-8 asserted together: the same command asserts the same properties on both platforms, and the resolved reach is compared **across** the two jobs and must be equal
- [ ] Planting a registry entry changes the expected set without the check being edited — the third `Then` of Journey 7
- [ ] The substituter and its key are passed to the runner explicitly, since a CI user is not a trusted user and an input's `nixConfig` reaches neither; without them a runner builds every agent from source
- [ ] Violation planted (the workflow runs only the cheapest layer), seen to FAIL, reverted, recorded in plan.md
- [ ] `AGENTS.md`'s "no CD pipeline" sentence amended to permit non-deploying CI, retaining the prohibition on deployment

The second arm is what makes this checkable at all: exit 0 alone is also what a suite that ran nothing produces, which is why `validate.sh` treats "no checks ran" as a failure ([M1a](#m1a--the-scenario--check-bijection-status-done)). The cross-platform comparison is the one assertion in the suite that no single machine can make, so it lives here rather than in a check.

**Checkpoint**: `check_sc3` passes for the first time — every scenario has its check, and the bijection is closed. The set it has been naming since [M1a](#m1a--the-scenario--check-bijection-status-done) — twenty scenarios — is empty for the first time.

______________________________________________________________________

## M10 — Documentation

### M10a — Close out (Status: PENDING)

- [ ] `docs/HANDBOOK.md` updated: how to use what landed, the accepted leak **`$XDG_STATE_HOME/nono`** with its justification, and the coverage gap from [plan.md](plan.md#coverage-gap)
- [ ] Known drift entries retired and deleted: the Kafka leftovers, the six leftover variables, `system = "x86_64-linux"` hardcoding, the four devcontainer bind mounts, orphaned `ai.nix`, the stray `^`, missing `scripts/validate.sh`, missing `README.md`, absent `shellcheck`/`shfmt`, absent `statix`/`deadnix`, no `justfile`, and the wrong canonical ref which FR-19 corrects
- [ ] Anything from that list still true is *moved* rather than deleted, so a gap stays a known gap
- [ ] Root `README.md` written: component table taken from the code, one `flowchart LR` for structure, one `sequenceDiagram` per phase including **a refused case of its own** (AGENTS.md §6), checked by eye in both themes
- [ ] The migration path for a consumer with a host-global setup is documented (FR-21) — including that the prior-art arrangement granted the authenticating agent's state read-write and that [D14](plan.md#decisions) replaces it, so a migrating consumer knows what they are giving up and what they get back
- [ ] FR-11: the supported platforms are named, each with the enforcement tier its operating system provides, and a weaker guarantee says so with the difference named
- [ ] FR-14 and FR-12: every claim the automated run cannot reach is listed with its procedure, and the handbook describes what a human runs without restating the assertions anywhere
- [ ] The way to run an agent unconfined — by not invoking the confined entry point — is described rather than concealed (FR-10)
- [ ] Every open question in `spec.md` resolved in place with a one-line outcome, including the two assumptions the plan was still to confirm
- [ ] The handbook names what the automated run cannot reach: an unattended token flow, the second platform, and a consumer's own trust settings for the substituter
- [ ] `docs/CONSTITUTION.md` P1's accepted-leak list amended to its second entry
- [ ] `research.md` consolidated to what is still true, per AGENTS.md §1 — the decisions and the criteria kept, the record of how each was checked dropped; the `codex` findings kept, since they are the follow-up feature's head start
- [ ] Touched files formatted and linted per [AGENTS.md](../../AGENTS.md#4-verify-every-change)
- [ ] `scripts/validate.sh` passes

The accepted leak is named precisely here because it was named wrongly for most of this feature's life: the mechanism anchors its supervisory state at `$XDG_STATE_HOME/nono`, and one of the two research rounds asserted `$HOME/.nono`. It is an accepted leak rather than a fixable one because the mechanism refuses to grant any path overlapping its own state root, so relocating it into the project would make the project ungrantable ([D13](plan.md#decisions)).
