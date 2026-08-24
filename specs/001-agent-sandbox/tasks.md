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
- All four agents were inspected rather than reasoned about: `claude-code` `ANTHROPIC_BASE_URL`, `opencode` `provider.<id>.options.baseURL`, `pi` `providers.<id>.baseUrl`, `codex` `model_providers.<id>.base_url`. `codex` was built from the pinned nixpkgs to check it; it substituted without compiling. `codex` was subsequently dropped from this feature, and its findings stay in `research.md` as the follow-up's head start rather than being deleted — the work is done and re-doing it would cost a build. Two of those four readings were inspection rather than measurement and did not survive it: `M8c` found `opencode` reading `ANTHROPIC_BASE_URL` from the environment as well as from its config key, and `M8e` found `pi` **ignoring** the environment variable entirely because it passes its own registry's `baseUrl`.
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
- **FR-22 is not satisfied by relocation.** Relocation puts the npm install inside the project — `$PI_CODING_AGENT_DIR/npm/node_modules/…`, observed — which satisfies FR-4. But `pi` still "installs any missing packages automatically on startup", `pi install` runs a real `npm install` that reached the registry here even under `PI_OFFLINE=1`, and the `package.json` it generates loosens a pinned spec to a caret range. So the environment ships no `pi` packages and sets `PI_OFFLINE`, added to the plan's sketch. `M8d` corrects the reading of that variable: it is the *startup* install it stops, which this spike could not observe because it declared no package, and the explicit-command half is stopped by the substrate carrying no `npm` rather than by the variable.
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

### M1g — Spike: does `claude-code`'s configuration root relocate? (Status: DONE)

The last open fork, and the one the rest of the feature now rests on. `M1d` asked this of `pi` because a research round had contradicted itself; nobody asked it of `claude-code`, when it was one agent among four. It is now the reference case (FR-1) **and** the credential source the other two draw from ([D14](plan.md#d14)), so FR-4 and FR-7 both stand on the answer.

A first look at the payload counts thirteen candidate variables rather than one — `CLAUDE_CONFIG_DIR` most often, `CLAUDE_SECURESTORAGE_CONFIG_DIR` where the credential plausibly comes to rest, and eleven more for jobs, plugins, skills, memory, logs and temporary files. A count establishes that a name is read somewhere. It does not establish that it governs what it appears to: `M1d` found a documented variable that the binary does not contain at all, so the evidentiary standard is observation, not occurrence.

**Scenario**: none — investigation blocking `M4b` and `M7a`.

**RED**: not applicable; a spike has no check. It is a task because it is a commit and it blocks two milestones.

- [x] Set the candidate variables into the project, run `claude`, and record what is written under each — and whether anything at all is written under `$HOME`
- [x] Run the **control**: the same invocation with nothing set, so the default is fixed by observation and the override is shown to be what moved it, as `M1d` did for `pi`
- [x] Establish where the credential comes to rest, since FR-7 reads it from there and `M7a` asserts its form
- [x] Record whether any surviving path needs a registry entry (FR-3), with both justification fields drafted if so
- [x] `research.md` states the finding per variable with its evidence; `plan.md`'s `lib/agents.nix` sketch and `spec.md`'s relocation assumption are corrected in place to match

`M1c` recorded that a confined session cannot be started from an agent session at all. That is too strong, and `research.md` corrects it: a real `nono run` is reachable from here under four conditions, so all five criteria were observed from an agent session, including the credential one — `claude auth status` answers "where does it rest" behaviourally, by losing the credential when the root moves, without anyone logging in again.

**Implementation notes.** A five-phase harness under `.tmp/m1g/` (gitignored, not a check): unconfined control, unconfined override, confined control, confined override, credential. Each candidate went to its own leaf directory named after the variable, so a write attributes to the one variable that could have moved it.

Three of thirteen govern — `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_TMPDIR`, `CLAUDE_CODE_REMOTE_MEMORY_DIR` — and together they cover the whole default layout, with nothing left under `$HOME`. **No registry entry is forced**, so the fallback in `spec.md` went unused and the registry stays empty as [D2](plan.md#d2) expected. All four `XDG_*` roots got nothing, falsifying the inference from `XDG_CONFIG_HOME`'s strings count; occurrence has now failed to predict behaviour three times in this feature.

The credential rests in `.claude.json` at the root of `CLAUDE_CONFIG_DIR` and **relocates with it**: `claude auth status` goes from `loggedIn: true` to `loggedIn: false` when only that variable and `CLAUDE_SECURESTORAGE_CONFIG_DIR` change. So FR-7 is not satisfiable by relocation, which confirms rather than redirects [D1](plan.md#d1) and [D14](plan.md#d14). `CLAUDE_SECURESTORAGE_CONFIG_DIR` governs nothing observable. The key name inside that file is left to `M7a`, which is what needs it; reading `~/.claude.json` is denied to an agent session here.

Two constraints on the description came out of failures rather than from the question asked, and both are recorded in `plan.md`: `--allow-cwd` grants the working directory **read-only** by default, and `TMPDIR` must resolve inside the working directory or claude refuses to start. `DISABLE_AUTOUPDATER` is inherited on the developing host, so the description must set it or P8 holds only here.

**Checkpoint**: every architectural fork in `plan.md` is closed. Implementation may begin.

______________________________________________________________________

## M2 — The previous project leaves

Independent of everything else, and it clears the ground. Doing it first means no later check passes because a Kafka leftover happened to satisfy it.

### M2a — No artefact of the prior project remains (Status: DONE)

**Scenario**: R7

**RED**: write `check_r7`, which evaluates the devShell and asserts no artefact of the prior project appears by name in packages, variables or `.gitignore`, **and** that a package the environment does need is found — the positive control [D9](plan.md#d9) requires, without which the check passes against an empty devShell.

- [x] Check written and seen to FAIL with: `kafka artefact present in devShell: kcat`
- [x] FR-18 satisfied: remove the packages `kcat kafkactl postgresql lazysql openjdk25 maven nodejs zellij` and the six variables `KCAT_CONFIG KAFKA_CTL_CONFIG PSQLRC PSQL_HISTORY MAVEN_ARGS MAVEN_OPTS` from `flake.nix`; correct `description` from `"Hivemind Kafka Playground"`; remove `materialize/.config/`, `current-context.yml`, `.env` from `.gitignore`
- [x] `bash scripts/validate.sh --layer unit` reports `check_r7` passing, and the set `check_sc3` names shrinks by exactly `r7` with nothing else moved
- [x] Violation planted (re-add `kcat`), seen to FAIL, reverted, recorded in plan.md
- [x] `nixfmt` and `nix flake check` clean

**Implementation notes**

- **The criterion "`validate.sh --layer unit` passes" was wrong as written, and has been corrected in place.** `check_sc3` is deliberately red until the last scenario lands, which [M1a](#m1a--the-scenario--check-bijection-status-done) recorded as the feature's progress bar. The criterion now states the property M1a actually defined: `check_r7` passes, and the set `check_sc3` names shrinks by exactly `r7`. Observed 20 → 19, `comm` in both directions giving `r7` and nothing else. The same stale wording survives in `M2c` and `M3a`; it will be corrected as each is reached.
- **The check matches package names as nix reports them, not as `flake.nix` spells them.** `openjdk25` evaluates to pname `openjdk` and `bash` to `bash-interactive`, so the forbidden list holds the reported name. A version bump cannot then reintroduce one under a new attribute, which an exact match on the attribute spelling would have missed.
- **One evaluation supplies both halves.** `devshell_facts` evaluates `devShells.<system>.default` once, with `--apply`, into `{ packages, hook }`; the system comes from `builtins.currentSystem` rather than being hardcoded, so `M9`'s second platform needs no edit here. `mkShell` folds its `packages` argument into `nativeBuildInputs`, which is what gets read. 0.7s, no build.
- **The description is asserted by property, not by value**: it must not match `kafka|hivemind|playground`, case-insensitively. Pinning the new string would make the check a restatement of `flake.nix`. It now reads `"Per-project confined agent sessions"`.
- **`.gitignore` rules are matched as whole lines.** `.env` is a substring of the `.envrc.local` rule that stays, so a substring match would have reported a false positive forever.
- **Two violations were planted, not one.** Re-adding `kcat` was the one the task named. The second removes `jq`, the positive control [D9](plan.md#d9) requires, and was seen to FAIL with `positive control absent: the devShell declares no jq, so the assertions above hold vacuously` — which is the only evidence that the control is load-bearing rather than decorative. Both are recorded in `plan.md`.
- **`npm_config_cache` and `NPM_CONFIG_USERCONFIG` were kept** although `nodejs` went. Two of the three agents are node programs and will run `npm` inside a session, so those two redirections are this feature's, not the prior project's. The task's list of six variables was followed exactly.

The leftovers are not only a tidiness matter. A live session was observed inheriting `JAVA_HOME` and an `XDG_DATA_DIRS` carrying openjdk, postgresql, zellij and nodejs store paths, so they are on the boundary this feature is drawing, not beside it. Formatting is `nixfmt`, per [AGENTS.md](../../AGENTS.md#4-verify-every-change); an `alejandra`-formatted `flake.nix` was discarded once already.

### M2b — The two bootstrap variables are mirrored (Status: DONE)

P1's bootstrap exception requires a check that parses both files. `flake.nix` claims one exists; it does not.

**Scenario**: P1 mirror

**RED**: write `check_bootstrap_mirror`. It parses `TMPDIR` and `XDG_CACHE_HOME` out of `.envrc` and out of `flake.nix` and compares them byte-for-byte. It must be bash, not zsh, because of `${!v}`.

- [x] Check written and seen to FAIL with: `bootstrap variables differ between .envrc and flake.nix` after a deliberate edit
- [x] The stale `flake.nix` comment referencing `.claude/settings.json` and a non-existent `scripts/validate.sh` is corrected to name the real check
- [x] Violation planted (change `TMPDIR` in `.envrc` only), seen to FAIL, reverted, recorded in plan.md

**Implementation notes.**

`check_bootstrap_mirror` lives in `scripts/checks/unit.sh` alongside two helpers.

- **The variable list is derived, not written down.** `envrc_bootstrap_exports` takes every `export` line above the `use flake` directive, which is what "bootstrap" means — the variables nix needs before it can read the flake. A third one added later is covered without touching the check.
- **It compares resolved values, not source text.** `resolve_bootstrap` runs each fragment in its own `bash -c`, `cd`-ed into one shared temporary directory so the embedded `$PWD` resolves identically, then reports each name through `${!v-<unset>}`. `plan.md` said byte-identical; that is the wrong criterion, because nix's indented strings escape where a shell does not, so equal text is neither necessary nor sufficient. Corrected there in place. A variable missing from the hook entirely surfaces as `<unset>` against a value.
- **The flake side is read through `nix eval`,** reusing `check_r7`'s `devshell_facts`, so what is compared is the hook the shell would actually run.
- **The anti-vacuity guard bit unplanted, on the first run.** It reported `no exports found before 'use flake' in .envrc; the mirror comparison would be vacuous` — because line 6 of `.envrc` mentions `use flake` inside a comment and the region parser stopped there. Fixed by matching the directive (`^[[:space:]]*use[[:space:]]+flake`) rather than the words. The comment was deliberately left saying `use flake`, so the file keeps the trap the parser has to survive.
- **Both stale comments were corrected,** not just the one the criterion names. `.envrc` carried the same fiction — "scripts/validate.sh compares both files against .claude/settings.json" — and now names `check_bootstrap_mirror`. Neither `.claude/settings.json` nor that comparison has ever existed.
- **`check_sc3` is unmoved at 19,** as it should be: "P1 mirror" is a plan-level property, not one of the spec's numbered scenarios, so this check is not a scenario check and the bijection does not see it.

### M2c — The container and the orphans are deleted (Status: DONE)

**Scenario**: none — deletion. Verified by the absence of any check that referenced them and by `nix flake check` still passing.

- [x] Delete `devenv.nix`, `devenv.yaml`, `ai.nix`, `draft1.md`, `draft2.md`
- [x] Delete the `.devenv*`, `devenv.local.nix` and `devenv.local.yaml` entries from `.gitignore`, which have nothing left to ignore
- [x] Add `/.agents/` to `.gitignore` ([D8](plan.md#d8))
- [x] Every instruction a reader could run that names a deleted file is corrected: `AGENTS.md`'s source-of-truth list, and `docs/HANDBOOK.md`'s devenv commands and format command
- [x] `nix flake check` passes; `bash scripts/validate.sh --layer unit` reports `check_r7` and `check_bootstrap_mirror` passing, and the set `check_sc3` names is unchanged

**Implementation notes.**

- **The deletion falsified two documents, and one of them was a runnable command.** `grep` for each filename before deleting found `AGENTS.md`'s source-of-truth list naming `devenv.nix` as code, and `docs/HANDBOOK.md`'s `nixfmt flake.nix ai.nix devenv.nix`, which a human following the handbook would now watch fail. Both corrected, along with the `devenv shell` / `devenv container build` block, which described a capability this task removes; it now says there is no devenv path and why.
- **Four Known drift entries were retired early, because they named files that no longer exist.** The devcontainer's four bind mounts, `ai.nix` being an unimported orphan, `devenv.nix`'s stray `^`, and `devenv.nix` claiming Apple Silicon against `flake.nix`'s hardcoded system. A drift entry about a deleted file is not drift, it is fiction, so `AGENTS.md` §1 requires fixing it where the wrong statement is rather than waiting. `M10` still owns the rest of that list.
- **A criterion was corrected in place, the same stale wording `M2a` hit.** "`bash scripts/validate.sh --layer unit` passes" cannot hold while `check_sc3` is the progress bar. It now names the two checks that must pass and requires `check_sc3`'s set to be *unchanged*, which is the right property for a task that adds no scenario. Observed: 19 before and 19 after, the same list. `M3a` carries the last copy of the stale wording.
- **No check was written, and none was needed.** Nothing in the suite referenced the deleted files, so there was no RED to reach; the deletion's own criterion is `nix flake check` still passing, observed `all checks passed!` exit 0. This is the one task in `M2` with no planted violation, because it adds no guard.
- **`/.agents/` was verified to bite, not just to be present**: `git check-ignore -v .agents/probe` reported `.gitignore:17:/.agents/`.
- **Two `devenv` mentions survive on purpose.** `AGENTS.md`'s preamble and `docs/HANDBOOK.md`'s opening both say a project can point at this repository "from a flake, a devenv configuration or a devcontainer". Those describe the *consumable surface offered to a downstream project*, not this repository's own deleted devenv files. Whether that offer is still honest is `M9`'s question, not this task's.

`ai.nix` is the prior art and it earned its keep during `M1`: its comment "nono has no general `--env` flag" turned out true of the command line and false of the confinement description, which is how [D4](plan.md#d4) and [D6](plan.md#d6) came to be confirmed rather than guessed, and its `~/.claude` read-write grants are the arrangement [D14](plan.md#d14) rejects. All of that is now in `research.md` with its evidence, so deleting the file here — before `M8` reaches the agents it configured — loses nothing that `M8` will need.

______________________________________________________________________

## M3 — The registry and the confinement description

### M3a — The leak registry is typed and well-formed (Status: DONE)

**Scenario**: SC-2

**RED**: write `check_registry` asserting the three invariants in [plan.md § Properties](plan.md#properties). It fails because `lib/leak-registry.nix` does not exist.

- [x] Check written and seen to FAIL with: `lib/leak-registry.nix: no such file`
- [x] `lib/leak-registry.nix` written with the `submodule` entry type and an **empty** entry list, carrying the comment explaining why the mechanism's own state root is not an entry ([D2](plan.md#d2)). That root is `$XDG_STATE_HOME/nono`, not `$HOME/.nono` — one research round claimed the latter and `M1c` observed the former
- [x] The spec's assumption about the mechanism's state root reads as an accepted leak rather than a registry entry, corrected in place if it does not
- [x] `nix eval --json .#leakRegistry` succeeds; `check_registry` passes, and the set `check_sc3` names is unchanged, this task adding no scenario check
- [x] Both registry violations planted, seen to FAIL, reverted, recorded in plan.md
- [x] `shellcheck` and `shfmt` are in the devShell and resolve from the store rather than a user profile, and the Known drift entry saying they are absent is retired

An empty list is the expected outcome, not a placeholder: `M1b` resolved [D1](plan.md#d1) to the branch where no agent needs a credential file granted, and [D14](plan.md#d14) closed the one route that would have added one. The check must therefore hold over an empty list without passing vacuously — `check_registry` asserts the entry *type* rejects a malformed entry, which is a property of the type and does not need an instance.

**Implementation notes.**

- The fourth criterion originally read "`bash scripts/validate.sh --layer unit` passes", which cannot hold while `check_sc3` is the feature's progress bar. Corrected in place to the property `M1a`, `M2a` and `M2c` already use. This was the last copy of that wording in `tasks.md`.
- **The type settles shape, the check settles content.** `entryType` is a `types.submodule` with five named options, so `mode` outside `[read readwrite]` and any sixth key fail evaluation. `why = ""` deliberately *does* type-check, because an empty justification is a judgement about the text rather than about its type, and `check_registry` is what rejects it. That split is what makes the plan's two planted violations land on the check rather than on nix.
- `entries = map checkEntry [ ]` rather than a bare list, so an entry cannot join the list unchecked without editing that line. `checkEntry` runs the candidate through `lib.evalModules` against `entryType`, and is exported as the flake output `leakRegistryCheckEntry` so the check can probe the type from outside.
- **The empty list is not a vacuity problem, it is the answer.** Three of the check's assertions are properties of the type and need no instance: a well-formed entry must be accepted (the positive control), a bad `mode` must be rejected, and an extra key must be rejected. All three were planted against and all three bit.
- **An ordering guard emerged that the plan did not anticipate.** Invariant 3 — every agent an entry names exists in the agent set — cannot be checked before `lib/agents.nix` exists, which is `M3b`. Rather than skip it silently or leave an untestable branch, the check looks up `.#agents` only when the registry is non-empty and fails with `the registry has entries but the agent set does not evaluate` if it cannot. Both entry plantings triggered it as a second finding, which is correct: today an entry genuinely cannot be added before `M3b` lands. Recorded as a sixth planted-violation row.
- One real bug, caught before GREEN: capturing `nix eval` with `2>&1` fed `warning: Git tree … is dirty` into `jq`, giving `jq: parse error: Invalid numeric literal`. Fixed by not merging stderr where the output is parsed, and merging it only where a nix failure is the expected result. `run_check` prints captured output solely on FAIL, so a check's diagnostics can flow freely without being noise on a pass.
- `lib/leak-registry.nix` had to be `git add`ed before `nix eval` could see it — a flake reads the git tree, not the working directory, so an untracked file is invisible.
- **`shellcheck` and `shfmt` folded in on request.** Both are named in AGENTS.md's lint table and had been resolving from a user profile, so under §3 the lint step was not reproducible for a stranger. Now in the devShell, verified resolving from `/nix/store`.
- **Six further Known drift entries retired**, having been falsified by `M2a`, `M2b` and this task rather than by close-out: the whole "environment still belongs to the previous project" block, the claim that `scripts/validate.sh` does not exist, the byte-identical mirror criterion, the hand-run bootstrap comparison now automated, and the absent linters. The handbook's verification section now names `scripts/validate.sh` and explains why it exits non-zero by design. `plan.md`'s close-out list was corrected to say which entries remain.

### M3b — A confinement description is generated and validates (Status: DONE)

**Scenario**: none directly — this is the artefact SC-1 asserts against. Verified by nono's own schema.

**RED**: write the component check that runs `nono profile validate` on the generated profile. It fails because `lib/confinement.nix` does not exist.

- [x] Check written and seen to FAIL
- [x] `lib/agents.nix` and `lib/confinement.nix` written per [plan.md § Implementation shapes](plan.md#implementation-shapes), for `claude-code` only
- [x] The description names **no parent** and takes what it needs by group inclusion ([D10](plan.md#d10)); `meta.name` is set, because nono refuses the profile without it
- [x] `groups.include` carries `nix_runtime`, and does **not** carry `git_config` ([D11](plan.md#d11))
- [x] `environment.set_vars` carries the relocation variables `M1g` established, plus `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`
- [x] `nono profile validate` passes on the generated profile
- [x] Each omitted path carries a comment saying **why it is not granted** (P5)

`nix_runtime` is not optional cosmetics: `/nix/store` is absent from the floor, and a session without it exits 127 before the agent runs. It is included as a group rather than granted by path, because the group grants read and a path grant would give read **and** write to the store.

**Implementation.** RED was `FAIL check_confinement_validates` / `lib/confinement.nix: no such file`. GREEN came on the first build after wiring the flake. The resolved manifest is 42 grants and 51 denies, against `M1e`'s bare-description baseline of 33 and 48; the eleven added `/nix` grants are all read.

`lib/agents.nix` holds only `groups` and `stateVars`, and only `claude-code`. A field nothing reads is how a table starts lying, so `package` and `binary` wait for `M4`, `credential` for `M7`, and the other two agents for `M8`. The plan's sketch was annotated to say so rather than left reading as though this task fell short of it. Both this table and the registry run every entry through `lib.evalModules`, so a field is type-enforced from the moment it exists.

**The description cannot suppress the update check, and the plan was wrong about how that fails.** The sketch had `NONO_NO_UPDATE_CHECK = "1"` in `set_vars`. It is not ignored: `validate` rejects the whole description with `Invalid set_vars key 'NONO_NO_UPDATE_CHECK': the NONO_* prefix is reserved`, exit 1, and `PATH` is refused the same way. Corrected in `plan.md` in place, including the P8 row of the Constitution Check; the entry point exports it before `exec`, which is where it belongs, since the call it suppresses is the supervisor's rather than the boundary's.

The `set_vars` assertion is derived, not restated: the check applies the agent table's own `stateVars` function and requires every key and value to appear in the built description. Planting a `removeAttrs` in the description alone — leaving the table untouched — is what proves it, and that is the drift a restated list could never catch. `M8b` adding a variable needs no edit to the check.

`validate` exiting 0 is a weak observable on its own, so the check carries a negative control in the same run: a copy of the description with one unresolvable group reference must be rejected. Neutering that mutation is one of the eight recorded plantings.

**A lesson about plantings, now written into `plan.md`'s preamble.** The unknown-key planting appeared not to bite. The cause was a `sed` pattern that did not match the file, so nothing was planted at all — and a planting that never applied is indistinguishable from a check that never fires. Re-done against the real text, the check failed with nono's full enumeration of its thirty-five legal top-level keys, matching `M1e`'s record. The artefact is now inspected for the violation before its absence is believed.

`shellcheck`'s `SC2016` is suppressed once, with its reason: `$WORKDIR` in the `--apply` expression must reach nono unexpanded.

### M3c — Granted reach is the project directory (Status: IMPLEMENTED)

**Scenario**: SC-1

**RED**: write `check_sc1`, deriving the expected set from `lib/leak-registry.nix` and never restating it. It fails until the profile is correct.

- [x] Check written and seen to FAIL with: `granted path outside project and not in registry: …`
- [x] The resolved reach is read from `nono profile show <name> --format manifest`, as `M1e` established, and the paths from `.filesystem.grants[].path`
- [x] The set asserted is FR-2's: the project directory plus leak-registry entries, and nothing else — an equality, not a containment
- [x] The grants the floor supplies unconditionally are excluded by deriving them from a description that declares nothing, not by listing them ([D4](plan.md#d4))
- [x] `bash scripts/validate.sh --layer component` passes
- [x] Violation planted (`$HOME/.ssh` added to the description's grants), seen to FAIL, reverted, recorded in plan.md

The manifest is the sandbox-capability view only. Credential wiring does not appear in it, so nothing about `network.credentials` or `credential_routes` can be asserted here; `M7` asserts those against the description's own source.

**What this task actually cost, and why the plan changed.** The equality could not be stated at all while the description included `nix_runtime`: the group grants seven paths outside the project, two of them under `$HOME`. Measuring it produced [D15](plan.md#d15) — a path grant on the store confers read alone, so the reason a group was preferred was false, the group is dropped, and the store becomes the leak registry's one entry with `builtins.storeDir` as its path. The description needed no new mechanism, because the registry already feeds `filesystem.read`: the grant *is* the entry, which is what makes the equality hold by construction.

Two further findings, both recorded in [D15](plan.md#d15) and both aimed at `M3d` and `M4b`: Landlock is allow-only, so no deny can carve a hole in a granted parent and nono refuses to start rather than pretend; and `nono why` will report a deny the kernel cannot enforce, so it is not a proxy for enforcement.

The floor is derived by stripping the description under test down to `{meta}` with `jq` and resolving that, so a floor which grows in a later nono release moves the baseline instead of breaking the check. Three properties of the resolver forced the shape of `manifest_grants`: `profile show` has no `--workdir`, so `$WORKDIR` is its cwd and the resolver must run from the repository root; the `/proc/<pid>` grants carry the resolving process's own pid and are normalised away; and nono grants **stdout's file** `readwrite`, so a check that redirects the resolver into a file finds its own artefact in the comparison.

`check_confinement_validates` lost its `nix_runtime` assertion and gained one that the store is granted read, with the prefix from `nix eval builtins.storeDir` rather than spelled out. It is independent of `check_sc1` by construction: emptying the registry takes the grant with it, so the two sides still agree and only the substrate assertion fires. That was planted and observed.

**The planting found a defect in the check itself.** With `$HOME/.ssh` granted, `jq` reported `Cannot index string with string ("path")` beside the expected failure: in `$p | startswith(.path + "/")` the pipe rebinds `.` to `$p`, so `.path` indexed a string. The exact-match disjunct short-circuited for `/nix/store` and hid it. The entry is now bound with `. as $e` before the pipe. Known gap: with one registered path granted exactly, the prefix branch is not exercised by any current data, and a defect there would make the check too strict rather than too lax.

### M3d — the merge is what the plan claims (Status: DONE)

[D4](plan.md#d4) is a boundary contract, and P7 requires a boundary's merge behaviour be written down — and here, asserted. The schema does not settle it: it describes what fields exist, not how they combine.

**Scenario**: D4

**RED**: write `check_component_merge` asserting the three claims [D4](plan.md#d4) actually rests on, against `nono profile show --format manifest`: that a group's `deny` outranks a grant the description makes for the same path, that the floor's grants and denies are present whether or not a parent is named, and that an included group's contribution is additive.

The third claim was written as "the environment filter applies `deny_vars` before `allow_vars`" and has been **corrected in place**, because that claim cannot be observed against a resolved description and the second criterion below forbids asserting it from the schema. `--format manifest` has no `environment` key, `--format profile` prints no environment section, and `nono run --dry-run` prints capabilities only. It is also not a contract this environment rests on: [D6](plan.md#d6) chose an allowlist and `lib/confinement.nix` sets no `deny_vars`, so there are no two lists to order. FR-5's real requirement is behavioural and already has a home — `check_r3`, at the integration layer, against a canary from inside a session. Additivity replaces it because it is the one D4 claim left unasserted and it *is* observable here.

- [x] Check written and seen to FAIL with a deliberately wrong claim
- [x] Nothing is asserted from the schema alone; every claim is observed against a resolved description
- [x] Every deny the merge produces is disjoint from the project directory, asserted as a property over `.filesystem.deny[].path` and derived from the resolved manifest rather than from a list of group names
- [x] The precedence claim is observed against the resolved manifest, and `nono why` is not read as enforcement anywhere in the check ([D15](plan.md#d15))
- [x] Violation planted (assert a description's grant beats a required group's `deny`), seen to FAIL, reverted, recorded in plan.md
- [x] Violation planted (a deny pointed at a path inside the project), seen to FAIL, reverted, recorded in plan.md

This task no longer asserts `extends` semantics. [D10](plan.md#d10) means no description this environment ships names a parent, so how `extends` combines two descriptions is not a contract anything here depends on. What is still a contract is the merge of the floor, the included groups and the description's own declarations — and the first of those three claims is the one the boundary rests on, because it is what makes a `required` deny group unable to be undone by a mistake elsewhere.

**This task derisks `M4b`, and that is why the disjointness criterion is here rather than there.** [D15](plan.md#d15) found that Landlock is allow-only: a deny cannot carve a hole in a granted parent, and nono checks for the overlap before `landlock_restrict_self` and refuses to start rather than pretend. Granting `$WORKDIR` recursively therefore makes every `required` deny group a *precondition on the project a consumer runs this in*, not merely on this repository. If any deny path resolves inside a checkout, no session starts there at all — an unconditional failure of Journey 1 for that consumer, and the kind of thing that would otherwise be discovered as a mysterious `Sandbox initialization failed` in `M4b`. The component layer can see it one task earlier, from the manifest alone, because `nono profile validate --strict` **accepts** an overlapping deny without complaint. So validation is not the observer; the set is.

The second planting is the honest control for that: a deny aimed inside the project must make the check fail with a message naming the path, at the component layer, without a kernel in the loop. `M4b` then confirms the consequence — a session that does start — rather than being the first place the condition is noticed.

**Implementation.** `check_component_merge` and one helper, `manifest_denies`, in `scripts/checks/component.sh`. The helper mirrors `manifest_grants` — same repo-root subshell, since `profile show` has no `--workdir` — and reads `.filesystem.deny[].path`. The check compares the description under test against three counterparts it derives from that same description: stripped to `{meta}` for the floor, with one probe path added to `filesystem.read` for precedence, and with one probe group added to `groups.include` for additivity. Nothing is compared against a parent, because [D10](plan.md#d10) means there is none.

**Precedence does not work the way the plan implied, and the correction is the finding.** The resolver does not drop the losing grant: a path a `required` group denies and the description also grants appears in `.filesystem.grants` **and** in `.filesystem.deny` of the same manifest. So precedence is observable as *deny-survival*, not as grant-absence, and a check written to watch the grant disappear would have concluded the opposite of the truth. The probe is not a path anyone wrote down — the required deny groups come from `nono profile groups --json` filtered on `required == true`, their paths from `nono profile groups <name>`, and the check takes the first that the merge actually denies. It came out `$HOME/.1password`, and a new nono release moving that set moves the probe with it. [D4](plan.md#d4) is corrected in place to state the observed form.

**The precedence arm carries its own positive control**, per [D9](plan.md#d9), because its observable is a survival rather than a change: the probe grant must be *seen* in the mutated manifest, else the arm passes while proving only that a grant nono ignored did not disturb a deny. It did not fire during the planting, which is what makes that planting evidence.

**Two arms would otherwise have held vacuously, and both now say so.** The floor comparison fails outright if the floor resolves to no grants or no denies. Additivity is worse: several non-required granting groups — `system_read_linux_core`, `user_tools`, `homebrew_linux` — are *already in the floor*, so including them adds nothing and a check that probed one would have asserted over an empty diff. The loop therefore walks the derived candidates until one genuinely adds a grant and fails if none does. `bun_runtime` is the first that does. `nix_runtime` adds six rather than [D15](plan.md#d15)'s seven, because `/nix/store` is already granted by the registry entry.

**A deny above the project is not a violation and is not flagged.** Landlock being allow-only cuts both ways: an ancestor deny is expressed by not granting, and the project's own grant overrides it. Only a deny *inside* the granted subtree is unenforceable, which is exactly the plan's `deny_group_paths ∩ subtree($WORKDIR) = ∅` and no wider.

`nono why` appears nowhere in the check, as the fourth criterion requires. The counts, for the record: the floor resolves to 35 grants and 51 denies, the description to 37 and 51.

**`check_sc3` is unmoved** at 21, the same list before and after — correct for a task whose scenario is a plan-level decision rather than one of the spec's numbered scenarios. `unit.sh`'s parser matches `check_(j…|r…|rep…)` only, so this check is invisible to the bijection by construction rather than by luck.

______________________________________________________________________

## M4 — Journey 1: one confined agent

The MVP slice. After this group `claude-code` is confined and could be handed to a consumer even if nothing else lands. It is the reference case not because it is the easiest — `M1g` exists precisely because it is not — but because `opencode` and `pi` obtain their credential from the session it authenticates, so nothing about FR-6 or FR-7 can be shown until it works.

### M4a — The pre-flight refuses an unenforceable host (Status: IMPLEMENTED)

**Scenario**: R6

**RED**: write `check_r6`, which runs the canary unconfined and asserts exit `77` and a message naming the missing primitive.

- [x] Check written and seen to FAIL with: no `77` and no message
- [x] `preflight_or_die` written with **four** assertions, so neither "nono failed to start" nor "the canary was already unwritable" can pass as "the child was denied" (P9)
- [x] The canary sits at a path the pre-flight has **observed to be writable unconfined**, so the denial it later sees is attributable to the confinement and not to whatever else may be in the way ([D5](plan.md#d5))
- [x] The positive control is that the same pre-flight exits 0 on the machine running the suite, so a pre-flight that refuses every host cannot pass this check ([D9](plan.md#d9))
- [x] `bash scripts/validate.sh --layer integration` passes
- [x] Violation planted, seen to FAIL, reverted, recorded in plan.md
- [x] `shellcheck` clean; the task is under ~50 lines of shell

The criterion naming **three** assertions was corrected in place to four, and the canary criterion added, because the sketch in [plan.md](plan.md#d5) could conclude "confinement is enforced" from a write that never had a chance of succeeding. Its canary was `$HOME/.agent-sandbox-preflight.$$`, and on any host where `$HOME` is not writable by the user — this repository's own development sandbox among them — the confined write fails for a reason that has nothing to do with nono, assertion 3 finds no file, and the guard passes having proven nothing. That is the silent false pass **P9** forbids, in shipped code rather than in a check, and it is [D9](plan.md#d9)'s positive-control rule applied one level down: a guard whose observable is a *failure* has to show the same operation succeeding first.

**Implementation.** `lib/preflight.sh` holds `die` and `preflight_or_die`, 27 lines of code. `scripts/checks/integration.sh` is new, and this is the first task whose observable is a real kernel-enforced session rather than a resolved policy.

RED was `FAIL check_r6` / `lib/preflight.sh: no such file`, which is "no `77` and no message" as the criterion words it. GREEN came on the first run after writing the file.

- **The pre-flight has no profile of its own, and the plan's `preflightProfile` parameter is gone.** It asserts a property of the *host*, so the description it tests under may as well be the one the agent is about to run under. A second description whose only consumer is the pre-flight is another artefact to keep true and an option nothing else exercises. `plan.md`'s `mkConfinedAgent` sketch was corrected in place, and the pre-flight became a file rather than the sketch's inlined `preflightSh` string, because `check_r6` sources it and `shellcheck` reads it — neither of which can be done to a string interpolated into a derivation.
- **The plant is a passthrough `nono`, not a no-op.** A no-op never runs the child at all, so assertion 1 would fire and the check would see `77` for the wrong reason. The stub consumes `--profile` and `--workdir`, breaks on `--` and `exec`s the rest, which is the honest shape of "nono is present and enforcing nothing".
- **Attribution was verified rather than assumed.** All four assertions exit `77`, so the exit status alone cannot say which one fired, and a stub that happened to break assertion 1 would pass the check while proving nothing. Both arms were run by hand: the plant arm printed `confinement is not enforced: a confined process wrote outside the project.` — assertion 3, the one the plant exists to trip — and the control arm printed nothing at exit 0.
- **A third arm was added that the task did not ask for.** Arms one and two both leave assertion 2 untested, because `$XDG_RUNTIME_DIR` is writable on this machine, so deleting the positive control would have gone unnoticed by the check that exists to protect it. The third arm points both `$XDG_RUNTIME_DIR` and `$HOME` at a `chmod 500` directory and requires `77` with `cannot verify confinement`. Deleting assertion 2 is the second recorded planting, and it is the defect that prompted this task's correction, observed in the artefact rather than argued from the sketch.
- **`session_env` establishes `research.md`'s four conditions once, before the layer's first session**, and exports them as an array rather than a string because every value is a path. Condition 3 — the audit ledger existing beforehand — is load-bearing for the whole layer and not merely for running by hand: the migration that fails runs *after* the child exits and replaces its exit status with `1`, so a refusal that should report `77` would report `1` and every exit status this layer asserts would be the supervisor's cleanup.
- **The pre-flight passed no `--allow-cwd`, and that was a defect.** This line has now been wrong twice and is corrected in place a second time. The first version argued from `workdir.access`; the second argued that the flag is unnecessary because the pre-flight writes nothing inside the project, its canary being deliberately outside. That is true of the *grant* and silent about the *prompt*: with a terminal on `stdin`, nono asks `Share <project> with read+write access? [y/N]`, and the pre-flight had sent both output streams to `/dev/null`, so a real session hung on an invisible question. `M9a` gives the flag to both confined runs and adds `check_r6` arm 4 to keep it there. `die` spells the Landlock version constraint `>=` rather than `≥`, so the message a user reads survives a terminal without the glyph.

`check_sc3`'s set shrank from 21 to 20, `r6` leaving and nothing else moving. The suite is `1 of 8 checks failed`, that one being the progress bar.

### M4b — A confined `claude` starts (Status: IMPLEMENTED)

**Scenario**: Journey 1.1

**RED**: write `check_j1_1` against a `claude` on `PATH` that does not yet exist.

- [x] Check written and seen to FAIL with: `expected exactly one confined claude session, found 0` — **not** the predicted `claude: command not found`, and the difference is the finding below
- [x] `lib/confined-agent.nix` written; the wrapper shadows the agent name and the raw binary is not on `PATH` ([D3](plan.md#d3))
- [x] `flake.nix` exports `devShells.<system>.default` for **both** systems via `lib.genAttrs` ([D7](plan.md#d7))
- [x] `numtide/llm-agents.nix` added as the sole source of `nono`, `claude-code`, `opencode` and `pi`, pinned to a revision rather than a branch. **`allowUnfree` is not scoped to anything, because there is nothing to scope** — see below ([M1f](#m1f--spike-which-agent-packages-exist-and-where-status-done))
- [x] `XDG_DATA_HOME` points inside the project, in **both** `.envrc` and `flake.nix` per **P1**, above `use flake` so `check_bootstrap_mirror` picks it up without being edited
- [x] `nixConfig` declares `https://cache.numtide.com` and the key `niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=` as the **record** of where the binaries come from, and `docs/HANDBOOK.md` says what actually reaches the cache, because nix ignores the block for a non-trusted user
- [x] The `inputs.nixpkgs.follows` question decided either way, with the reason written down rather than left to the default
- [x] Every check invokes the **pinned** nono, not whatever `nono` `PATH` resolves to
- [x] Violation planted (the unconfined binary on `PATH` under the agent's own name), seen to FAIL, reverted, recorded in plan.md
- [x] `bash scripts/validate.sh --layer integration` passes

The wrapper creates `$XDG_CONFIG_HOME` before invoking nono. `M1e` observed that nono **silently falls back to the host's `$HOME/.config`** when that directory does not exist, warning rather than failing — so the redirection is undone by exactly the condition a fresh checkout is in.

**Three criteria above were added after the task was drafted, from preconditions verified before it started** ([research.md § M4b](research.md#m4b--the-pinned-toolchain-and-two-preconditions-the-plan-did-not-name)). Each was measured, not anticipated.

- **`XDG_DATA_HOME` is set in neither file today, and nix needs it.** Any evaluation of a flake carrying `nixConfig` reads `$XDG_DATA_HOME/nix/trusted-settings.json` to decide whether to honour the block, and `--no-accept-flake-config` does not avoid the read. So adding the input fails outright until the variable is set — which is a **P1** gap that exists now, before this task, and is only invisible because nothing here declared `nixConfig` yet.
- **`nixConfig` is not a mechanism.** For a non-trusted user nix prints `warning: ignoring untrusted flake configuration setting 'extra-substituters'` and proceeds without the cache. There is no prompt. The criterion is therefore split: declare it as the record, and put the operative `--extra-substituters` / `--extra-trusted-public-keys` invocation in the handbook. `M1f`'s claim that an untrusted user gets a prompt is corrected in `research.md` in place.
- **The checks must name the pinned binary.** Every assertion from `M1` to `M4a` was observed against a host `nono 0.73.0` resolving out of a user profile, which AGENTS.md §3 says is not available at all. The pinned revision carries `0.74.0`, and all four existing component and integration checks were run against it and **pass unmodified** — so the substrate change is safe, but a check still reading `PATH` would keep testing a binary a stranger does not have while reporting green.

**Implementation.** `lib/confined-agent.nix` is new; `flake.nix` is restructured around `forSystems`; `check_j1_1` joins `scripts/checks/integration.sh` and moves to the e2e layer with `M9a`.

- **The RED arrived by the wrong route, and that is the substantive finding.** The criterion predicted `claude: command not found`. Instead the first run exited **0** and failed with `expected exactly one confined claude session, found 0`, because this host carries `claude` in a user profile and `nix develop` keeps the host `PATH`. **The task's own planted violation happened by itself, before the code that prevents it existed.** So [D3](plan.md#d3)'s shadowing is not ergonomics: on any machine that already has the agent, the wrapper must come first on `PATH` or the environment runs the host's unconfined copy and reports success. The criterion is corrected in place rather than annotated, because the message it named was never the one a reader will see.
- **`allowUnfree` had nothing to scope, and scoping it would have cost the cache.** `claude-code` at this revision carries `license.fullName = "Unfree"` beside `license.free = true`, so a pure `nix build` succeeds with the permission set nowhere. Worse, it *cannot* be scoped as the criterion imagined: the packages are instantiated by the input against its own nixpkgs, so setting `config.allowUnfree` means importing our own nixpkgs with the input's `shared-nixpkgs` overlay and taking a **different derivation** from the one `cache.numtide.com` holds — compiling everything from source for a gate that never fires. Taking the publisher's binary is the same argument as the `follows` decision, one level down. `M1f`'s reasoning is retired in `research.md` in place.
- **The observable is a session, not a resolution.** `check_j1_1` reads `.tracked_paths` from `$XDG_STATE_HOME/nono/audit/<id>/session.json`, which is `granted ∖ floor` for a run that actually happened — the same set `SC-1` states as a property, now measured live rather than resolved. The banner was rejected because it collapses the floor to a count. The manifest was rejected because it **lies about this**: it reports the project `readwrite` for a session that reached only `/nix/store`.
- **`--allow-cwd` is the consent; `workdir.access` is only the level.** Without the flag a non-interactive session is granted no part of the project, and a confined write inside it silently leaves no file. The wrapper passes it. What this task did *not* find is that the same omission behaves differently again on a terminal, where nono prompts — `M9a` completes the picture and gives the pre-flight the flag too.
- **There is no `binary` field, against the plan's sketch.** `meta.mainProgram` already names the command, so `lib/confined-agent.nix` reads it from the very package it is about to run and a second spelling cannot drift from the first. For the same reason the entry points are keyed by the derivation's own name, so `nix build .#claude` and the name a user types coincide by construction rather than by agreement. `package` is a function of llm-agents.nix's package set rather than of `pkgs`, because the agent table is system-independent and that set is not.
- **The pinned binary is resolved lazily and memoised**, as `pinned_bin <attr>` in `scripts/validate.sh`, because the unit layer is defined to need no build. `check_r6` needed care: the pre-flight resolves `nono` from `PATH`, which is precisely the mechanism its second arm exploits, so every *unplanted* arm puts the pinned bin dir in front of the host's while the plant stays in front of that. The arms now differ by their plant and nothing else.
- **The pinning was proven to bite in both directions**, which the criterion did not ask for but P2 does. A sabotaged `nono` first on `PATH` is invisible to all five component and integration checks with the pinning in place; with it reverted to a bare `nono`, three component checks and `check_r6` fail, `check_component_merge` reporting `the floor resolves to no grants or no denies, so the merge claims would hold vacuously`. `check_j1_1` is indifferent either way, because it reaches nono only through `nix develop`.
- **The wrapper refuses rather than defaults** when `XDG_CONFIG_HOME` is unset: `''${XDG_CONFIG_HOME:?…}`, naming `nix develop` and direnv in the message. Silently choosing a directory is how `M1e`'s host-`$HOME/.config` fallback happens, and this task exists to close that.
- `NONO_NO_UPDATE_CHECK=1` is exported by the wrapper rather than set in the description, because nono reserves the `NONO_` prefix and its own validator rejects a description that sets one.
- **`XDG_DATA_HOME` turned out to be load-bearing for every `nix` command, not only for evaluating the input.** Once *this* flake declares `nixConfig`, nix reads `$XDG_DATA_HOME/nix/trusted-settings.json` before it will evaluate the flake at all, so under a sandbox that denies `$HOME` even `nix build` dies. `/.local/` and `/.config/nono/` were added to `.gitignore`.

`check_sc3`'s set shrank from 20 to 19, `j1_1` leaving and nothing else moving. The suite is `1 of 9 checks failed`, that one being the progress bar. Both systems evaluate: `packages.<system>.{claude,nono,confinement-claude-code}` and `devShells.<system>.default` all produce a derivation for `x86_64-linux` and `aarch64-darwin`, and `nix flake check` passes for the host system.

### M4c — The execution substrate is the session's own closure (Status: IMPLEMENTED)

**Scenario**: SC-1

[D15](plan.md#d15) grants the whole store read because at `M3c` there was no session whose closure could be computed. `M4b` creates one, so the temporal justification in the registry entry expires here. The reach this narrows is not hypothetical: the store on the developing machine holds tens of thousands of paths, a few hundred of them `-source` trees belonging to *other projects* — 67,051 and 251 when last measured, both of which drift upward with every build, which is why no criterion below pins either number. Read access to another project's source is precisely the leak this feature exists to prevent, so leaving it is not an option once the closure is knowable.

**RED**: extend `check_sc1`'s expectation to the closure and watch it fail against the whole-store grant.

- [x] The granted substrate is derived from `closureInfo` over **one** list that is also the devShell's `packages`, so the grants and the `PATH` the session runs with are the same expression and cannot drift apart. Roots are taken as package attributes, never as a restated output: `PATH` carries `jq`'s `bin` output while `jq^out` is a different path, and a root set that names the wrong one denies a tool the session can see — `sessionTools` in `flake.nix`, `substrateFor` over it, and `packages.<system>.substrate-<agent>` so a human and a check read the same answer
- [x] Every tool the devShell puts on `PATH` still works inside the session, and the tools the agent's own Bash tool needs — `git` above all, which the devShell does **not** provide today — are in that list rather than resolved from the host user profile ([P1](../../docs/CONSTITUTION.md), `AGENTS.md` §3)
- [x] `LOCALE_ARCHIVE` is set to an archive inside a **granted** store path, because the compiled-in default `/run/current-system/sw/lib/locale/locale-archive` is outside the store and setting the variable without granting what it names only moves the denial. `glibcLocalesUtf8` (2 MiB) rather than `glibcLocales` (222 MiB), and both halves conditional on `stdenv.hostPlatform.isLinux`
- [x] `strace -f -e trace=openat` over a real session shows **no `EACCES` or `EPERM` that a whole-store control does not also show**, asserted as an equality between two denial sets rather than as a count or a list of literals — `check_substrate_denials`, eleven identical `/sys` denials in both arms
- [x] `strace` is in the devshell for Linux only, as `lib.optionals stdenv.hostPlatform.isLinux`, so the check does not depend on a host tool ([P1](../../docs/CONSTITUTION.md)) and `devShells.aarch64-darwin.default` keeps evaluating. The check itself reports `SKIP` off Linux, for which the harness gained a skip status distinct from the product's exit 77, and the gap is recorded in the plan's coverage list rather than passed over
- [x] The registry's substrate entry is replaced or deleted, and if it survives, its `whyNotNarrower` no longer rests on the closure being unknowable — **deleted**, because keeping it as an upper bound narrows nothing: Landlock's allow rule on `/nix/store` subsumes every path beneath, measured as an out-of-closure path opening under the retained prefix and being refused without it. The registry is now empty, which [FR-3](spec.md) and [D18](plan.md#d18) make the healthy state
- [x] `bash scripts/validate.sh --layer integration` passes
- [x] Violation planted (a path dropped from the closure that the session needs), seen to FAIL, reverted, recorded in plan.md — dropping the locale archive's store path while `LOCALE_ARCHIVE` still names it bit three checks at three layers, and its trace named glibc's compiled-in fallback as a second denial. Three further plants recorded: the store prefix re-granted beside the enumeration, and the denial equality stripped of its control

**Preconditions**, measured before the task and recorded in [research.md § M4c](research.md#m4c):

- The narrowing works and is free. `claude --version` under a 17-path grant behaves exactly as under the whole store, and the store is 67,051 paths.
- **`PATH` cannot be narrowed.** It is inherited whole, host user profile included, even though it is not in `allow_vars`; `set_vars.PATH` is rejected as reserved and `deny_vars: ["PATH"]` has no effect. So the substrate cannot be the agent's own closure — under it the agent's Bash tool cannot run `ls` — and it has to cover everything the session can reach by name.
- **The floor denies eleven `/sys` paths in every arm**, including the whole-store control, so criterion 3's original form was unsatisfiable and is now differential.
- Grant count is not a constraint: 109 grants started in 0.33 s.
- A confined agent cannot start a second confined agent — the wrapper's `XDG_CONFIG_HOME` guard fires, by design — so the wrapper is not usable as a probe from inside a session.

One measurement from `M3c`'s spike still bounds the work: a 62-path closure served a session that opened 55 store paths, so the closure is a tight upper bound rather than a loose one, and every gap it left was named by exact path in the trace. Both gaps were the locale archive, which is why `LOCALE_ARCHIVE` is a criterion and not a discovery.

`strace` is the observer because nono is not. On a session that failed for a denied locale archive, `nono run --diagnostics-json` reported `"denials": []` and `"violations": []`, offering only an `info`-level `command_failed_likely_sandbox` whose remediation names a discovery mode that does not exist — there is no `--discover`, `--learn` or `--permissive` flag and no `discover` subcommand. A check that trusted nono's own denial reporting would pass over exactly the failure this task exists to find.

Deciding this at the integration layer is forced: `nono profile show` proves what nono *would* grant, and only a real session proves what the kernel enforces.

**The task reopened the spec, which is why it took a review gate mid-flight.** Deleting the registry entry left the closure's paths as neither the project directory nor a registry entry, and `FR-2` said the reach was those two things "and nothing else". Retaining the entry as an upper bound was the alternative the criterion above allows, and the measurement killed it. So `FR-2`, `FR-3` and `SC-1` were amended to name the execution substrate as a category of its own, with the reasoning in [D18](plan.md#d18): a registry entry owes a justification a human writes and reviews, and the programs a session runs are derived from the session's definition, so entries for them would be neither reviewable nor stable. The registry did not gain a kind of entry; it lost its only one.

**Checkpoint**: Journey 1 is independently verifiable by `bash scripts/validate.sh --layer integration`.

______________________________________________________________________

## M5 — The boundary holds

Refusals come immediately after the first working session, because they are what the feature exists to guarantee.

Every task in this group is subject to [D9](plan.md#d9): a check whose observable is a failure carries a positive control in the same session, because a session that never started, a binary that is missing and a boundary that works all produce the same failure. The control is named in each task below and is not optional.

### M5a — A key outside the project is unreadable (Status: IMPLEMENTED)

**Scenario**: R1

**RED**: `check_r1` plants an SSH key in the fake `$HOME` and reads it from inside.

- [x] Check written and seen to FAIL — but not by the route the criterion assumed, and the difference is recorded below rather than glossed: the property already held as shipped, so the only RED available is the planted one
- [x] Assertion covers both halves: the read fails **and** no key material appears in the output. A third assertion joins them — the failure must say `Permission denied` — because a key that had never been planted would exit non-zero and show no material just as convincingly
- [x] **Control**: a file inside the project is read successfully in the same session, so a session that failed to start cannot pass. Asserted in **both** arms, and first, so every other assertion is reached only once the session is known to have run
- [x] The fake `$HOME` lies **outside** the project, and the check says why rather than leaving it to look arbitrary — the 48 `$HOME`-relative denies and the startup refusal they cause, in the comment above the check
- [x] Violation planted (`$HOME/.ssh` in the registry), seen to FAIL, reverted, recorded in plan.md — all three shipped-arm assertions fired at once, and the plant took `check_j1_1` with it for an unrelated reason worth keeping

**Measured before starting, in `research.md` § `M5a`.** Four things the check can be written against rather than discovered by:

The property already holds as shipped — one `bash -c` gave `READ_DENY` on `$HOME/.ssh/id_ed25519` and `READ_OK` on a file in the project, so the refusal, the absence of key material and `D9`'s control all come from a single invocation and need no instrument beyond the shell. `coreutils` is in the substrate, so `cat` is available too.

The fake `$HOME` **must** be outside the project. The resolved description carries 48 `$HOME`-relative deny rules, so a `HOME` under the granted project makes nono refuse to start with `Landlock deny-overlap is not enforceable on Linux`. `mktemp -d -p "$XDG_RUNTIME_DIR"` is the route, as `check_j1_1` already does.

The planted violation does bite, and it bites harder than expected. Granting exactly `$HOME/.ssh` reads the key material out, even though `deny_credentials` — a `required` group whose whole purpose is keeping credentials out — denies that path. So the required deny groups are **not** a backstop behind the leak registry, and this task is the only thing asserting `R1` at the kernel. [D4](plan.md#d4) is corrected accordingly.

Granting an **ancestor** of a denied path refuses to start instead of narrowing quietly. A plant must therefore name the exact path, or it will fail for the wrong reason and prove nothing.

**Implementation.** `check_r1` joins `scripts/checks/integration.sh`. Three arms, one session each: the shipped description, the shipped description with the key's directory added to `filesystem.read`, and an unconfined read of the key before either.

- **There was no RED to see at this layer, and saying so is the finding.** The criterion is written as though the check would fail before the code existed, but the code exists: `R1` has held since `M4b`. The RED that is honestly available is the one the unit layer reports — `check_sc3`'s missing-scenario set shrank from 21 to 20, `r1` leaving and nothing else moving — plus the planted violation below, which is the only way to watch this check fail. Every future task in `M5` inherits this: a refusal that already holds cannot be test-driven, only planted against.
- **The plant bites, and `$HOME` is expanded inside `filesystem.read`.** That was untested before — the registry writes `entry.path` into the description verbatim, and only the `$WORKDIR` substitution was known to work. With `$HOME/.ssh` in the registry, the built description carries it unexpanded, nono resolves it against the ambient `HOME`, and the shipped arm reads the key out: **exit 0, key material in the output, and no `Permission denied`** — all three assertions firing together, which is what says the three are not one assertion written out three times.
- **The plant also breaks `check_j1_1`, for a reason that has nothing to do with `R1`.** That check takes the registry side of its comparison straight from `nix eval`, unexpanded, while `tracked_paths` is written expanded, so the two cannot match for an entry naming a variable. Its session also gained no tracked path at all, because its fake home has no `.ssh` — a grant on a path that does not exist is silent rather than an error, which is what a typo in an entry will look like. The registry is empty, so this is latent, but the **first real entry naming any variable will fail `check_j1_1` spuriously**. Recorded in [research.md § M5a](research.md#m5a--a-key-outside-the-project-is-unreadable) rather than fixed here: fixing it means deciding where expansion happens, which is a change to `lib/confinement.nix`'s contract and not this task's.
- **The permanent third arm is the probe's own positive control**, and it is the finding from the preconditions made executable: with the key's directory granted, the same probe must read the key out. It names the directory exactly, never an ancestor, because a grant above a denied path is refused at startup. The arm is not scaffolding to be deleted — without it, a probe that could read nothing at all would pass the shipped arm.
- **The probe reads with the shell's own redirection rather than by calling `cat`.** `PATH` is inherited whole, host entries included, as `M4c` measured, so a name resolved inside the session can land on a binary the session may not read, and the probe would report a denial of its own. It is also why `bash` comes out of `substrate_member` rather than off `PATH`.
- **The probe prints the key material it managed to read, on purpose.** An assertion that no key material appears in the output proves nothing against a probe that never shows it, so the successful read in the granted arm and the empty read in the shipped one differ in exactly the string being asserted about.
- Both canaries are generated per run, so a stale match in a scrollback or a log cannot satisfy either assertion.

The integration layer is `4 checks passed` and the whole suite is `1 of 11 checks failed`, that one being the progress bar. **The integration layer must be run from inside the devShell** — `nix develop -c bash scripts/validate.sh --layer integration` — because the pre-flight `check_r6` exercises execs `true` by bare name, which on a host carrying one outside the store resolves to an ungranted path and turns assertion 1 into a false 77. Recorded in the plan's coverage gap.

### M5b — A write outside the project is refused (Status: IMPLEMENTED)

**Scenario**: R2

**RED**: `check_r2` creates a file in the fake `$HOME` from inside.

- [x] Check written and seen to FAIL — under the plant, as with `M5a`: the property already held
- [x] Assertion covers both halves: the attempt fails **and** the file does not exist afterwards. The second half is asserted from the host, after the session has exited
- [x] **Control**: a write inside the workdir succeeds in the same session and the file is there afterwards, so a read-only session cannot pass
- [x] Violation planted, seen to FAIL, reverted, recorded in plan.md. **Not the plant written here**: `filesystem.allow = ["$HOME"]` makes nono refuse to start, so it fails the check on its control instead of on its refusal. The plant that bites names the target's own directory, `$HOME/outside`

**Measured before starting.** Four arms against the shipped description, all on x86_64-linux with nono 0.74.0.

| Arm | Result |
| --- | --- |
| Write to the fake `$HOME` | `Permission denied`, exit 1, **file absent afterwards**, and the in-workdir write in the same session succeeds |
| `filesystem.allow += ["$HOME"]` | **Refuses to start.** `Refusing to grant '<home>' (source: Profile) because it overlaps protected nono state root '<home>/.nono'` |
| `filesystem.allow += ["$HOME/probe"]` | Starts, the write succeeds, the file is there — so `$HOME` expands in `allow` as it does in `read` |
| The same subdirectory, shipped | Denied — so the arm above differs by the grant and not by the path |

The second row is the one that changed the task. nono protects a state root **candidate** under `$HOME` whether or not `XDG_STATE_HOME` moved the real one elsewhere, so any grant on a home directory is refused before the 48 deny rules are even considered. That is a second, earlier reason a plant must name an exact path, alongside the deny-overlap `M5a` found.

**Implementation.** `check_r2` joins `scripts/checks/integration.sh`, three arms, one session each: the shipped description, the shipped description with the target's directory added to `filesystem.allow`, and an unconfined write to the target before either.

- **Both arms aim at the same path**, a subdirectory of the fake `$HOME` rather than the fake `$HOME` itself, because the granted arm cannot name a home directory without being refused at startup. A control that succeeded at a different path than the one the shipped arm is refused at would not be controlling the same thing.
- **The second half of the scenario is asserted from the host, not from the session.** A refusal reported inside the sandbox is the sandbox's own account of itself; the file's absence afterwards is the fact `R2` is about. This matters more than it looks: nono's own summary printed `No path denials were observed during this session. The failure may be unrelated to sandbox restrictions.` for a write it had just refused, so its report is not usable as evidence either way and the check relies on the shell's `Permission denied` and on `[ -e ]`.
- **The plant the task asked for proves nothing**, and correcting it in place is the finding. With `$HOME` granted, all five integration checks fail at startup — including `check_r6` and `check_substrate_denials`, which grant the *real* `$HOME` and hit the same refusal — and `check_r2`'s failure is `the shipped arm never wrote inside the project, so it observed no session`. That is the control firing. The corrected plant fires all three refusal assertions at once instead.
- **The three checks now sharing a live session grew a fixture.** `session_fixture <agent>` resolves the description, the substrate and a `bash` out of that substrate, each failing separately, so `check_r1` and `check_r2` state it once rather than twice — and `M5c` onwards will not state it a third time.

The integration layer is `5 checks passed`, run as `nix develop -c bash scripts/validate.sh --layer integration`, and the whole suite is `1 of 12 checks failed`, that one being the progress bar: `check_sc3`'s missing-scenario set went from 20 to 19, `r2` leaving and nothing else moving.

### M5c — No host secret crosses (Status: IMPLEMENTED)

**Scenario**: R3

**RED**: `check_r3` exports a random canary as `ANTHROPIC_API_KEY` and prints the confined environment.

- [x] Check written and seen to FAIL with the canary present — under the planted violation, `the host secret crossed into the session, carried by: ANTHROPIC_API_KEY`
- [x] `environment.allow_vars` written explicitly, default-deny ([D6](plan.md#d6)) — the mechanism FR-5 rests on. It was already written; what this task adds is the measurement that it is what does the work, and a check that fails if it stops
- [x] The canary is generated per run, so the check asserts a property rather than a value. So is the `TERM` the control looks for
- [x] **Control**: a variable the session is meant to inherit — `TERM` — is present in the same output, so an empty environment cannot pass. It is asserted with the host's value, which says the list passes variables through rather than merely naming them
- [x] Violation planted (remove `allow_vars`), seen to FAIL, reverted, recorded in plan.md

The measured starting point is 233 variables crossing into a child, `HOME` and every `XDG_*` among them, and the devShell's whole `shellHook` body exported verbatim as a variable of its own. `HOME` and `XDG_STATE_HOME` stay as they are, deliberately and for different reasons ([D13](plan.md#d13)).

**Measured before starting.** Against the shipped description, with `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `TERM` and `LC_TESTVAR` canaries in the host environment ([research](research.md#m5c--no-host-secret-crosses)):

| Arm | Variables crossing | Secret canary |
| --- | --- | --- |
| shipped | 20 | absent, both of them |
| `del(.environment.allow_vars)` | 221 | present, both of them |
| `allow_vars += ["ANTHROPIC_API_KEY"]` | 21 | present |

So nono's default without the key is pass-everything, and the 221 corroborates the 233 above. Of the 20 that cross under the shipped description, 10 come through `allow_vars` — `LC_TESTVAR` among them, so the `LC_*` glob works — 7 are `set_vars`, and 3 are nono's own: `PATH`, `BROWSER` and `NONO_CAP_FILE`.

**Implementation.**

- The session command is `env -0` out of the substrate, with no probe script between it and the scenario's "prints its own environment". `-0` because the host carries the devShell's entire `shellHook` body as a variable, newlines included, which a newline-separated listing would split into entries that parse as variables of their own. It is captured to a file rather than a command substitution, because bash drops NUL bytes from `$(…)` and would run the whole environment together into one unsplittable line.
- The assertion the scenario asks for is on the canary's **value**, never on the name `ANTHROPIC_API_KEY` being absent. M7 sets credentials for a session, plausibly under that very name, and this check must not be what breaks when it does.
- Alongside it, the property the scenario is an instance of: every name that crossed is either matched by an `allow_vars` pattern, or is a key of `set_vars`, or is one of nono's three. Both lists are read out of the built description with `jq`, so adding a variable there moves the expected set with it. The three injects are named in the check because they are the only names in a session that nothing in this repository asked for, and a fourth appearing is a change in nono worth failing over.
- Both aggregate failures report once, with a count. The first draft failed once per unsanctioned name, and under the plant that was 200 lines that buried every other assertion in the suite. The secret's carriers are named rather than printed, so the suite's own output does not become the leak.
- The plant — deleting `allow_vars` from `lib/confinement.nix` — was confirmed absent from the built description before its FAIL was trusted, and it also fails `check_substrate_denials`, because the host's `LOCALE_ARCHIVE` then crosses and points at a `glibc-locales` store path that is not in the narrowed substrate. Under the plant the *granted* arm fails its control rather than its assertion: `allow_vars += [...]` on a missing key yields a one-element list, which is stricter than the shipped description, and `TERM` stops crossing.

The integration layer is `6 checks passed`, run as `nix develop -c bash scripts/validate.sh --layer integration`, and the whole suite is `1 of 13 checks failed`, that one being the progress bar: `check_sc3`'s missing-scenario set went from 19 to 18, `r3` leaving and nothing else moving.

### M5d — An agent cannot widen its own confinement (Status: IMPLEMENTED)

**Scenario**: R4

**RED**: `check_r4` rewrites `lib/leak-registry.nix` from inside a running session.

- [x] Check written and seen to FAIL — and here, unlike M5a to M5c, the first FAIL was at the integration layer and was the check's own fault: the wrapper assertion started as a line-level search for `$PWD` near `--profile`, and the shipped wrapper legitimately carries `--workdir "$PWD"` on that same line. It reported the workdir as if it were the description. The assertion now extracts the value given to `--profile` and to `PREFLIGHT_PROFILE=` and requires each to be the store path or the variable holding it.
- [x] Both halves asserted, which together are FR-9: four readings of the same target — before the edit and after it inside the editing session (`BEFORE :: 1`, `EDIT :: 0`, `AFTER :: 1`), from a second session started with the same description once the first exited (`READ :: 1`), and from a third started with the description rebuilt out of the edited source (`READ :: 0 :: <canary>`)
- [x] **Control**: the edit is confirmed to have landed on disk — the file differs from the backup and carries the planted path — and the check returns the source to what it found, then rebuilds and asserts the original description store path comes back
- [x] Violation planted (wrapper reads the profile from `$PWD`), seen to FAIL, reverted, recorded in plan.md

**Measured before starting.** Recorded under [`M5d`](research.md#m5d--an-agent-cannot-widen-its-own-confinement).

| Step | Observed |
| --- | --- |
| Session edits `lib/leak-registry.nix`, reads the target before and after | `BEFORE :: 1`, `EDIT :: 0`, `AFTER :: 1` — the write lands, the reach does not move |
| Second session, same description | `READ :: 1` |
| `nix build .#confinement-claude-code` from the edited tree | a different store path, and `warning: Git tree is dirty` on stderr |
| Third session, rebuilt description | `READ :: 0 :: <canary>`, the capability banner listing the granted directory |
| Old wrapper store path after the rebuild | still names the old description — a built entry point is pinned to the description it was built with |

**Implementation.**

- The scenario says "grant the whole home directory". It cannot: M5b measured that a grant covering a parent of nono's deny rules makes it refuse to start, so every session would fail to start and the refusals would be that refusal rather than the boundary holding. The grant names an exact directory inside the fake `$HOME` instead.
- The planted violation is caught by the wrapper assertion and by nothing else. Every session in the check is driven by handing `nono` a description path, so an entry point that resolved its description from `$PWD` leaves all four readings exactly as they are. That is why the check reads the built entry point at all, and why the assertion is about the value of `--profile` rather than about the shape of the line it appears on.
- The widening is written by substituting a needle, `entries = map checkEntry [ ];`, and the check fails loudly when the needle is absent rather than writing the file back unchanged. A registry that had been refactored would otherwise leave this check passing on an edit that widened nothing.
- The registry is restored by a `RETURN` trap that runs before the scratch directory holding the backup is removed. A run killed outside bash's control leaves the registry edited; `git checkout -- lib/leak-registry.nix` is the repair, and the check says so where the trap is set.
- stdout and stderr are kept in separate files rather than merged the way `check_r1` and `check_r2` merge them, because nono prints its whole capability banner to stderr and the readings would be needles in it. The two `nix build` invocations have their stderr captured for the same reason: the dirty-tree warning on the suite's own stderr reads as the suite having left the tree changed.
- This is the most expensive check in the suite — three sessions and two evaluations of the flake — because the scenario's second half is about what a *rebuild* produces, and nothing short of a rebuild answers it.

The integration layer is `7 checks passed`, run as `nix develop -c bash scripts/validate.sh --layer integration`, and the whole suite is `1 of 14 checks failed`, that one being the progress bar: `check_sc3`'s missing-scenario set went from 18 to 17, `r4` leaving and nothing else moving.

### M5e — An untrusted repository cannot grant itself paths (Status: IMPLEMENTED)

**Scenario**: R5

**RED**: `check_r5` places an agent config file in the checkout requesting `$HOME`.

- [x] Check written and seen to FAIL — at the unit layer as RED, and at its own layer under the plant. As with `M5a` to `M5d`, the property already held as shipped, so the plant is the only route to watching this check fail
- [x] **Control**: not the benign-setting probe the criterion asked for, but a stronger one, and the substitution is the finding — the same file, in the same place, resolved **by name**, granting the very path under test and observed reading a canary out of it. A benign setting would only prove the file was parsed; this proves the request was refused rather than unread
- [x] FR-15's override path is exercised too: a fourth arm adds `NONO_ALLOW` at the invocation and the granted reach differs from the clean run by **exactly** that one grant, asserted in both directions. "And only from there" is not asserted, because it is not a property nono has — see below
- [x] Violation planted (`--profile ${profile}` → `--profile ${name}`), seen to FAIL, reverted, recorded in plan.md. It took `check_r4` and `check_j1_1` down with it, and it exposed a registry fetch nobody had looked for

**Measured before starting**, in [`research.md § M5e`](research.md#m5e--an-untrusted-repository-cannot-grant-itself-paths). Eight arms established that R5 holds and why; a further six closed the three surfaces the first pass left owed.

| Surface | Verdict |
| --- | --- |
| a nono user profile inside the project | denied when the wrapper names a store path, honoured the moment anything resolves it by name |
| `NONO_PROFILE`, `NONO_ALLOW`, `--extends` | all widen, all arrive at the invocation, none from a file in the project |
| `config.toml` inside the project | read, and cannot widen — `[extensions]` and `[overrides]` are not keys it validates — but it can make the entry point exit `77`. [D19](plan.md#d19) |
| `--bypass-protection` | refuses to start without a grant, adds nothing to one that has it, and is the one widening flag with no environment variable |
| a project-level `trust-policy.json` | selects which files are verified against which keys, never which paths are granted. Outside R5 |

The measurement that changed the check's shape is that **nono prints its whole capability set to stderr before the program runs**, with no ANSI escapes when stderr is not a terminal. That makes the real entry point the instrument: `claude --version` exits in about a second and its banner is the session's granted reach, as a set that two runs can be compared on.

**Implementation.** `check_r5` joins `scripts/checks/integration.sh` with two new helpers and four arms.

- **The subject is the real entry point, not a composed `nono run`.** Every other check in the suite supplies `--profile` itself, so a wrapper that resolved its description from the checkout would leave their readings untouched — which is exactly why `check_r4` had to assert on the wrapper's *text*. Driving `.#claude` instead puts the plant in the path of the observable, and the plant firing on `check_r5`'s subject rather than on a control is what confirms it.
- **The assertion is set equality between a hostile checkout and a clean one**, not the absence of the hostile path. Both are asserted — the path is absent, and the whole set is `diff`-identical — because a session that lost an unrelated grant would satisfy the first and still be a change in reach.
- **`granted_reach` and `reach_grants` are the two helpers**, and both are property-shaped rather than literal. The first extracts the banner by its grammar — first field one of `r`, `w`, `x`, `r+w`, `net`, `+` — and swallows grep's non-match so an empty set is an answer the caller asserts about rather than a crash. The second matches mode and path **by field** with `awk`, so a grant is found regardless of the banner's column alignment.
- **The checkout's configuration is a scratch config root, not the developer's `.config`.** The check exports `XDG_CONFIG_HOME` at a directory under `$REPO_ROOT/.tmp`, which is what a checkout controls under [C1](plan.md#c1) without the check writing into a root a human is using. That decision is load-bearing rather than tidy: the plant, run before it, pulled a third-party pack into the real `.config/nono/packages`.
- **FR-15's second half is not asserted, and the task says why rather than quietly dropping it.** "Widening works from the invocation, and only from there" — the first half is arm 4. The second is not a property nono holds: a checkout's own `.envrc` is part of the calling environment once a human has run `direnv allow`, so the distinction FR-15 draws is a human one and belongs in the handbook. Recorded in the plan's coverage gap.
- **The plant was sharper than the plan predicted, in a way that corrects `D10`.** With the wrapper naming `claude-code` instead of a store path and an *empty* config root, nono did not refuse: it pulled `nolabs-ai/claude` from `https://registry.nono.sh` and applied a description granting `$HOME/.claude` read-write. So the by-name wrapper lands on the checkout's file when a checkout ships one and on a registry pack when it does not, and both are the leak this feature removes. `nono profile list` shows nine language runtimes and `nono profile show claude-code` says `Profile not found`, so `M1e` measured honestly with the instruments it had; the resolver `nono run` uses is a different one. A store path never pulls, which is a reason for FR-9's pinning the plan had not stated.
- **The plant also wrote executable hooks and a skill into the project**, by way of that pull, which is FR-26's category arriving through a channel no check watches. The residue was removed and `.config/` is gitignored, so nothing reached the index, but it is recorded because it is a gap rather than an anecdote.

The integration layer is `8 checks passed`, run as `direnv exec . bash scripts/validate.sh --layer integration` in 49 s. Under the plant it was `3 of 8 checks failed` — `check_r5` on its subject, `check_r4` on its wrapper text, `check_j1_1` on its reach comparison. `check_sc3`'s missing-scenario set went from 17 to 16, `r5` leaving and nothing else moving.

**Measured before starting** ([`research.md`](research.md#m5e--an-untrusted-repository-cannot-grant-itself-paths)). Eight arms against the shipped description, with the checkout's agent configuration modelled as a nono user profile *inside the project* — which is where `XDG_CONFIG_HOME` already points nono's user profile directory, so the file needs no contrivance to be found.

| Arm | Observed |
| --- | --- |
| `--profile <store path>`, a widened description sitting in the project's config root | denied — R5 holds as shipped |
| `--profile evil`, that same file resolved by name | the canary is read — the file is live, not inert |
| `--profile <store path>` with `NONO_PROFILE=evil` in the environment | denied — the command-line argument beats the variable |
| `--profile <store path>` with `NONO_ALLOW=<dir>` | the canary is read — an invocation widens a pinned description |
| `--profile <store path> --extends evil` | the canary is read |

What that settles before the check is written:

- R5 holds for one reason: the wrapper writes `--profile <store path>` as a command-line argument, and the argument beats `NONO_PROFILE`. A description inside the checkout is not refused or even noticed. The assertion is about the entry point naming its description, which is the same property `check_r4` already asserts on the wrapper.
- The control criterion asks for "the same file read for a benign setting". The by-name arm is stronger and is what to use: the same file, in the same place, granting the very path under test. A benign-setting probe would only show the file was parsed.
- FR-15's "widening works from the invocation" needs no new mechanism — `NONO_ALLOW` is additive to a pinned description today, and `--extends` is a second channel. "And only from there" is not something nono enforces: a checkout's own `.envrc` is part of the calling environment once a human has run `direnv allow`. The check can assert the first half; the second is a human decision and belongs in the handbook rather than in an assertion.
- The plant the criterion names is the wrapper resolving `--profile evil`, or dropping `--profile` so `NONO_PROFILE` decides. Both were measured reading the canary out, so either bites.
- Still unmeasured, and owed before this task can claim to have covered the surface: what keys `nono/config.toml` accepts, what a project-level `trust-policy.json` can do, and `--bypass-protection <PATH>`, which is documented as overriding a deny rule.

### M5f — A host-global configuration does not reach an undeclared session (Status: IMPLEMENTED)

**Scenario**: Journey 8.2

This task was written against R9 and is now the *undeclared* half of the pair R9 became. A machine with no declaration is the state every consumer starts in and the only state a stranger is ever in, so it belongs here, with the rest of the boundary, and needs none of the mechanism `M8f` builds. R9 itself is the declared half and is a difference between two runs, which is why it moved to [`M8g`](#m8g--the-declared-surface-is-exactly-what-arrives-status-pending).

**RED**: `check_j8_2` plants a whole host-global agent configuration in the fake `$HOME` — an authoring surface among it — declares nothing, and compares the session's granted reach to `{project} ∪ registry`.

- [x] Check written and seen to FAIL — at the unit layer, `check_sc3`'s missing-scenario set going from 16 to 15, `j8_2` leaving and nothing else moving. As with every task in this group, the property already held as shipped, so the FAILs that say something about the code are the two planted ones below
- [x] The assertion is the **set equality**, not the absence of an error — `diff -u` of the session's own `tracked_paths` against `{project} ∪ substrate ∪ registry`, derived the same way `check_j1_1` derives it. The reason has changed, and the change strengthens the criterion rather than retiring it: for `claude-code` the host surface is hidden by **redirection**, not by denial, so nothing would have been denied and no error would have appeared either way ([D17](plan.md#d17))
- [x] The agent starts, works, and reports none of the planted extensions — `claude plugin list` exits 0 and its listing carries the in-project extension and not the host one (FR-21)
- [x] **Control**: an extension planted inside the project — under `$CLAUDE_CONFIG_DIR/skills`, not `.claude/skills` — is reported `✔ loaded` in the same session. It accumulates rather than returning early, so a violation that breaks the control and loads a host extension at once reports both
- [x] Violation planted, seen to FAIL, reverted, recorded in plan.md. **Not the plant written here**, and the correction is the finding: the wrapper reading a declaration from a file inside the project fails no check, because the file it would read is `lib/leak-registry.nix`, which sits on both sides of the comparison. Two plants are used instead — a `--read "$HOME/.claude/skills"` in the wrapper, which fires the set equality, and that plus dropping `CLAUDE_CONFIG_DIR`, which fires all four assertions

**Measured before starting**, recorded under [`M5f`](research.md#m5f--a-host-global-configuration-does-not-reach-an-undeclared-session). Four things, on `claude-code` 2.1.237 with nono 0.74.0.

`claude plugin list` is the enumeration instrument, and it is the only one. There is no `debug skill` equivalent — `claude --print /skills` answers `/skills isn't available in this environment.` and `claude doctor` reports installation health and names no extension. `plugin list` runs confined, exits 0 in about a second, and needs no credentials.

A skills-directory extension needs a manifest. A bare `SKILL.md` is invisible to `plugin list` even unconfined, so the planted extension carries `.claude-plugin/plugin.json` alongside it.

**The host surface is hidden by redirection, not by denial**, and that is a finding against the criterion this task was written from.

| Arm | Reported |
| --- | --- |
| unconfined, `HOME` only | the host canary, `Scope: user`, loaded |
| unconfined, `HOME` plus `CLAUDE_CONFIG_DIR` | the project canary only; the host canary absent |
| confined, through the entry point | the project canary only; the host canary absent, and **no denial in stderr** |

`D17`'s `$HOME`-relative hazard was measured for `opencode`; `claude-code`'s user-scope skills root follows `CLAUDE_CONFIG_DIR`, which the description already sets. So the confined arm is behaviourally identical to the unconfined arm that sets the variable, which is FR-21's "must not prevent one from working" already holding — and it is why the set equality matters more rather than less, since a leak here would arrive silently with nothing to catch it.

The in-project control cannot be `.claude/skills`. Every arm printed `1 project-scope plugin directory under ./.claude/skills/ was not loaded because this workspace was not trusted when plugins were scanned`, so a project-scope extension is scanned and not loaded pending an interactive dialog. `$CLAUDE_CONFIG_DIR/skills` — `$WORKDIR/.agents/claude/skills`, inside the project — loads cleanly and is the control.

**Implementation.** `check_j8_2` joins `scripts/checks/integration.sh`, one session, with two helpers beside it: `plant_extension` writes the manifest and the prose, and `extension_loaded` delimits one stanza of the listing before looking for `loaded` on its `Status:` line.

- **One session answers both halves**, because the extension question and the reach question are asked of the same run: `claude plugin list` through the real entry point, with a whole host-global configuration planted in the fake `$HOME` — an authoring surface, a credential file, a history file, `.claude.json`, a target directory, and a nono description of its own naming that directory in `filesystem.read`. Credentials, history and state are covered by the set equality rather than by assertions of their own, which is what makes that assertion carry FR-21 whole.
- **A second, named assertion says no tracked path is under the fake `$HOME`.** The set equality already implies it, but its failure would be one hunk among 130 store paths, and the self-referential case — a host description taking part in deciding reach — is the sharpest thing this check refutes and deserves to be legible.
- **An assertion was removed after the plant showed it could not bite.** A `grep -F "$home"` over the listing would pass while a host extension was loading, because `claude` abbreviates the prefix and prints `Path: ~/.claude/skills/<name>`. A comment stands where it was.
- **The control accumulates rather than returning early.** The first run of the second plant reported only the broken control, hiding the host extension being loaded in the same listing. Ordering the control first satisfies `D9` — a session that never started fails there — but only if the louder finding is still reached.
- **The criterion's own plant fails no check, and that is recorded rather than worked around.** An in-project declaration channel for this feature would be an entry in `lib/leak-registry.nix`, which both this check and `check_j1_1` read as the expected set, so a host path added there moves both sides together. The gate is human review of that file, and it is written into the plan's coverage gap.
- **Plant 1 leaves `check_j1_1` passing**, which is why this check exists: that check's fake `$HOME` has no `.claude/skills`, and a grant on a path that does not exist is silent.

The integration layer is `9 checks passed`, run as `direnv exec . bash scripts/validate.sh --layer integration`, and the whole suite is `1 of 16 checks failed`, that one being the progress bar: `check_sc3`'s missing-scenario set went from 16 to 15.

### M5g — A host tool configuration does not direct the session (Status: IMPLEMENTED)

**Scenario**: R10

R9's counterpart for the ordinary toolchain, and the sharper case, because this one was observed happening rather than reasoned about. A live session read `credential.helper = cache` out of the host `~/.gitconfig` and tried to start a daemon; it failed only because that session's workdir happened to be read-only, and in the shipped arrangement it is not. The danger is not the file being readable but the directives in it, so a read-only grant is no protection — the same class as `core.hooksPath`, arriving through a key that looked harmless.

**RED**: `check_r10` places a configuration in the fake `$HOME` carrying a directive that runs a program, and inspects the toolchain's effective configuration from inside.

- [x] Check written and seen to FAIL — and this is the **one task in `M5` with a real RED**, because the property did not hold as shipped. It failed on its own control: `the toolchain is directed at a configuration file this environment never wrote, so the session has no commit identity and the outcome depends on what the host contains`. `GIT_CONFIG_GLOBAL` named `$WORKDIR/.agents/git/config` and nothing anywhere created it
- [x] `groups.include` does not carry `git_config`; `GIT_CONFIG_GLOBAL` points at a file this environment wrote and `GIT_CONFIG_SYSTEM` is `/dev/null` ([D11](plan.md#d11)). **The two halves are asserted one layer apart, because they catch different things** — see below. The group is `check_confinement_validates`'s and `check_sc1`'s; the variables' *values* are asserted from inside a live session by this check, which is stronger than asserting the key is present
- [x] Second arm: `COMMIT_RC :: 0` and the marker the planted `pre-commit` hook would have written is absent afterwards, checked from the host
- [x] **Control**: two of them. The planted directive is confirmed to run **outside** the boundary first, so a hook that never worked cannot pass as a hook refused; and `user.name` is read back out of the effective configuration inside the session, so a toolchain with no configuration at all cannot pass
- [x] `user.name` and `user.email` are copied from the host once at setup and a consumer can override them (FR-23). The file is asserted to hold **exactly** those two keys with the host's values and nothing else, and a third session asserts a file the consumer has edited is left untouched
- [x] Both violations planted, each seen to FAIL, reverted, recorded in plan.md. **Three plants, not two**, because the first one does not bite where the criterion assumed

**Measured before starting**, recorded under [`M5g`](research.md#m5g--a-host-tool-configuration-does-not-direct-the-session).

The effective configuration inside a session was already clean — no `global` scope, no `system` scope, none of six planted directives — while the same probe run unconfined with the same `HOME` reported all six. So the probe discriminates, and pointing `GIT_CONFIG_GLOBAL` at a path that does not exist suppresses both `~/.gitconfig` and `~/.config/git/config`.

But the file it pointed at **did not exist**, and nothing in the repository created it. `user.name` inside a session was coming from the checkout's own `.git/config`. That is the RED, and closing it is this task's production change.

`GIT_CONFIG_SYSTEM=/dev/null` is load-bearing even here, where `/etc/gitconfig` does not exist: with the variable, `git config --list --system` is exit 0 and empty; without it, exit 128 and `fatal: unable to read config file '/etc/gitconfig'`. The variable stops the toolchain going looking, so the assertion is that the system scope resolves and contributes nothing — failing by error on this host and by content on one that carries the file.

A `core.hooksPath` hook in a granted directory does run, measured unconfined, so the second arm tests something live rather than hypothetical. And a commit with no identity fails visibly, exit 128 with `Please tell me who you are`, which is the **P9** shape a missing file should produce.

**Implementation.** `check_r10` joins `scripts/checks/integration.sh` — three sessions and one unconfined control — and the entry point gains the file FR-23 always said existed.

- **The identity file is written by the entry point, create-if-absent**, which is the decision `D11` had left open. Not the shell hook, because a stranger running `nix run <ref>#<binary>` never enters one. Create-if-absent makes three requirements one mechanism: "once at setup", the consumer override — whatever the file says already wins, and nothing rewrites it — and `M9b`'s idempotency. Only `user.name` and `user.email` are copied, `|| true` on each because `git config --get` exits 1 when unset. A host with no identity leaves **no file**, so the failure is git's own rather than a placeholder commit, and a host that gains one later is still picked up.
- **No environment-variable override was added.** FR-23's "a consumer may override" is satisfied by editing the file, which no check would distinguish from a variable, and the skill forbids an option no check exercises.
- **The scratch project is a sibling of the fake `$HOME`, never under it**, for the reason `M5a` found: the 48 `$HOME`-relative deny rules make a granted directory beneath the home unenforceable.
- **The hook lives inside the project and its shebang is the substrate's own bash.** A hook in the fake home would be unreadable inside a session, so a crossed directive would fail for a reason unrelated to the directive; `#!/bin/sh` would fail to exec in a store-only session. Either would mask a leak as an unrelated error.
- **The origins assertion is a property**: every `file:` origin in the effective configuration must be under the project. The four named directives are asserted individually alongside it, because a property failure names a file and the point of the scenario is which directive arrived.
- **Plant 1 is inert at this layer, and that is the finding.** Including `git_config` changes nothing `check_r10` can see: while `GIT_CONFIG_GLOBAL` is set, git ignores `~/.gitconfig` however readable it is. **The grant alone is not the leak — the search is**, which is `D11`'s point made executable. The component layer catches it instead, so no value assertion was added there: it would be a third copy of an assertion two layers already make.
- **Plant 2 reconstructs the incident the decision was written from**, and is the one that matters: `credential.helper = cache` in the effective configuration, `commit.gpgsign` producing `gpg failed to sign the data`, and a program named by the host configuration **executing inside the session** and leaving its marker.
- **Two bugs in the check were found by planting, not by writing it.** `git config --file` happily parses a `--show-origin` listing and exits 0, so the control's fallback never ran; and git lowercases keys in `--list`, so `core.hooksPath` read back as `core.hookspath` and the one directive observed *running* was the one directive not reported. It was the only assertion of the six that could not have failed. Both say the same thing: a check that has only ever passed has not been checked.

### M5h — Every refusal check has a control (Status: IMPLEMENTED)

**Scenario**: none directly — this enforces [D9](plan.md#d9) over the suite, which is why it comes last in this group, when there are refusal checks to enforce it over.

**RED**: write `check_controls`, which reads the suite's own text and asserts that every `check_r*` invokes a control.

- [x] Check written and seen to FAIL against a refusal check with its control removed — `refusal check asserts no permitted action: check_r2 (integration.sh)`, verbatim what the plan predicted
- [x] Suite-wide violation planted, seen to FAIL, reverted, recorded in plan.md. **Not the wrapper**: the lever that reaches every refusal check is the built description they all drive their sessions from, and `workdir.access = "none"` in `lib/confinement.nix` withholds the project from all of them at once. `8 of 10 checks failed`, three of them in the control's own words

This is a proxy and is written down as one: it establishes that a control is *called*, not that the control is apt. The failure mode it exists for is forgetting one entirely, which is what happened to `check_j6_1` twice, and a proxy catches that. The suite-wide plant is what raises it above bookkeeping: it demonstrates the controls bite together, not merely that they are present.

**Measured before starting**, recorded under [`M5h`](research.md#m5h--every-refusal-check-has-a-control).

There are eight refusal checks — `check_r1` through `check_r6` and `check_r10` in the integration layer, `check_r7` in the unit layer — and **all eight already carry a control**, so the check passes as shipped and the only FAIL available is a planted one.

There is no mechanical marker on a control assertion anywhere in the suite, and inventing one would have meant rewriting eight checks to satisfy a ninth. What exists is a comment convention in two places: a paragraph in the header comment above a function, and a `# Control …` line inside its body. `workdir.access = "none"` is accepted by nono 0.74.0, which is what makes a suite-wide plant possible at all.

**Implementation.** `refusal_check_bodies` and `check_controls` join `scripts/checks/unit.sh`, beside `check_sc3`, which is the check they most resemble: both read the suite's own text and assert a property over it.

- **The marker is looked for inside the body, never in the header comment above it**, and the plant is what settled that. `check_r2`'s header paragraph — "Two controls, because the observable is a failure (D9)" — survived the deletion of both controls untouched, so a check that read the header would have been satisfied by prose describing arms that were no longer there.
- **Plant 1 is the argument for the check existing.** With both control arms deleted, comments and code together, the integration layer still reported `10 checks passed` — `check_r2` among them, asserting a refusal it could no longer tell from a session that never started. `check_controls` was the only thing that said so.
- **The proxy's limit is stated in the check's own header comment**, not left to be discovered: a control whose code was deleted while its comment stayed would pass. The check is worth having anyway, because the failure mode it guards against is forgetting one outright.
- **Plant 2's two survivors are the reason to run it rather than assume it.** `check_r6` passed because it starts no session at all — the pre-flight refuses before one exists, so the description cannot reach it. `check_r3` passed because its subject is the environment, and a denied workdir does not stop a program that reads its substrate and prints its own variables. Neither is an uncontrolled check that got away with it, and both are now written down as principled rather than left looking like gaps.
- **A denied workdir surfaces as exit 126**, with nono's summary still printing `No path denials were observed during this session` — the same unreliable self-report `M5b` found for a refused write, now for a refused exec.

The unit layer is `1 of 5 checks failed`, that one being the progress bar, and the whole suite is `1 of 18 checks failed`. `check_controls` is deliberately outside `check_sc3`'s scenario↔check bijection: it answers to a decision rather than to a scenario, and its name carries no scenario id.

**Checkpoint**: met. Every refusal in the spec except R7 and R8 is executable, and each one is known to fail for the reason it claims — R1 through R6 and R10 by their own planted violations, and all of them together by `M5h`'s suite-wide plant.

______________________________________________________________________

## M6 — State stays, and projects do not cross

### M6a — Agent state lands in the project (Status: IMPLEMENTED)

**Scenario**: Journey 2.1

**RED**: `check_j2_1` snapshots the fake `$HOME`, runs a session that writes history, and diffs.

- [x] Check written and seen to FAIL — and here, unlike everything in `M5`, the first FAIL was **real**: `the description names no environment-resolved root, so there is nothing for a session to relocate`. The scenario's own arm held as shipped; the two criteria below it did not, because every root arrived unset. The non-empty `$HOME` diff the criterion names is the planted FAIL, and what it took to produce one is recorded below
- [x] `stateVars` wired into `environment.set_vars`; the property `∀ (k,v) ∈ set_vars. v ⊑ "$WORKDIR"` is asserted over the agent table, not per variable — in `check_confinement_validates`, over `nix eval .#agents.<name>.stateVars`, with a value carrying no `/` treated as a setting rather than a location, so `DISABLE_AUTOUPDATER=1` passes while a host absolute path and a bare relative path both fail
- [x] Every root the agent will write to is covered, not only the ones the devShell happens to redirect. **Measurement corrected the criterion, and widened it**: not one root crossed the boundary, `TMPDIR` included, so "not only the ones the devShell redirects" turned out to mean *none of them*. Five keys were added, and the coverage assertion compares the session's set against the `XDG_*` names parsed out of the devShell hook — mirror against mirror — plus `XDG_STATE_HOME`, which the hook cannot export
- [x] The state root is redirected in the session's `set_vars` rather than in the shell hook, which is what makes it safe: the supervisor resolves its own protected state root from the ambient value before the child's environment applies, so the child can be moved without making `$WORKDIR` ungrantable ([D13](plan.md#d13)). Asserted by observation, not by assuming the two resolutions are independent — the child's own value is read out of a probe, and the supervisor's audit record is asserted present under the ambient root and absent under the project's
- [x] **Control**: the writes are found where they were redirected to, under `$WORKDIR`, so an agent that wrote nothing at all cannot pass as state landing in the project ([D9](plan.md#d9)). It **accumulates** rather than returning early, because the plant that breaks it also produces the leak, and a control that returns hides the louder finding
- [x] Violation planted (drop the state variable), seen to FAIL, reverted, recorded in plan.md — **twice, because the criterion as written cannot produce its own observable.** Dropping the variable alone fires the control and leaves the diff empty; the fallback has to be granted alongside it
- [x] Violation planted (redirect every root **except** `state`), seen to FAIL, reverted, recorded in plan.md — a per-root check is the only kind that bites here, since a single blanket variable leaves exactly this hole. It is inert at the integration layer and caught only at the component layer, which is the criterion's own point made executable

**Measured before starting**, in [`research.md` § `M6a`](research.md#m6a--agent-state-lands-in-the-project). Four things this task can be written against rather than discover.

The scenario already holds for `claude-code`, so the first criterion's FAIL has to be planted like every other in `M5`. `claude plugin list` through the entry point leaves the fake `$HOME` diff **empty** and lands `.agents/claude/.claude.json` plus a `backups/` copy inside the project. It needs no credentials and takes about a second, so no conversation has to be driven to produce a write.

**`D13`'s load-bearing assumption is true, and the observation the fourth criterion asks for is available in two arms.** With `set_vars.XDG_STATE_HOME = "$WORKDIR/.agents/state"` the session starts, `$WORKDIR` expands, the child writes there, no overlap is complained about, and the supervisor still writes its audit record under the ambient value. The shipped arm is the same run without the key.

**Inside a session the variable is `<unset>`, not host-valued.** `allow_vars` carries no `XDG_*` pattern, so a tool that honours XDG falls back to `$HOME/.local/state` and is denied there. The outcome `D13` predicts is right; the route is not. So the change is an addition to `set_vars` and nothing has to leave `allow_vars`.

**Two traps.** A probe written outside the granted workdir gives **exit 126** with no output, which is indistinguishable from the boundary working — `M5h`'s signature. And the identity file `.agents/git/config` will not appear in a run made from this repository's own confined session, because the wrapper's `git config --global --get` is denied `~/.gitconfig` by the outer sandbox and correctly writes nothing; that is the developing environment, not a defect.

**Measured once the task had started, and it reshaped the change.** A probe reported `TMPDIR`, `TMPPREFIX` and every `XDG_*` root arriving `<unset>`; all four `$HOME`-relative fallbacks denied; all five in-project targets writable; and **`/tmp` writable**, because it is among the 33 system paths in the floor. So the devShell's redirection stops at the boundary entirely, and the one root whose loss is not even a visible failure is `TMPDIR`: a tool falling back to `/tmp` writes outside the project silently, at a path two projects share. That is why `TMPDIR` is in the change rather than the state root going in alone.

**Implementation.**

- **The production change is five keys in `set_vars`** — `TMPDIR`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, each under `${w}` — and nothing else. **No directory is created for them**: a tool that does not create its own root failed under `$HOME` before and fails under the project now, so the change is a strict improvement, and a `mkdir` no check exercises is a helper the process forbids.
- **`check_j2_1` runs two sessions, because the scenario has two halves no single observable covers.** The first is the agent itself, `claude plugin list`, so the state under test is state the agent chose to write. The second is a probe, because the first cannot answer the third and fourth criteria — an agent that writes nowhere near a relocated root leaves it unobserved, and every root was measured arriving unset.
- **The root set is read out of the built description**, `jq '.environment.set_vars | keys[] | select(test("^XDG_|^TMPDIR$"))'`, with an anti-vacuity guard. Each root is asserted twice: the child's value equals the description's with `$WORKDIR` substituted, **and** the write succeeds. The first without the second is a variable pointing somewhere the session cannot use.
- **The two coverage assertions live at the component layer, and the plant is what proves they had to.** Dropping `XDG_STATE_HOME` leaves the integration layer reporting `11 checks passed`, because `check_j2_1` reads its root set out of the description and a dropped root shrinks both sides of its own comparison. Only a mirror against something *else* — the devShell hook — can see it. `XDG_STATE_HOME` is asserted separately from the parsed set, with its own message, because the hook does not export it and folding it in made the failure text claim otherwise.
- **The `$HOME`-diff arm needed two corrections before any plant could fire it**, both found by planting rather than by writing. An empty fake home gives the agent no fallback to write to, so a session that lost its relocation writes nowhere and the arm passes for the wrong reason; the fixture now plants a prior installation, which is also the more honest Given. And the leak the plant then produces is a **single file rewritten in place**, invisible to a snapshot of paths, so both snapshots carry size and mtime.
- **The plant the criterion names does not produce the observable the criterion names.** Dropping `CLAUDE_CONFIG_DIR` fires the control — the agent writes nowhere at all — and leaves the diff empty. The plant that fires both halves drops the variable **and** grants the fallback, which takes two grants and two flags: `--allow "$HOME/.claude"` plus `--allow-file "$HOME/.claude.json"`, because nono refuses a directory grant naming a regular file and `~/.claude.json` is a sibling of `~/.claude` rather than a child. Both plants are recorded, because the difference between them is the finding.
- **A harness that reverts by `git checkout` destroyed the GREEN once**, before it was committed, and the run that followed reported four coverage failures that had nothing to do with the plant. It is a false result that reads exactly like a true one. The harness backs up by copy and restores by copy, and the hazard is recorded in `research.md`.

The unit layer's progress bar went from 14 missing scenarios to 13, `j2_1` leaving and nothing else moving. The integration layer is `11 checks passed`, the component layer `3 checks passed`, the whole suite `1 of 19 checks failed` — that one the progress bar — and `nix flake check` is `all checks passed!`.

### M6b — Two concurrent projects share nothing (Status: IMPLEMENTED)

**Scenario**: Journey 3.1

**RED**: `check_j3_1` runs two sessions **genuinely concurrently**, not in sequence — spec Risk 16 is that ports and the shared state directory contend.

- [x] Check written and seen to FAIL — at the unit layer, `check_sc3`'s missing-scenario set going from 13 to 12 with `j3_1` leaving and nothing else moving, and at the integration layer under the two plants below. The property held as shipped, so there was no other RED to see, and the write-up says so rather than implying one
- [x] Both halves asserted, which together are FR-8: the other project directory is unchanged, and neither reach includes the other. The read-only plant is what establishes they are two assertions and not one — it fires the reach half and leaves every cross-write assertion green
- [x] **Control**: each session's write into its *own* checkout is present afterwards, so two sessions that both did nothing cannot pass as two sessions that did not interfere ([D9](plan.md#d9)). Two controls in fact: the agent pair's own state under `.agents`, and each probe's `OWN :: ok` before its `CROSS :: denied`
- [x] Violation planted (grant the sibling checkout), seen to FAIL, reverted, recorded in plan.md — twice, once read-write and once read-only, because the two fire different halves

**Measured before starting**, recorded under [`M6b`](research.md#m6b--two-concurrent-projects-share-nothing). Three things.

**Journey 3.1 already holds, run genuinely concurrently.** Two `git init`ed checkouts, one fake `$HOME`, one config root and **one** shared ambient `XDG_STATE_HOME` — the arrangement a consumer is actually in — both started with `&` and joined with `wait`. Both exited 0; each project gained only its own `.agents/claude/.claude.json` and a timestamped backup; each other's diff was empty in both directions; the fake `$HOME` diff was empty; neither session's stderr named the other's path; and each granted reach carried exactly one project, its own. So the only RED available here is a planted one, as with every task in `M5`.

**Risk 16's two premises come apart, and only one of them is real.** The shared supervisory state directory exists and is contended for — `$XDG_STATE_HOME/nono/audit/ledger.lock` is created, so nono guards the shared ledger rather than assuming one writer. The loopback port the risk also names was **not observed at all**: no port appears in either session's output and nothing matching `lock|contend|busy|port|address in use|conflict|retry` was printed by either. The check should assert the outcome the risk is about rather than instrument a port that may not exist.

**`check_j1_1`'s selection idiom does not carry over, and the correction is this task's first design decision.** Each session leaves **three** audit records, not one: `true` and `sh` — the pre-flight's enforceability probe and its companion, each carrying the 128 store paths and no workdir — and the agent itself, carrying 129. So "the one record whose `.command[0]` ends in `/bin/claude`" is two records once there are two sessions. A record carries no working directory either: its keys are `audit_attestation audit_event_count audit_integrity command ended executable_identity exit_code merkle_roots network_events session_id snapshot_count started tracked_paths`, with no `cwd`, `workdir` or `working_directory`. So a record cannot be attributed to a session by anything it carries, and selecting by the project path in `tracked_paths` is the obvious substitute — which the plant falsified. The correction is below.

**Implementation.** `check_j3_1` joins `scripts/checks/integration.sh`. No production change: the property holds as shipped, and this task adds only the check that says so.

- **Two rounds of two concurrent sessions, because FR-8's two halves have no single observable.** The agent pair answers "share no agent state", because the agent writes state of its own accord. It cannot answer "must not reach each other's project directory": `M6a`'s plant A measured an agent handed a grant it has no use for leaving the grant unexercised while its own writes stayed put. So a probe pair attempts the cross-project write the agent never would. Each round is started with `&` and joined with two separate `wait`s, so a pair where only one survived cannot read as a pair that did not interfere.
- **The two checkouts are siblings under a `work/` directory, not directly under the temporary root.** That is what lets the plant grant the parent of one working directory and reach the other project and nothing else. With the fake `$HOME` beside them the same grant would cover it and nono would refuse to start on deny-overlap, and the plant would prove nothing.
- **Selection is by the agent's own command, and the reason is the plant.** The first draft selected each session's audit record by the project path in `tracked_paths` and required exactly one per project. Under the read-write plant nono canonicalises `$WORKDIR/..` to the parent, so neither project is named in either record, the selection found 0, and the check returned early on its own bookkeeping — `expected exactly one session record naming alpha, found 0` — without ever reaching its subject. A plant naming the sibling exactly would have broken it the other way, finding 2. Selection is now `.command[0] | endswith("/bin/claude")` requiring exactly two, which no grant can move, and it runs **before** the probe round, which would otherwise make four.
- **The reach property is stated over the pair rather than per session**: each record must reach exactly one of the two checkouts, and the two must differ. Per session it could not be stated at all, since no field attributes a record to a session; over the pair, two sessions with indistinguishable reach is itself the failure, which is the thing FR-8 is about. An **ancestor** counts as reaching, because a grant containing a checkout is as bad as one naming it.
- **The cross-project write is confirmed absent from the host afterwards**, not merely reported denied from inside, for the reason `M5b` recorded: a denial reported inside the sandbox is the sandbox's own account of itself, and nono has been observed claiming no denials for a write it had just refused.
- **The read-only plant is why both halves are asserted.** Appending the parent to `filesystem.read` fires the reach assertion and leaves every cross-write assertion green: a read grant on a sibling checkout is a leak no write attempt can observe. Neither half implies the other, and that is measured rather than argued.
- **The read-write plant's collateral is worth naming**, because it says what a single line in a description can do: `check_j1_1` and `check_j8_2` fail on their reach set-equality with the repository's own parent added; `check_r5` starts no session at all; `check_r10` and `check_j2_1` exit `77`, because the granted parent overlaps nono's protected state root; and `check_r6` reports `the refusal does not say the canary was unwritable`, so an unstartable description is indistinguishable to the pre-flight check from an unenforceable host. The component layer passes throughout both plants, so neither is visible one layer down.
- A jq bug in the ancestor clause survived the first plant run because the plant still failed, on the other half. `.` rebinds after a `|`, so `($p | startswith(. + "/"))` compared `$p` against itself. Recorded in `research.md` with the `$(<file 2>/dev/null)` note beside it.

The integration layer is `12 checks passed`, run as `direnv exec . bash scripts/validate.sh --layer integration`, and the whole suite is `1 of 20 checks failed`, that one being the progress bar.

______________________________________________________________________

## M7 — Credentials

Gated on `M1b` and `M1g`. [D1](plan.md#d1) resolved to the branch where the real secret never enters the boundary, so no credential file is granted and the registry stays empty. This group lands **before** `M8` finishes, because [D14](plan.md#d14) makes `opencode` and `pi` draw their credential from the session `claude-code` authenticates — there is nothing for them to draw from until the arrangement below exists.

### M7a — A readable credential is a substitute (Status: IMPLEMENTED)

**Scenario**: Journey 4.1

**RED**: `check_j4_1` asserts every readable credential value matches the substitute form, using mock credentials.

- [x] Check written and seen to FAIL — on the vacuity control, `the session was handed no credential, so every readable value being a substitute holds vacuously`, which is the honest RED: there was no credential to be a substitute of yet
- [x] **Control**, and two of them, because either half could hold vacuously. The real value is in the supervisor's environment in the same run — which on a host with no keychain is what "authenticated once on the machine" is — and the routed name is asserted non-empty before its form is asserted. **The criterion's control had to be built differently than written**: the route overrides `allow_vars` for the name it claims, so the same canary is handed through under a name no service policy claims, and the same probe reads it and the same tree search finds it ([D9](plan.md#d9))
- [x] The credential service name is validated before a session starts, so a typo cannot yield a silently unauthenticated session (P9). **The criterion was written as "the wrapper validates it itself", and the measurement below withdraws that**: the command-line `--credential` form is silent, but a name in the description is refused with the list of available services, so the requirement is met by putting the arrangement in the description and never using the flag
- [x] SC-6 is asserted over the whole project directory rather than only the agent's own state: a value that authenticates from outside the boundary, at rest anywhere inside the checkout, fails the check. The search runs after an agent session has written real state into the project, and the control session demonstrates the same search finding a planted value
- [x] The live-rejection half is recorded in the coverage gap, not silently skipped — the entry was already there and is now narrowed by what was measured, rather than being added
- [x] The registry stays empty, and no `credential_key` is written at all, so nothing forces an entry. `check_sc1` re-run to prove it
- [x] Violation planted, seen to FAIL, reverted, recorded in plan.md. **Not the plant as written**: exposing the real value takes two edits, not one, because withdrawing the route alone leaves the name unset and adding the name alone is inert. Both were run, and the inert one is recorded as a result rather than dropped

**Measured before starting**, for the whole group, in [`research.md § M7`](research.md#m7--the-credential-surface-and-interception-measured-rather-than-reasoned). The surface is five top-level keys — `credential_capture`, `credential_providers`, `credential_routes`, `env_credentials` and its alias `secrets` — plus `network.credentials` and `network.custom_credentials`, which `M1b` discussed by name without recording that they sit under `network`. Three constraints bind what this task may write:

- `CustomCredentialDef` requires only `upstream`, but **`env_var` becomes required as soon as `credential_key` is a URI manager reference** — `op://`, `bw://`, `apple-password://`, `file://`, `cmd://` — and is derived only for `env://`. So the arrangement's shape is decided by which scheme the credential comes from, and `env://` is the one that needs no second field.
- `credential_key` is mutually exclusive with `auth`, `aws_auth` and `spiffe`.
- A bogus service name on the **command line** still exits 0 at 0.74.0, with nothing in either stream naming it, so that half of `M1b`'s finding survives.

**Measured for this task**, in [`research.md § M7a`](research.md#m7a--a-readable-credential-is-a-substitute). Five findings, each of which changes what this task builds:

- **The arrangement is one line**: `network.credentials = [ "anthropic" ]`, one of six service names nono ships a policy for. With the real value in the supervisor's environment the child reads a **64-lowercase-hex substitute** in `ANTHROPIC_API_KEY`, the banner says `net proxy`, and the canary appears in neither the child's environment, nor the resolved capability manifest, nor the project directory afterwards. No `custom_credentials`, no `credential_capture` and no `credential_providers` are needed, and the registry stays empty without a `credential_key` being written at all.
- **`credential_providers` cannot be used here**, which withdraws half of [D1](plan.md#d1). With a correct provider and route the base URL is mediated but the phantom does not exist until a token exchange has been captured, so the OAuth branch **cannot be exercised unattended** and a check written against it would assert the substitute property over an empty set. It cannot be mocked either, because `token_endpoints[].host` must be HTTPS.
- **A missing credential is loud and the session still starts** — `Credential not found for route 'anthropic' … Looked for env var 'ANTHROPIC_API_KEY' (not set)`, as both a warning block and a `credential_not_found` line in the capability banner. That is P9 arriving from the mechanism, and it is also the observable `M7c` needs. Its keychain advice is macOS-specific and misleading on Linux.
- **The substitute is per session**, so a value copied out of one session is not even the string the next session sees.
- **The route injects sixteen variables** — the credential pair `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL`, the five trust-bundle names, and nine proxy names — and `check_r3` fails the moment it ships. For a built-in service the names are nono's rather than ours and are not derivable from the description, and the session's capability manifest is unreadable from inside, so they must be written down — the one place here where the literal *is* the criterion, exactly as `PATH`, `BROWSER` and `NONO_CAP_FILE` already are in that check. The first arms of this measurement said *two*, because the probe printed only the names it had been told to look for; a full `env -0` diff, taken before the check was written, said sixteen.

**Implementation.**

- **The whole production change is two lines of nono configuration**: a `credentialServices` option on the agent table, `[ "anthropic" ]` for `claude-code`, and `network.credentials = a.credentialServices` in the description. Names rather than definitions, because the upstream, the injected header and the endpoint policy come from the mechanism's own policy for the six services it knows, and a name it does not know is refused before a session starts with the list of the ones it does — which is how the third criterion is met without the wrapper validating anything.
- **The RED was the vacuity control, and that is the honest one.** `check_j4_1` failed on `the session was handed no credential, so every readable value being a substitute holds vacuously` — not on the substitute's form, because there was no credential at all. Everything above it passed, so the failure also established that the probe *can* read a real credential out and the tree search *can* find one. At the unit layer `check_sc3`'s missing-scenario set went from 12 to 11, `j4_1` leaving and nothing else moving.
- **Four sessions, and each one earns its place.** A *control* session, which is the criterion's own control turned into something the route cannot defeat: the same canary handed through under `MOCK_UNROUTED_KEY`, a name no service policy claims, read out by the same probe and found by the same tree search — because the route overrides `allow_vars` for the name it *does* claim, so a same-name control cannot be built. A *live* session for the substitute form. An *agent* session, `plugin list` through the real entry point in the same project, so SC-6's search has real agent state to look through rather than only a probe's leavings. And a second live session, because the per-session property is a difference between two runs and nothing else observes it.
- **The substitute's form is asserted, not its inequality with the canary.** `^[0-9a-f]{64}$` is the assertion, because a value that merely differs from the real one — a truncation, say — can still authenticate. The canary's absence is asserted separately, over every crossed value rather than over the one name, and the carriers are named rather than printed so the suite's own output does not become the leak.
- **SC-6 is asserted over the whole project tree**, after the probe's own artifacts are removed, and the control session proves the same search finds a planted value. The plant that withdraws the route does **not** fire it: the real value crossed in the environment and nothing wrote it at rest. So the two halves are independent, and this task covers the at-rest half by a search whose only demonstrated failure mode is the control's.
- **`check_r3`'s control had to be rebuilt rather than repaired.** Its granted arm asserted that a host value crosses when `allow_vars` names it, using `ANTHROPIC_API_KEY` — the one name the route now overrides. The arm now grants two names and asserts both halves: the unclaimed one crosses with its host value, so default-deny is what withholds things; and the claimed one does not, so the route is not a filter a widening can get behind. Dropping the control instead would have lost the first property, and dropping the arm would have lost both.
- **`check_r3`'s R3 assertion needed no change at all**, because `M5c` wrote it against the canary's value rather than against the name being absent, stating at the time that M7 would plausibly set a credential under that very name.
- **The substitute is the session's proxy token.** `NONO_PROXY_TOKEN` carries the identical string, and so does the password in the injected `http_proxy`. So what the child holds is the ticket authenticating it to its own supervisor, handed over under the name a client expects a key in — which is why it is per session and why it stops working when the session ends.
- **A credential route switches TLS interception on**, with no `allow_domain` in the description at all: all five trust-bundle variables arrive set and the banner reads `net proxy`. [D12](plan.md#d12) is corrected, and `M7e`'s named plant must now withdraw the route as well or it will not bite.
- **The second plant is inert, and that is the result.** Granting the host name while leaving the route in place changes nothing — `13 checks passed` — which is the suite-level confirmation that a consumer's widening cannot get behind the route, and the reason the new assertion is falsifiable only by removing the route. No component-layer assertion was added: `check_j4_1` asserts the substitute's form directly rather than reading the route out of the description, so a withdrawn route is caught where it is, and a mirror would be a third copy.
- The leak registry is untouched and still empty, which `check_sc1` re-ran and confirmed. The live-rejection half was already a coverage-gap entry in the plan and stays one, narrowed by the observation that the substitute is a per-session proxy token the provider has never seen.

The full suite is `1 of 21 checks failed`, the one being `check_sc3`, the deliberate progress bar, now at 11 missing scenarios. `nix flake check` passes.

### M7b — Authenticating once serves every project, and every agent (Status: IMPLEMENTED)

**Scenario**: Journey 5.1

Two axes in one scenario. Across projects is the original claim; across agents is [D14](plan.md#d14), and it is not a convenience — FR-6 and FR-3 together **exclude** the alternative, because letting `opencode` and `pi` read `claude-code`'s credential store would put a credential that works outside the boundary inside it, on a grant resting on convenience rather than structural impossibility.

**RED**: `check_j5_1` puts one credential in the calling environment, then starts a session per checkout and per agent and asserts each is handed a substitute of its own with no login.

- [x] Check written and seen to FAIL
- [x] Every agent in the table declares the service in its own entry, and each session is minted a substitute of its own — so no agent reads another's store, and the axis is asserted as a property over the table rather than against a named second agent. **The criterion was written as "`credential_providers` captures the token flow and `credential_routes` exposes it", and the measurement below withdraws that**, as `M7a` withdrew the same mechanism from [D1](plan.md#d1)
- [x] **Control**: a third identity that has *not* been authenticated must **not** work in the same session, so a route that authenticates everything cannot pass as a route that authenticates the right thing ([D9](plan.md#d9))
- [x] The tension with FR-4 is resolved explicitly: credentials are machine-scoped, all other agent state is project-scoped, and the plan says which is which
- [x] Violation planted (empty one agent's `credentialServices`), seen to FAIL, reverted, recorded in plan.md

**Measured before starting**, in [`research.md § M7b`](research.md#m7b--authenticating-once-serves-every-project-and-every-agent). Five findings, each of which changes the task.

**Both axes already hold, so the only RED available at this layer is a planted one.** Two unrelated checkouts and two descriptions differing only in `meta.name`, one credential in the supervisor's environment: three sessions, three exits of 0, three **distinct** 64-hex substitutes, the real value absent from every one, no `credential_not_found` warning anywhere, and each session's audit record reaching only its own project.

**Across agents holds by a simpler route than `D14` described, and the decision is corrected rather than worked around.** There is no authenticating agent and no dependency between agents: each declares the same service name in its own table entry and the supervisor mints it an independent substitute. That is why the second criterion is rewritten above, and why the plant is emptying an agent's `credentialServices` rather than removing a `credential_routes` entry that does not exist.

**The control is a single session's observation.** With `anthropic` and `github` both declared and only `ANTHROPIC_API_KEY` set, `ANTHROPIC_API_KEY` arrives as 64 hex while `GITHUB_TOKEN` does not arrive at all, and the warning block names `github` by itself. `github` is the identity to use because it is one of only three built-in services that name an environment variable — `openai`, `gemini` and `google-ai` name none, so nothing in the calling environment can authenticate them at 0.74.0.

**The across-agents axis is written as a property over `builtins.attrNames agents`, not against a second agent.** Only `claude-code` is in the table until `M8`, so a check naming a second agent would either block this task on `M8` or assert against a stand-in description that proves nothing about the table. The property grows on its own when `M8` lands and needs no edit here.

**The layer moves from e2e to integration, and the reason is that nothing logs in any more.** `e2e` was chosen when authenticating meant a live OAuth exchange needing a real account. Authentication is now a variable in the calling environment, both axes were measured unattended above, and there is no `scripts/checks/e2e.sh` for the check to live in. Recorded in the plan's test-strategy row.

**Implementation.**

- **The production diff is empty**, and that is the result rather than a shortfall: `lib/` and `flake.nix` are byte-identical before and after, and the whole task is `check_j5_1`. `M7a`'s two lines of `credentialServices` already satisfied both axes, which is what measuring first established; adding a mechanism here would have been adding one for a scenario that already held.
- **The RED is therefore the planted one, and it bit in four places at once**: both project arms of the emptied agent, the count of sessions handed a credential against the size of the table, and the control's positive half. Four independent messages rather than one, which is what the count assertion and the control's positive half are for.
- **The sessions are the product of the agent table and two sibling checkouts** — two today, six when `M8` lands, with no edit here. One `$HOME` and one `XDG_STATE_HOME` for every arm, because a login that served only the session it was made in would still pass a check that gave each arm a machine of its own.
- **Distinctness is asserted over every session at once**, pairwise across the whole product rather than between two named arms, so the across-projects and across-agents axes are one assertion instead of two. A shared substitute would be machine-scoped state *inside* the boundary, which is exactly what the plan's new scope table says must not exist.
- **The control gained a positive half the measurement did not have.** Research observed `GITHUB_TOKEN` absent and the warning naming `github`; the check also asserts that the *authenticated* identity still arrives as 64 hex in that same session. Without it, a control description that broke the route outright would show the same absence and be read as a refusal.
- **The `credential_not_found` grep names the service** rather than matching the warning in general. FR-7 is about the identity this machine authenticated, so an `M8` agent that declares a service nobody has a credential for must not fail this check — and the control depends on that same warning firing for `github`, so a blanket match would make the two assertions contradict each other.
- **`local -a` leaves an array unset, and `${#arr[@]}` on an unset name is an unbound-variable error under `set -u`.** The plant run is what found it, on the arms that fail before appending — so the first thing the planted violation proved was that the failure path runs at all. The two accumulator arrays are assigned empty rather than only declared.
- `check_r3`'s `routed` list is untouched, because no new service is declared. It grows in `M8`, per the note above this section.

The full suite is `1 of 22 checks failed`, the one being `check_sc3`, the deliberate progress bar, now at 10 missing scenarios — `j5_1` leaving and nothing else moving. `nix flake check` passes. `plan.md` gained the machine/session/project scope table that resolves the FR-4 tension, and Journey 5 left the live-OAuth coverage gap, which now belongs to `Rep3` alone.

### M7c — Authentication failure is not a denial (Status: IMPLEMENTED)

**Scenario**: R8

**RED**: `check_r8` invalidates the stored substitute and makes a request.

- [x] Check written and seen to FAIL
- [x] FR-16: the assertion is that the two messages **differ** and that the authentication one is identifiable — not that upstream emits a particular string, which is not ours to demand. That difference is itself the control: two identical messages fail, and so does one message with nothing to compare it to
- [x] Violation planted (empty `credentialServices`, so no route crosses), seen to FAIL, reverted, recorded in plan.md

**Measured before starting** ([`research.md § M7c`](research.md#m7c--a-stale-substitute-answers-differently-from-a-denied-path)), because the scenario's Given had two readings and only one of them is checkable unattended.

- **A substitute that is not the session's own is answered locally.** The route replies `401 Unauthorized` with none of the upstream's headers on it, so the arm needs no provider, no network beyond the loopback port the session already has, and nobody else's rate limit. The other reading — the session's *own* substitute, forwarded and rejected — carries `server: cloudflare` and `authentication_error` back, which is the real thing and leaves the machine. It is a coverage gap in `plan.md` rather than an arm.
- **A missing credential is a third answer again**, `503`, not `401`. That is what makes the second session a control worth running rather than a restatement.
- **The environment does not carry the denial target in.** `allow_vars` drops anything the description did not name, so the first shape of the probe read `/nonexistent` and failed for the wrong reason. The path arrives as an argument, as in `check_r1`.

**Implementation.**

- **The production diff is empty again.** Both messages already exist and already differ; the task is the check, and the only knob that changes either of them is the agent table's own `credentialServices`.
- **The assertion is the status *family*, `401` or `407`**, which is HTTP's vocabulary for "who you are was not accepted", not this route's phrasing. `{"error":"Unauthorized"}` is deliberately not matched — a version bump that reworded the body must not turn FR-16 red.
- **Distinguishability is asserted both ways round**: the authentication message must not read as a denial, and the denial must not read as an authentication failure. One direction alone would pass a pair where one message contained both vocabularies.
- **Three controls** (D9), because two of the three observables are failures: an in-project read carrying a per-run canary, so a session that died at startup cannot pass; the denial target read once from outside the boundary first; and the credential-less second session.
- **The planted RED bit in one place**, `check_r8` reporting that the session was handed no provider route. The control arm stays quiet under the plant, which is correct — it asserts an *absence* of the authentication family, and a session with no route has none.

The full suite is `1 of 23 checks failed`, the one being `check_sc3`, the deliberate progress bar, now at 9 missing scenarios.

### M7d — Authenticating twice is harmless (Status: IMPLEMENTED)

**Scenario**: Rep3

**RED**: `check_rep3` authenticates twice and compares the resulting state.

- [x] Check written and seen to FAIL
- [x] **Control**: the state compared is non-empty and contains the captured credential, so two absent states cannot pass as two indistinguishable ones ([D9](plan.md#d9))
- [x] Violation planted (authentication records the session it ran in), seen to FAIL, reverted, recorded in plan.md

**Measured before starting** ([`research.md § M7d`](research.md#m7d--what-a-second-authentication-changes-and-what-it-does-not)). Two authentications in one project, each the entry point followed by an environment dump, with a different canary in the calling environment each time.

- **The entry point writes one file, `.agents/git/config`, and writes it identically both times.** `claude --version` creates no agent configuration at all, and the fake `$HOME` gains nothing. So the at-rest half of the state is already indistinguishable, by sha256.
- **Five values are session-scoped and nothing else varies**, out of 42 crossed entries: the substitute, the loopback authority, the interception session directory, the browser shim directory and the capability file. Each is a property of a session rather than of an authentication, so they are masked and the rest compared.
- **The state root cannot be in the comparison.** [D13](plan.md#d13) has nono append an audit record and a session directory per session, which is the feature working.

**Implementation.** The production diff is empty again; the task is the check, plus two file-level helpers, `project_state_manifest` and `env_dump_value`.

- **"Authenticate again" is the value supplied again**, deliberately a *different* one. `M7b` established that nothing logs in, so repeating the login is repeating the supply — and a real second login would mint a new token, so using the same canary twice would mask exactly the dependence the scenario asks about.
- **Each authentication is observed twice**, once at rest and once in the environment, because the two halves of the state are not readable from a single vantage point.
- **The whole environment is compared**, not a credential-shaped subset: the scenario does not get to choose which variables count. What makes that tractable is that each mask is a long unique string taken from that session's own dump, never a fragment like a bare port.
- **The at-rest half is content-addressed** — `find` piped through `sha256sum` — so a file rewritten with identical bytes is the same state, and the check's own probe directory is pruned because [`research.md § M7b`](research.md#m7b--authenticating-once-serves-every-project-and-every-agent) requires it to sit inside the granted workdir.
- **The control is that both halves are non-empty in the right way**: each normalized environment must carry the exact line `ANTHROPIC_API_KEY=<substitute>`, and each manifest must carry `./.agents/git/config`. A guard on the two raw substitutes being different keeps the masking from being a way to erase the difference rather than normalize it.
- **The planted RED bit in one place**, the at-rest half. A file written under the project cannot show up in a crossed environment — which is the argument for asserting both halves rather than either alone.

The full suite is `1 of 24 checks failed`, the one being `check_sc3`, the deliberate progress bar, now at 8 missing scenarios.

### M7e — The toolchain survives interception (Status: IMPLEMENTED)

**Scenario**: Journey 6.1

Shaped by `M1c`, and rewritten twice after the first two shapes were found to prove nothing. Interception is **per-destination and off by default** ([D12](plan.md#d12)): a plain-string destination is tunnelled untouched, and only a destination asked for in the form that inspects it causes the five trust-bundle variables to be exported. So an ordinary exchange succeeding is not evidence: what an unintercepted tool does depends on whether the host's own trust store is reachable from inside the substrate, which is a property of the machine rather than of the feature. Only the *difference* between trusting and not trusting is evidence.

**RED**: `check_j6_1` in three arms, per [plan.md § check_j6_1](plan.md#check_j6_1-in-three-arms).

- [x] Arm 1, the mechanism engaged: `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE` and `GIT_SSL_CAINFO` are set in the child, and the file they name exists and parses as a certificate (FR-17)
- [x] Arm 2, the exchange did its work: the output is matched as a **shape** rather than pinned to a value
- [x] Arm 3, the negative control, in the same session: repeat with the trust bundle pointed at `/dev/null` and require failure with a certificate error
- [x] Arm 3 is **permanent** and lives inside the check, not planted and reverted, because the property under test *is* a difference — removing it would be a regression rather than a plant, which is why it is deliberately absent from the planted-violations table
- [x] Violation planted (empty `credentialServices`, so the description asks for nothing to be inspected — the plain-string `allow_domain` this criterion first named does not exist here), seen to FAIL **on arm 1**, reverted, recorded in plan.md

The exchange is credential-free and no requirement asks otherwise: `M1c` established that every store a credential could come from sits in a deny group the mechanism marks `required`, and authenticating the version-control toolchain is out of scope. FR-17 is about trust in the inspecting authority, and that is all this checks.

**Measured before starting** ([`research.md § M7`](research.md#m7--the-credential-surface-and-interception-measured-rather-than-reasoned)). Four things, all against the shipped description with one `jq` edit between arms.

The two arms differ exactly as `D12` predicts. A plain-string `allow_domain` entry leaves all five variables `<unset>`; an object entry — `{"domain": …, "endpoints": [{"method": …, "path": …}]}`, both endpoint fields **singular** — sets all five to the same path. So **the planted violation is already known to bite arm 1**, and arm 1 asserts a difference rather than restating the description.

There is a second observable for arm 1, independent of the child's environment: the capability banner's network line reads `net outbound allowed` for a tunnel and **`net proxy`** for an inspected destination. Worth asserting alongside the five variables, because a change in how nono exports them would otherwise take arm 1 down with it.

**The file is readable from inside, which the criterion needed and its location made doubtful.** The bundle is at `$XDG_STATE_HOME/nono/sessions/intercept-<pid>-<n>/intercept-ca.pem`, outside the project by [D13](plan.md#d13)'s design — yet the session reads it and it contains `BEGIN CERTIFICATE`. And the granted reach and the audit record's `tracked_paths` gain **nothing** but the project, so interception widens no reach and `check_j1_1` and `check_sc1` need no exception. The directory is deleted when the session ends, so arm 1 must read the bundle from inside rather than inspect it afterwards.

A malformed `allow_domain` arm refuses to start — `Profile parse error: data did not match any variant of untagged enum AllowDomainEntry`, exit 1 — so getting the endpoint shape subtly wrong cannot produce a passing check.

**Implementation.** No production change: the shipped description already asks for inspection, and the whole task is the check ([`research.md § M7e`](research.md#m7e--the-toolchain-survives-interception-and-nothing-else-would-carry-it)).

`check_j6_1` runs one session and writes one probe into the granted workdir. The probe records the five variables, counts `BEGIN`/`END CERTIFICATE` in the bundle in pure bash — the intercept directory is deleted at session end, so the counting has to happen while the session is alive — and then runs `git ls-remote` twice against the same remote, once as the session was handed it and once with all five variables pointed at `/dev/null`. `git` comes out of the substrate, and it is the only ordinary tool in `sessionTools` that speaks HTTPS.

Three things the task notes above did not predict.

**The credential route is the switch.** `lib/confinement.nix` names no `allow_domain` at all, so the plain-string plant this task planned for has nothing to act on. Declaring `anthropic` is by itself enough to set all five variables and take the banner to `net proxy`, which means every session this environment ships is an intercepted one and FR-17 binds it today rather than conditionally.

**`ca_env_vars` cannot withdraw trust.** Two attempts to plant through it failed. `[ ]` means the defaults, and a non-empty list means the defaults *plus* the names given — measured, after the built artefact was inspected to confirm the edit had landed rather than assuming the check was blind. Good for the guarantee, useless as a plant.

**The host trust store does not rescue an unintercepted exchange here.** On NixOS `/etc/ssl/certs/ca-certificates.crt` resolves into `/nix/store`, and that path is not in the substrate's closure, so an unintercepted `git` fails with `unable to get local issuer certificate (20)` and pointing the variables at the system bundle fails the same way as pointing them at `/dev/null`. `M1c`'s claim that the real certificate "validates fine" is corrected in place. The three-arm design survives the correction, because which way that arm falls is a property of the host.

The plant that was used is an empty `credentialServices`, and it bit in **four** places: no trust variables, `net outbound allowed`, an unreadable authority, and arm 2's exchange failing on the certificate. Arm 3 stayed quiet, correctly — it asserts a failure and the exchange fails either way, which is precisely why arm 2 is named as its positive control.

"Parses as a certificate" is discharged in two halves, because the substrate carries no `openssl`: structurally at arm 1, where the delimiters must balance and there must be at least one, and semantically at arms 2 and 3, where a real TLS exchange either accepts the authority or reports that it cannot.

The check needs the network, which no other check does. That is recorded in the plan's test-strategy row rather than left for a stranger to discover from a timeout.

The full suite is `1 of 25 checks failed`, the one being `check_sc3`, the deliberate progress bar, now at 7 missing scenarios.

______________________________________________________________________

### M7f — A commit needs no key (Status: IMPLEMENTED)

**Scenario**: Journey 6.2, R11

Unsigned commits are the default, and a key that is genuinely needed arrives from an agent or a secret service rather than from a granted directory ([D16](plan.md#d16)). Not hypothetical: every commit made while implementing this feature failed exactly this way — `M3c`, `M3d`, `M4a` and the `M4b` precondition commit, four for four — `gpg` denied its temporary file beneath `$HOME/.gnupg`, and `git` then reporting `fatal: failed to write commit object`. It fires on the first commit, so a consumer meets it immediately.

**Which half of this task those failures belong to has been measured, and it is the half FR-24 configures away.** The demand comes from the *global* `~/.gitconfig`; under [D11](plan.md#d11)'s redirection the setting is not present anywhere, and a commit in a throwaway checkout then succeeded unsigned with no override. So `check_j6_2` is expected to pass on the mechanism already shipped in `lib/confinement.nix`, and the RED it starts from is the absence of the check rather than a missing capability. `check_r11` correspondingly **must set its demand in the checkout's own `.git/config`** — a demand set globally is erased by `GIT_CONFIG_GLOBAL`, so a check that plants it there would assert nothing and still pass. That is what makes the criterion's wording *a checkout whose own configuration demands a signature* load-bearing, and it is the first thing to get right when this task starts.

**The route a consumer who wants signatures would take is a first-class credential type, not something that would have to be built.** `CommandCredentialConfig` carries a `local-socket` kind whose `path` is documented as "commonly `$SSH_AUTH_SOCK` for SSH agent", with `mode: connect` ([research](research.md#m7--the-credential-surface-and-interception-measured-rather-than-reasoned)). That is worth stating in this task's closing note rather than leaving `D16`'s forwarded socket sounding hypothetical — it is still a new feature number, but it is a configuration rather than an invention.

**RED**: `check_j6_2` and `check_r11`, in one session, each the other's control ([D9](plan.md#d9)).

- [x] `check_j6_2`: a commit made inside the session exists afterwards, carries no signature, and the configuration this environment wrote is confirmed not to ask for one (FR-24)
- [x] `check_r11`: in a checkout whose *own* configuration demands a signature, the commit fails, the message names the key material that could not be reached, and no commit object was created
- [x] The two run in the same session and stand as each other's control — `check_r11`'s failure is attributable to the demand only because `check_j6_2` committed successfully beside it
- [x] Neither check grants a key store, and this task leaves the leak registry unchanged; `check_sc1` is re-run to prove it
- [x] `bash scripts/validate.sh --layer integration` passes
- [x] Violations planted for both checks, seen to FAIL, reverted, recorded in plan.md

Where a consumer does want signatures, the route is the forwarded socket [D16](plan.md#d16) names, supplied at invocation under FR-15. This task does not build that route: it fixes the default and makes the refusal legible. Building it is a new feature number, not an extension of this one.

**Measured before starting.** Recorded in [research.md § M7f](research.md#m7f--a-commit-needs-no-key-and-the-demand-for-one-survives-while-the-key-does-not). The prediction above held: an ordinary commit in a session succeeds unsigned with no override — exit 0, a 40-hex object, zero `gpgsig` headers, `%G?` reporting `N` — and `git config --get commit.gpgsign` exits 1, so the file this environment writes does not ask for a signature. A demand set in the checkout's own `.git/config` refuses at exit 128 with nothing left behind. Two things the task text did not predict. The **ssh signing format is unusable as the subject**: it refuses too, but its message is `could not create temporary file: No such file or directory`, which names no key material and reads as the checkout being unwritable — the exact confusion R11 exists to prevent — so the check demands a signature the ordinary way. And `gpg` is denied at **execve**, not at `openat`, so `trace_denials` never sees it; that is not a hole, because J6.2's third `Then` under Landlock *is* an empty denial set.

**Implementation.** The production diff is empty again: the mechanism was already shipped in `lib/confinement.nix`, and the whole task is the two checks plus a helper.

`commit_session` runs both arms in **one** session and hands each check the same output, which is what makes them each other's control rather than two checks that happen to agree. The plain arm's success is what attributes the demand arm's refusal to the demand; the demand arm's refusal is what keeps the plain arm's empty denial set from being vacuous — a session that reached nowhere would also have denied nothing. `check_r11` asserts its control *first* and returns immediately if it fails, because everything below it is about a failure.

The message is matched for what it **names** — `sign` together with `gpg|key` — rather than for a string one toolchain version emits. A host with no signing program at all says `cannot run gpg` instead of `cannot exec 'gpg': Permission denied`; both name the material and both say the data went unsigned, and that is the property FR-16 asks for.

Both plants bit. `commit.gpgsign = true` in the file the entry point writes broke the default keyless commit, and it also fired `check_r11`'s control in the control's own words — a refusal proves nothing once the ordinary commit fails beside it, which is the control working rather than collateral. The plan's plant for `check_r11` was **not realisable**: granting a key store cannot make the demanded signature succeed when there is no `gpg` in the substrate at all. The plant that does bite is the temptation FR-24 has to resist — `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` in `set_vars` forcing `commit.gpgsign = false`, which outranks even the checkout's own file, and the commit then succeeds. The row is rewritten in [plan.md](plan.md#planted-violations) with that reason, as `M7e`'s was.

The leak registry is untouched, and `check_sc1` passes. The suite reports `1 of 27 checks failed`, the failure being `check_sc3`'s deliberate progress bar, now down to five missing scenarios: `j7_1 j8_1 r9 rep1 rep2`. `nix flake check` passes.

______________________________________________________________________

## M8 — The remaining agents

`claude-code` is already confined, from `M4b`. What is left is its own awkward corners, then the other two agents. The order is `claude-code` → `opencode` → `pi`, and `M7b` withdrew the reason [D14](plan.md#d14) gave for it: no agent takes its credential from another, so nothing here depends on `claude-code` beyond it being the one already confined and therefore the cheapest thing to generalise from.

Each of the two new agents needs `credentialServices` in its table entry, and declaring a service adds two names to what crosses into every session of that agent — `<SERVICE>_API_KEY` or `<SERVICE>_TOKEN`, and `<SERVICE>_BASE_URL`. `check_r3`'s `routed` list is where those are written down, per [research.md § M7b](research.md#m7b--authenticating-once-serves-every-project-and-every-agent), so a service declared without that list growing fails it.

The consumer's own authoring surface (FR-25) closes this group rather than opening it. It has to be enumerated per agent before it can be granted for any, so it depends on all three being confined — which is also why `M5f` keeps only the undeclared half, the half that needs no mechanism at all.

### M8a — Extract `mkEntryPoint` (Status: IMPLEMENTED)

A refactor, and therefore its own task per P6. No behaviour changes — and, as it turned out, no refactor either.

**Scenario**: none — refactor.

- [x] The reference agent's built description captured before, with `nix build --no-link --print-out-paths .#confinement-claude-code` and `jq -S`. The criterion first named `nix eval --json .#confinement.claude-code`, which does not exist: a description is a built artefact, not an evaluated attribute
- [x] The wrapper generalised — **already was**. `lib/confined-agent.nix` has taken `name` and resolved it as `agents.${name} or (throw …)` since its first commit at `M4b`, so there was no `claude-code`-specific wrapper to extract from. The code calls it `mkEntryPoint` rather than the plan's `mkConfinedAgent`; [plan.md](plan.md) has been corrected to the name the code uses
- [x] The same capture after; **the diff is empty**. With an empty production diff this is a tautology, so it is recorded as bookkeeping rather than as evidence
- [x] The generality the refactor was for, measured rather than argued: a second agent added to `lib/agents.nix` and **nothing else touched** produced a description the mechanism validates, a substrate, and an entry point under the agent's own command name, while the reference agent's description kept the same store path. Reverted afterwards; the table below is in [research.md § M8a](research.md#m8a--the-refactor-that-had-already-happened)
- [x] `bash scripts/validate.sh` passes unchanged — `1 of 27 checks failed`, the failure being `check_sc3`'s deliberate progress bar

**Implementation.** The production diff is empty, and this time that is the whole finding rather than a side effect: the task planned an extraction that `M4b` had already performed. `git show 7e3aea8:lib/confined-agent.nix` settles it — the file was parameterised over `name` on the day it was written, because `M4b` needed the agent table to be the only place an agent is named.

That leaves the criterion's own evidence worthless, since a diff across no change is empty by arithmetic. The replacement is the experiment the refactor was supposed to make possible: add an entry to the table and see whether a name the pipeline has never seen generates. It does — `nix build` produced `confinement-opencode`, `substrate-opencode` and `opencode` from one table entry, `nono profile validate` returned `Result: valid` on the generated description, the new agent's own `stateVars` appeared in `set_vars` beside the shared ones, and `confinement-claude-code` resolved to the identical store path it had before the second agent existed. That last one is what the empty diff was reaching for and could not express: adding an agent disturbs nothing about the agent already there.

One observation banked for the rest of the group. Every integration check and three component checks hardcode `agent=claude-code`, which is right for a reference case but means the suite does not start exercising a second agent merely because the table grew. `check_j5_1` is the only check that derives its subjects from `builtins.attrNames agents`. `M8c` and `M8d` decide per property which of the others should follow it.

### M8b — `claude-code`'s subagent and lock fallbacks (Status: IMPLEMENTED)

**Scenario**: Journey 2.1 extended — spec Risk 12: `CLAUDE_CONFIG_DIR` has documented fallbacks in subagent and lock paths, and `M1g` counted thirteen candidate variables rather than one.

- [x] `check_j2_1` extended to exercise a **subagent** run, not only a plain session
- [x] Every variable `M1g` found to govern something is set, and the ten it found inert stay **unset** — measured again through the subagent and background paths, where they are still inert, and setting one turned out not to be free
- [x] Any surviving fallback path is either confined by other means or becomes a registry entry with both justification fields — every one resolves under `$HOME`, which the description grants nothing of, so it is the first branch, and the plant proves it rather than arguing it
- [x] Seen to FAIL before the fix

**Measured before starting.** Recorded in [research.md § M8b](research.md#m8b--the-subagent-and-lock-paths-and-why-the-background-service-stays-refused). Three findings changed the shape of the task.

The first is that a subagent path exists that this suite can drive unattended: `claude agents --json` needs neither a credential nor a terminal, and `claude --bg '<task>' </dev/null` is the real spawn. The second is that the background service listens on a socket under `/tmp`, at a path the payload hardcodes and derives as `sha256(configRoot)[0:8]`, so no relocation variable moves it — the session is denied the `bind` and the `connect` and times out. Granting it would mean a recursively writable directory outside the project for a daemon that outlives the session, so it stays refused and is recorded in the handbook as a limitation. The third is that `M1g`'s "the cost of setting a variable that governs nothing is zero" is false: `CLAUDE_JOB_DIR` is an *output* whose basename claude reads back as a job identity, and `CLAUDE_SECURESTORAGE_CONFIG_DIR` set to the empty string falls back to `$HOME/.claude` while unset uses the relocated root. The ten inert variables therefore stay unset, and the criterion's "documented but absent from the binary" half does not arise here — all thirteen are present in 2.1.237, which was `pi`'s case in `M1d`, not claude's.

**Implementation.** The production diff is empty for the third time in this feature. The task was framed as "set the rest of the variables", and the measurement withdrew the reason to; what it left is a check that reaches the paths the variables were supposed to protect.

`check_j2_1` gained two invocations between the `plugin list` arm and the control, so that the existing `$HOME` before-and-after diff covers all three without being rewritten. `agents --json --all` must exit 0 and answer with a JSON array — taken from the first line that opens one, because the supervisor's own `Credential not found` warning shares the stream and treating it as part of the answer failed a working session on the first run. The `--bg` spawn's exit status is deliberately **not** asserted, with the reason in a comment: the socket is refused today, and pinning either outcome would break the check the day the mediation stops being recursive. What is asserted is that the attempt left `daemon*` entries under the relocated root, which is the anti-vacuity guard — a spawn that never started would leave none.

The plant is the two-part one [plan.md](plan.md#planted-violations) already records for this check, and it bit in **three** places: the new background arm first (`asking for a background agent left no trace under the relocated root`), then the control, then the home diff — which named `.claude/daemon/control.key`, `.claude/daemon.log`, `.claude/jobs` and two telemetry files, the daemon state escaping to the home directory rather than staying in the project. That is exactly the fallback spec Risk 12 describes, caught by the arm this task added. Reverted; suite back to `1 of 27 checks failed`, the deliberate `check_sc3` progress bar, and `nix flake check` passes.

Two stale sentences were corrected in place while here: research.md's "the four `XDG_*` roots stay out of `set_vars`", which `M6a` contradicted, and plan.md's sketch comment promising that `M8b` would set the remaining ten.

### M8c — `opencode` (Status: IMPLEMENTED)

**Scenario**: Journey 2.1 for `opencode`.

- [x] **No variable of its own is needed, and the criterion asking for one had nothing to ask for.** Eight of the nine roots derive from the four `XDG_*` names plus `TMPDIR`, which `M6a` already places under the working directory; the ninth *is* `$HOME`, which no variable can move. None of the 84 `OPENCODE_*` names in the binary relocates a root. The one variable the entry does set, `OPENCODE_DISABLE_AUTOUPDATE`, is not a relocation at all
- [x] `opencode debug paths` is the observable, and every root it reports but `home` is asserted under `$WORKDIR`, from the agent's own answer rather than from a list of variables. `home` is asserted to lie **outside** the project instead, because it is `$HOME`, and the session's denial is what keeps that honest
- [x] It takes its credential from the mediated route, and no grant on `claude-code`'s state is added to make it work ([D14](plan.md#d14)) — `opencode providers list` names `ANTHROPIC_API_KEY` under its `Environment` block while reporting `0 credentials` in its store, and the two are asserted separately
- [x] Seen to FAIL before the fix — two plants against `check_opencode`, and a third on the second agent's `stateVars` proving the generalised component check reaches it. All three recorded in [plan.md](plan.md#planted-violations)

**Measured before starting.** Both of the premises this task was written on are false, in the same direction as `M8a`'s and `M8b`'s.

- `opencode`'s base URL is **not** only a config key. The agent reads `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` straight out of its environment, with the config key winning where it is set and the environment as the documented fallback — and that pair is exactly what the mediated route injects. So the entry declares `credentialServices = [ "anthropic" ]` and this environment writes no configuration file. `check_r3`'s routed list does not grow, because no new service is named.
- Reading the binary was recorded as yielding nothing. It yields 84 distinct `OPENCODE_*` names — and not one of them moves a root. The conclusion survives; the reason for it was wrong.
- Details in [research.md § M8c](research.md#m8c--opencode-needs-no-variable-of-its-own-and-takes-its-credential-from-the-environment).

**Implementation.** The production diff is one table entry: `opencode` in `lib/agents.nix`, with `groups = [ ]`, `credentialServices = [ "anthropic" ]` and a single `stateVars` value. Everything else the agent needs was already there, which the flake confirmed by generating a description, a substrate and an entry point for it with no other edit.

Two checks were involved and only one is new.

- `check_opencode` at the integration layer, deliberately named outside the `check_(j<n>_<m>|r<n>|rep<n>)` pattern `check_sc3` scans, because Journey 2.1 already has `check_j2_1` and a second check claiming the same scenario would break the bijection rather than strengthen it. One session through the real entry point: the roots arm, the credential arm, a control that the project gained state, and the `$HOME` before-and-after diff.
- `check_state_vars` was written at the unit layer and then **deleted**. `check_confinement_validates` already made that assertion, with the same separator rule and the same `DISABLE_AUTOUPDATER=1` example — but named one agent, so the plan's description of it as a property over the agent table was drift. The fix was to make the description true: it now loops `builtins.attrNames agents` and names the agent in every failure. That is the whole of `M8c`'s coverage for the second agent at that layer, and adding a second copy would have been the third copy AGENTS.md forbids.

Two other checks needed no edit and cover `opencode` anyway. `check_j5_1` derives its subjects from the agent table, so it now runs two checkouts against two agents and asserts four pairwise-distinct substitutes. `check_confinement_validates` covers any entry the moment it lands.

The second plant is worth recording for its surprise. Removing a root's relocation does not make `opencode` write to `$HOME` and get caught by the diff — it makes `opencode` die with `EACCES` before it can answer, because the fallback root is denied. For this agent relocation is load-bearing rather than tidying, and the failure mode is refusal rather than leakage: the mirror image of `claude-code`, which reached `$HOME` only once `M8b`'s plant also granted the fallback.

Suite after the task: `1 of 28 checks failed`, the failure being `check_sc3`'s deliberate progress bar, now missing `j7_1 j8_1 r9 rep1 rep2`. `nix flake check` passes.

### M8d — `pi`, and pre-provisioned extensions (Status: IMPLEMENTED)

**Scenario**: Journey 2.1 for `pi`, plus FR-22.

Shaped by `M1d`: relocation holds through the single variable `PI_CODING_AGENT_DIR`, so `pi` needs no registry entry. `PI_CODING_AGENT_SESSION_DIR` does not exist and is not set.

- [x] Extensions provisioned through Nix before the session, never fetched from inside it (FR-22)
- [x] `PI_OFFLINE` is set, because `pi` installs missing packages automatically on startup, and its own install path reached the registry even under that variable — which disables startup operations only
- [x] It takes its credential from the mediated route — from `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` in the session's environment, and **not** from `providers.<id>.baseUrl` in a file this environment writes, because it writes none ([D14](plan.md#d14) is corrected)
- [x] The path for a consumer who must install an extension is documented rather than left to be discovered — and it is **inside** the confined entry point, not outside it, which is this criterion's other correction
- [x] Seen to FAIL before the fix — the check written before the table entry, `the confinement for pi does not build`
- [x] Five violations planted, each seen to FAIL, reverted, recorded in [plan.md](plan.md#planted-violations)

`pi` needs **two** variables, not the one `M1d` predicted, and every other premise this task carried was wrong in the same direction as `M8a`'s, `M8b`'s and `M8c`'s. Full account in [research.md](research.md#m8d--pi-needs-two-variables-and-fr-22-is-not-the-networks-doing); what the criteria above turn on:

- **The credential needs no file**, the third agent in a row. `pi auth check --provider anthropic --json --credentials` prints the credential the agent holds, so the check reads the 64-hex substitute out of the agent rather than inferring it from a variable name — the sharpest of the three agents' observables.
- **`PI_OFFLINE` is unobservable until a package is declared**, which is why `M1d` could not see it work. The check declares `npm:left-pad` in the relocated settings file and asserts the listing names it *before* asserting no `node_modules` arrived; without that control the FR-22 assertion holds vacuously.
- **`PI_PACKAGE_DIR` is a trap**, documented as "useful for Nix/Guix store paths" while naming `pi`'s own installation. It is deliberately unset.
- **The boundary is a second, independent guard.** With the variable removed inside a session the install is attempted and dies on `EACCES: permission denied, posix_spawn 'npm'`, because the substrate carries no `npm`.
- **FR-22 is not the network's doing, and that is worth knowing.** Egress from a confined session is mediated, not restricted: raw TCP is denied, but arbitrary HTTPS through the injected proxy succeeds, measured with `git ls-remote` against a public host. So a session that types `pi install npm:something` will reach the registry. FR-22 is the absence of *this environment* fetching, which is how the spec already frames it, and the unrestricted egress is a drift entry for `M10a` rather than a defect here.
- **A consumer provisions from inside the session.** `pi install ./vendor/my-ext` on a vendored directory works confined, records a path relative to the settings file, and copies nothing — so a cloned checkout resolves it too. That is what the handbook now documents.

Suite after the task: `1 of 29 checks failed`, the failure being `check_sc3`'s deliberate progress bar, still missing `j7_1 j8_1 r9 rep1 rep2`. `nix flake check` passes, now evaluating a third confinement.

### M8e — Spike: where does each agent read its declarative extensions from? (Status: IMPLEMENTED)

**Scenario**: none — a spike. It exists because this feature has now been wrong three times about a location by reading rather than measuring, and FR-25 cannot be implemented against a guess.

**`opencode` was already measured, in [research.md](research.md) § `M8e`.** That section was a partial answer to this task's question, written when the requirement was drafted, and this spike started from it rather than re-deriving it: the six skill roots and which are `$HOME`-relative, the two-arm differential that proved the blanket `XDG_CONFIG_HOME` hides the config root while `~/.agents` survives it, the `skills.paths` mechanism and the `OPENCODE_CONFIG_DIR` trap beside it, and the split of `~/.config/opencode` into a surface half and an executable half. What remained was `claude-code` and `pi`.

Do not trust an agent's own listing command alone. `opencode debug skill` reports what it *resolved*, so a root that was denied and a root that was empty look identical from outside — which is the mistake this spike exists to stop making.

**Question**: for each of the three agents, which locations does it read declarative extensions from, which of those are `$HOME`-relative rather than XDG-derived, and what is the sanctioned way to name an additional root?

- [x] Every location enumerated per agent, by observation — the agent's own listing command where it has one, `strace -f -e trace=openat` where it does not
- [x] Each location classified: authoring surface (FR-25) or executable extension (FR-26). For `opencode` this splits `~/.config/opencode` rather than granting it, since the same directory holds `plugin/` and `node_modules/`
- [x] The redirection interaction recorded per location: which survive the blanket `XDG_CONFIG_HOME` ([C1](plan.md#c1)) because they are `$HOME`-relative, since those are the ones that can arrive without being declared
- [x] For each agent, the mechanism that names an extra root, and whether it covers the whole surface. `opencode`'s `skills.paths` does for skills; `OPENCODE_CONFIG_DIR` does **not**, because the documented list is agents, commands, modes and plugins with skills absent — a mechanism that covers part of a surface while looking like it covers all of it is the failure mode here
- [x] Findings written to `research.md`, and [D17](plan.md#d17) corrected where they contradict it

**Findings**, in full in [research.md](research.md#m8e--where-each-agent-reads-its-declarative-extensions-from). The earlier blocker — a confined measuring session getting `Permission denied` on `~/.claude`, `~/.config/pi` and `~/.pi` — was the wrong instrument rather than a real obstacle: enumerating what an agent *attempts* to read needs a raw package run unconfined against a scratch `HOME` with a fixture in every candidate root, not the host's real dotfiles.

- **Each agent's undeclared-arrival channel is a different shape, and that is the spike's payload.** `pi` has `opencode`'s hazard exactly — `~/.agents/skills`, read `$HOME`-relative, surviving every redirection. `claude-code` has no `.agents` root at all, not even a probe for one, but walks **every ancestor of the working directory up to `/`** looking for `CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md`, `.claude/rules` and `.mcp.json` — so a surface, and an MCP server declaration, can arrive from `$HOME` or `/`. A third root, `/etc/claude-code/**`, is absolute and no variable moves it; measured unreachable inside a session, because the profile's `filesystem.allow` is `[]` and `groups.include` is `[]`, so `ls /etc` exits 2.
- **One variable per agent moves everything else.** `CLAUDE_CONFIG_DIR` relocates around 84 paths and leaves nothing under `$HOME`, `~/.claude.json` included. `PI_CODING_AGENT_DIR` moves all four of `pi`'s global surfaces (`skills`, `prompts`, `themes`, `extensions`). Both are broader than `OPENCODE_CONFIG_DIR`, which skills escape.
- **`pi`'s project surface is behind a trust gate, and it is observable.** Untrusted, only the global roots and `~/.agents/skills` are read; with `-a`, the four `.pi/` roots and `PROJ/.agents/skills` appear and nothing else does. Global extensions load in an untrusted project regardless.
- **The additive mechanism does not generalise.** `pi`'s settings arrays cover every surface; `opencode`'s `skills.paths` covers skills only; `claude-code` has **none** — `CLAUDE_CONFIG_DIR` moves the root rather than adding one. So `M8f` and `M8g` cannot assume a uniform "name the extra root" step across the table. [D17](plan.md#d17) carries this as its live constraint.
- **`pi` ignores `ANTHROPIC_BASE_URL`**, which corrects `M8d`: with the variable pointed at a dead port the agent still reached `api.anthropic.com` and returned the real API's 401, because it passes an explicit `baseUrl` from its own provider registry. Only the key crosses, and the mediation is nono's interception rather than a redirected base URL. [D14](plan.md#d14) and the `lib/agents.nix` comment are corrected; no code changes, since `credentialServices` was already the whole declaration.
- **Method notes worth keeping.** A cheap invocation does not trigger discovery at all (`pi --list-models`, 343 trace lines, versus ~1000 for a print-mode run and ~7900 for `claude-code`); the 401 at the end is the signal that discovery completed. `jiti`, which loads `pi`'s extensions, honours `TMPDIR`, so extension loading works in a session and only fails under `env -i` where it falls back to `/tmp`. And grepping a `claude-code` trace for `.agents` is a trap: the hits are `.git`/`.ignore`/`.rgignore` probes from its file walk, not discovery.
- **A gap this session cannot close**, recorded rather than left silent: no credential is resolvable here — `ANTHROPIC_API_KEY` arrives empty with nono's `Credential not found for route 'anthropic'` — and `curl` is absent from the substrate because only the package's default output is granted while `bin/curl` lives in its `-bin` output. So whether a live model request succeeds through the mediated route is unmeasured, no check in the suite makes one, and this belongs to `M9` and the handbook.

No check changed, and none should have: a spike that alters behaviour is not a spike. The suite is unchanged at `1 of 29 checks failed`, the failure being `check_sc3`'s progress bar.

### M8f — A declared authoring surface arrives (Status: IMPLEMENTED)

**Scenario**: Journey 8.1

**RED**: `check_j8_1` declares an authoring surface holding one extension per location `M8e` enumerated, starts a session, and asks the agent to report the extensions it has.

- [x] Check written and seen to FAIL
- [x] The declaration comes from the calling environment, never from a file inside a project — the same channel as `source_up_if_exists`, which keeps R5 intact by construction ([D17](plan.md#d17)). `AGENT_SANDBOX_SKILLS`, a colon-separated list of absolute host directories, read by the entry point before it starts a session
- [x] The grant names the enumerated authoring directories individually and **no ancestor of them**, so nothing FR-26 excludes and no credential store arrives with the surface. Asserted as a set equality against the `--read` flags read off the wrapper's own `execve` line in the trace, so the grant is observed rather than recomputed from the declaration
- [x] The agent is *pointed* at the granted roots by the configuration this environment writes; nothing is copied into the project, so there is no reconciliation step and no staleness (P8). Three mechanisms, because `M8e` found no common one, all declared as a `skillSurface` field beside each table entry
- [x] Second arm: the surface is byte-identical before and after a session that tries to write to it — FR-25 lends it rather than handing it over. The write is *attempted*, with the flags the wrapper was observed to pass, because a read-only grant leaves a normal session with no reason to try
- [x] **Control**: an extension planted at a location that was *not* declared is asserted absent in the same session
- [x] Both violations planted (remove the configuration key while keeping the grant; make the grant read-write), each seen to FAIL, reverted, recorded in plan.md

**Findings**

- **`claude-code` is coverable, which `M8e` had concluded it was not.** Symlinking each *child* of the skills root works where symlinking the root would not: the agent follows the links into a read-only host directory, and keeps its own `manifest.json` and `synced` at the writable level above them. So SC-9's "name the uncovered location" escape is not needed for skills.
- **The read-only grant has to go on the argv.** `--allow` is the only filesystem flag nono gives an environment form, and there is no `--set-env` at all — which also rules out pointing `opencode` with `OPENCODE_CONFIG_CONTENT`, since a run-time value cannot cross the boundary.
- **`strace -f -o <file>` is not a usable instrument for this**, and it fails intermittently rather than outright: one file for many processes splits a syscall into `<unfinished>`/`<... resumed>` lines, so a path stops sharing a line with its result. `-ff` per-process files, concatenated, fixes it. Also `O_PATH` opens succeed with no grant, so only a non-`O_PATH` open discriminates. Both recorded in [`research.md`](research.md#m8f--the-declared-surface-and-the-two-instruments-it-needed).
- **Skills alone.** Prompts, themes, agents, commands, output styles, rules, modes and workflows are not carried in, and SC-9's obligation to name them is discharged in the handbook. Past skills the surfaces shade into code that runs, which FR-26 keeps out of a variable set once and forgotten.

The suite is at `1 of 30 checks failed`, `check_sc3` now missing only `j7_1 r9 rep1 rep2`.

### M8g — The declared surface is exactly what arrives (Status: IMPLEMENTED)

**Scenario**: R9

The half of R9 that needs `M8f` to exist. A grant that brings the surface *and* something else satisfies `M8f` completely, so the property is a difference and one observation cannot carry it — the shape `check_j6_1` and `M4c` both arrived at independently.

**RED**: `check_r9` runs the same planted host configuration twice, once with the surface declared and once without, and subtracts the readable sets.

- [x] Check written and seen to FAIL
- [x] The difference set is asserted **equal** to the declared locations, in both directions: `⊇` is the surface arriving, `⊆` is nothing arriving with it
- [x] Stored credentials, conversation history and session state are planted under the same host root and asserted unreachable in both arms (FR-21)
- [x] No host confinement description takes part in deciding reach, asserted by comparing granted paths against a run with the host description removed — the self-referential case `M1e` found, where host configuration decides what a session may reach
- [x] **Control**: the session starts and works in both arms, so an agent that read nothing cannot pass
- [x] Three violations planted rather than the two named here, each seen to FAIL, reverted, recorded in plan.md

**Findings**

- **The reach is *read*, not reasoned about.** `session_readable` takes the grant off the wrapper's own `execve` line and hands that exact argv to a fresh `nono run`, which then tries to open each planted path. A check that subtracted two lists of `--read` flags would assert that the wrapper says the right thing; this one asserts that the session can do the right thing, and the two differ wherever a grant names a path a profile then withholds.
- **nono's diagnostics go to stdout**, so a session started with no resolvable credential prints `Credential not found for route 'anthropic'` into the same stream the probe answers on. Unmarked, that line lands in the difference set as though the surface had brought it. The probe marks each answer and the marker is stripped again, which is the only reason the difference is ever empty.
- **The three plants are disjoint, and that is what needed three of them.** Widening the grant to the surface's parent fires the difference arm alone; granting the host's `nono` directory fires FR-21 alone; making the grant *depend* on the host description fires the self-referential arm alone. The plan predicted the middle one would cover the last, on the reasoning that a granted host description is a host description deciding reach. It is not: an unconditional grant is byte-identical in both arms, so `deciding` needs a plant that varies with the description's presence. The third plant is P2 applied to a checklist line that would otherwise have gone unproven.
- **The never-declared sibling is load-bearing.** `$home/skills/gamma/three` sits under the same parent as the two declared roots and is what makes the widening plant bite. Without it the plant widens to a directory holding nothing else, the difference is unchanged, and the `⊆` direction passes for want of anything to catch — the plan's own prediction, that the parent would drag in credentials and history, does not hold for a home laid out the way a consumer lays one out.
- **The anti-vacuity arm is per-arm, not per-check.** `$PWD/canary.txt` is asserted readable in `declared` and in `bare` separately, because a difference of two empty sets is empty and satisfies both containments. The `nohost` arm needs none: only its grant is read, so the cheapest `--version` run that still reaches `exec nono run` is enough, and it never starts a session to be vacuous about.
- **The suite was silently one check short, and this task is how that surfaced.** With `check_r9` written, discovered by `--list` and named by `check_sc3` as covered, a full run still printed `1 of 30 checks failed` and never mentioned it. `run_layers` feeds check names to a `while read` loop through a process substitution, so a check inherits that list on its stdin; `check_j8_1` starts `claude -p hi` and `pi -p hi`, print mode reads stdin for its prompt, and the last name in the file was eaten. Reproduced in isolation before the harness was touched, because "a check vanished" and "a check was never defined" look identical from a green run.
  Two fixes, at two depths. `run_check` gives each check `</dev/null`, which closes the cause. And `run_layers` counts what `checks_in` found against what the loop reached, which closes the class: the existing anti-vacuity rule only fires when *nothing* ran, and a suite that runs all but one is the same failure one increment away from invisible. The second is what turns a future recurrence into a red run instead of a shorter green one.

The suite is at `1 of 31 checks failed`, `check_sc3` now missing only `j7_1 rep1 rep2`.

**Checkpoint**: FR-1 is satisfied; all three agents are confined and `check_sc1` still passes without being edited, which is the property SC-1 asserts. FR-25 holds for every agent, and SC-9's obligation — that any location the surface does *not* reach is named in the usage document rather than discovered by experiment — is carried into `M10a`.

______________________________________________________________________

## M9 — Consumability, idempotency and CI

### M9a — A stranger reaches a confined agent from the ref (Status: IMPLEMENTED)

**Scenario**: Journey 1.1 at the end-to-end layer — the layer AGENTS.md names as the one that matters and the one easiest to fake.

**RED**: `check_j1_1` at e2e runs `nix develop <canonical ref>` with `HOME=$(mktemp -d)`, from the pushed ref and never from the working tree.

**Preconditions, measured** — in full in [research.md](research.md#m9--preconditions-for-the-end-to-end-layer-measured-before-it-exists). Three of the first four change this task rather than merely confirming it; the fifth and sixth changed the repository, and had to land before this task could be written at all.

1. **The ref is right and its content is not.** `origin` is `git@github.com:GRBurst/agent-sandbox.git`, public and reachable unauthenticated, so FR-19's name is confirmed and the handbook's `github:HivemindTechnologies/sandbox-examples` is wrong in both halves. But `origin/main` is still `1c8b15e`, a Kafka playground shell with no agent, no `nono` and no `nixConfig`, and local `main` is a long way ahead of it — the distance is left unstated on purpose, because it grows with every commit this feature lands. **`check_j1_1` stays RED until a human pushes**, which is the correct state for it and not a reason to defer writing it.
1. **The obvious invocation passes against that agentless ref.** `nix develop --command` prepends the devshell's `PATH` and *keeps the caller's*, so `command -v claude` inside `nix develop <ref>` resolved the developing checkout's own wrapper, at position 53 of `$PATH`. The instrument is therefore part of this task's definition: `env -i` with a scratch `HOME`, never `direnv exec .`. It has since been run end to end and **does not lie** — against the agentless ref all four of `claude`, `opencode`, `pi` and `nono` report `ABSENT` while the ref's own `kcat` and `kafkactl` resolve, so the inheritance control this task's checklist demands is proven rather than assumed. Two details of it are load-bearing and [written up](research.md#the-instrument-that-does-not-lie): its `PATH` is **derived** as `dirname "$(command -v nix)"` rather than written down, because the literal that works on NixOS does not exist on the macOS runner `M9c` adds; and it must carry a scratch `TMPDIR`, because `env -i` strips it and the fallback to `/tmp` is denied to anyone developing this from inside a confined session.
1. **`--accept-flake-config` is load-bearing.** A clean run was seen to print `ignoring untrusted flake configuration setting 'extra-substituters'`, so the declared cache does nothing for a stranger who is not a trusted user. That changes what the handbook tells a stranger to type, not only what the check does.
1. **The harness needs one new file.** `scripts/checks/e2e.sh` does not exist; every function that walks the layers skips a missing file, and `M8g`'s found-versus-ran guard counts only files that exist.
1. **No agent could be started by hand at all, and the whole suite was green.** Asked to type `opencode` inside the environment, a human got a hang and no output. The pre-flight omitted `--allow-cwd`, on the reasoning recorded at [`M4a`](#m4a--the-pre-flight-refuses-an-unenforceable-host-status-done) that it writes nothing inside the project; measured, the flag is the *consent*, and without it nono's behaviour depends on `stdin` — [three states, tabulated](research.md#the-three-states-of---allow-cwd). On a terminal it **asks**, and the pre-flight had sent both its streams to `/dev/null`, so the question was invisible and the wrapper waited forever. Fixed here, with the flag on both confined runs and nono's own stderr now quoted on a refusal (P9). Two things about this are worth more than the fix. First, **no check could have caught it**: `validate.sh` pins every check's `stdin` to `/dev/null`, which is the one state in which the prompt does not happen, so `check_r6`'s new fourth arm asserts on the argv the pre-flight passes rather than on the outcome. Second, it is precisely the failure this milestone exists to find — a claim verified only from inside the developing checkout, where nobody ever typed the command a stranger types first. The handbook's *"`type claude` is the check that matters"* comes from the same session: the human's shell aliased `opencode` to their own host arrangement, so `PATH` was never consulted and the reported error, `nono: Profile not found: opencode-claude`, came from outside this repository entirely.
1. **And once it could start, it could not start twice.** Behind the hang sat a second defect, in the machinery `M8f` added: `jq: parse error: Expected another key-value pair at line 2, column 48`, naming neither this environment nor the file. `opencode` parses *and edits* its configuration as JSONC, and `M8e` had pointed `skillSurface.path` at that file precisely because a consumer's settings might already be there. So the entry point wrote `{}` on the first start, the agent inserted its own `$schema` into an empty object and left the trailing comma its editor emits, and the second start died — with `set -e` taking the shell down before the `mv` and leaving a zero-byte temporary behind. The developing checkout had been in that state since `M8f` landed. Fixed here: `skillSurface` gains an `owned` flag, `opencode` is pointed at `.agents/opencode/config.json` through `OPENCODE_CONFIG` — an *additional* scope, so the consumer's own configuration is no longer read, written or fingerprinted — and the file is rewritten whole on every start. The measurements, the four-scope precedence chain and the rejected alternatives are in [research.md](research.md#the-second-opencodes-configuration-file-is-jsonc-and-the-agent-writes-to-it). What this precondition adds to the one above is the reason no check saw it either: every fixture in the suite starts from a project where that file does not exist, which is the one state the defect cannot occur in. `check_opencode` now **seeds** the file with what the agent leaves behind, because starting a session twice turned out not to reproduce it reliably — the same agent mangled the file on one run and left it alone on the next.

- [x] Check written and seen to FAIL
- [x] FR-19: the canonical reference is `github:GRBurst/agent-sandbox`, named identically in every document; the handbook's current owner and repository are both wrong and are corrected
- [x] No step depends on the author's configuration (SC-5), and the run inherits **nothing** from the developing environment — asserted by the check itself, which fails if any agent resolves before `nix develop` has been entered
- [x] The clean `$HOME` is created before the run and `$XDG_CONFIG_HOME` inside it exists before the mechanism is invoked, or the mechanism silently reads the real home instead ([M1e](research.md#m1e--machine-readable-resolved-policy))
- [x] The binary cache is reachable by the stranger too: this repository's own `nixConfig` declares `https://cache.numtide.com` and its key, because an input's `nixConfig` is not inherited ([M4b](#m4b--a-confined-claude-starts-status-implemented)). Since a stranger is not a trusted user, the handbook's command carries `--accept-flake-config` and the check passes it too
- [x] Nothing is passed `--impure`, and the lock is the committed one (P8)
- [x] Three violations planted rather than the one named here, each seen to FAIL, reverted, recorded in plan.md — `M4b` already planted the confinement arm, and this task adds the arm that is specifically about consuming from the ref

**Findings**

- **The check is red for the one reason it should be, and that is the deliverable.** `check_j1_1` reports `the agent entered from github:GRBurst/agent-sandbox does not resolve to a store path, so the name is answered by this machine rather than by the reference: claude=ABSENT`, against locked rev `1c8b15e0dca28d89f36ec917a03bbeaefa90f85c`. Every control arm passes; the only failing arm is the one that needs the environment to exist at the ref. Nothing about the check changes when a human pushes — the fix is a push, not an edit, and the handbook now says so where it used to call the path untested.
- **The ref control is what stops this being a check of the working tree, and it is load-bearing rather than decorative.** Swapping `canonical_ref` for `$REPO_ROOT` and *also* neutralising both ref-control arms turns the whole check green: `PASS check_j1_1`. That false green is the finding. It also, incidentally, proves the other four arms correct — the enter, the start, the session selection and the reach equality all pass against a real environment, so what remains untested at the ref is only that the ref carries one.
- **The inheritance control needs a sentinel, because a store path is not evidence of anything.** With `PATH=$nixbin:$PATH` planted, the leaked `claude` resolves to `/nix/store/pgrk02lclv49p0p6h0ga6p4ablpcyffl-claude/bin/claude` — a store path, from the developing checkout's own devshell. An arm asserting only "resolves under `/nix/store`" passes on that. So the check plants an executable of its own on the caller's `PATH` before building the stranger environment and requires it to come back `ABSENT`, which is the assertion that discriminates.
- **A purity guard that names what it forbids fails on itself.** The first form of the `--impure`/`--override-input` grep counted its own pattern and its own failure message, three occurrences in a clean file. Written as `-[-]impure` and `-[-]override-input`, with the message avoiding the literals, it reads 0 on the file as it stands and 1 with `--impure` planted. Any check that greps its own source has this hazard, and the plant is the only thing that surfaces it — a guard that always fails looks the same as a guard that always fires.
- **`2>&1` on `nix flake metadata --json` destroys the diagnosis.** With a dirty working-tree ref, nix's own warning was folded into the JSON and the check reported `jq: parse error: Invalid numeric literal` — true, useless, and naming neither the ref nor the type it resolved to. Sending stderr to a file instead yields `the canonical reference is not a published github reference: /home/pallon/projects/hivemind/agent-sandbox`, which names the fault (P9). The cost is ordering: the scratch directory has to be created before the ref is inspected.
- **The move between layers is invisible to the harness, by earlier design.** `check_sc3`'s bijection and `check_controls` both scan `checks/*.sh` rather than a named layer, so deleting `check_j1_1` from `integration.sh` and defining it in a new `e2e.sh` disturbs neither. `--list` shows it under `e2e`; the covered-scenario set is unchanged.

The suite is at `2 of 31 checks failed`: `check_sc3`, still missing `j7_1 rep1 rep2`, and `check_j1_1` itself.

This check needs no positive control against confinement, and the reason is worth writing down rather than leaving as an omission: that observable is a *set* — the granted reach compared against the registry — and a set is already discriminating, because with confinement removed there is no manifest to read at all. [D9](plan.md#decisions) binds the checks whose observable is a *failure*. It does need the inheritance control named above, which is a different problem: there the failure mode is a check that passes without the ref taking any part at all.

### M9b — Entering and verifying twice change nothing (Status: DONE)

**Scenario**: Rep1 and Rep2 — two scenarios, so if either needs more than a trivial edit, split this task.

**Precondition, measured**: `.gitignore` already excludes `.tmp/`, `.cache/`, `/.local/`, `/.config/`, `/.agents/`, `*.log` and `.direnv`. That is what "tracked files unchanged" rests on, and an entry added later would weaken the assertion in silence. So the repository's *content* is compared over tracked files, where `.gitignore` has no vote — and everything else is compared over the working tree **outside the state roots the environment declares for itself**, which is a list with a different owner. `*.log` is why the second half is not optional: `git check-ignore -v validate.log` answers `.gitignore:8:*.log`, so the violation this task requires planting into `validate.sh` is one a git-shaped assertion cannot see at all.

- [x] `check_rep1`: tracked files unchanged and granted reach byte-identical — three arms, `tracked`, `tree` and `reach`, each diffed between the first entry and the second
- [x] `check_rep2`: same result, no residue a third run would trip over — SC-7 stated as a property of the suite rather than of one run: three runs, each asserted to exit 0, and runs 2 and 3 compared against run 1 on verdict, tracked content and residue
- [x] Both carry the control an equality assertion needs: `check_rep1` asserts the reach is non-empty and holds the workdir, that the tracked manifest is non-empty, and that the residue manifest still covers every tracked path; the second entry is confirmed by its own audit record, in a state root of its own, holding exactly one `claude` session. `check_rep2` parses the suite's own `N checks passed` verdict and requires N > 0, so two runs that found nothing to do cannot agree their way to green
- [x] Two violations planted, one per check, each seen to FAIL, reverted, recorded in [plan.md](plan.md#planted-violations) — `date +%s%N >"$PWD/entered-$(date +%s%N)"` in the entry point's body, and `printf 'run at %s\n' "$(date +%s%N)" >>"$REPO_ROOT/validate.log"` in `validate.sh`'s `main`

An assertion that two things are equal is the shape most easily satisfied by nothing happening at all, which is why the control here is about the *content* of what is compared rather than about a failure. This is the same reasoning [D9](plan.md#decisions) applies to the refusal checks, reaching a different arm of the same problem.

**Findings**

- **The end-to-end layer cannot reach these two scenarios from the published reference, and the reason is the fourth checkbox.** Both plants have to be *in the thing under test*, and a published revision is precisely what cannot have one planted in it. On top of that the reference is still `1c8b15e`, which carries no agent, so Rep1's "granted reach" could not be observed there at all. So both checks consume the repository as `stranger_checkout` makes it: every tracked path copied, `git init`, one commit, nothing untracked and nothing the environment has already written. `nix flake metadata --json` reports that copy as `{"type":"git","rev":…,"dirty":"none"}`, which is what makes entering it equivalent to entering a reference rather than a dirty path. The deviation from plan.md's test-strategy row is recorded there.
- **`.gitignore` would have hidden one of the two plants completely.** `*.log` is ignored anywhere in the tree, so `git status --porcelain` in the checkout stays empty while `validate.log` accumulates a line per run. That is the "weakened in silence" hazard in the precondition arriving one task later as a concrete false green. The residue observable is therefore derived from the environment instead: every variable the entered shell points inside the project (`env -0` from inside `nix develop`), reduced to its first path component, plus every `$WORKDIR/…` value in the agent's built confinement description, plus `.git`. Measured, that yields `.agents .cache .config .docker .git .local .npmrc outputs .tmp` for `check_rep1` and the same set without `.agents` for `check_rep2` — which is itself an assertion, since a verification run has no business writing under `.agents`.
- **The first path component is the right unit, and not only for brevity.** `TMPDIR` is stable but `NIX_BUILD_TOP`, `TEMP`, `TEMPDIR` and `TMP` all carry a per-entry `nix-shell.xCOLd5` suffix, so a root list taken at full depth would differ between two entries that are identical in every way this scenario cares about.
- **`.git` is excluded, and that is not a convenience.** Reading the index refreshes it, so a comparison including `.git` would be measuring the observer rather than the environment. The repository's content is covered by the tracked manifest instead, which is the half `.gitignore` cannot weaken.
- **Both plants bit, and each bit only the arm it should.** The wrapper's timestamped file appeared as `+file … ./entered-1787473805705244595` in `check_rep1`'s residue diff, with the tracked and reach arms still green — the file is untracked, so a tracked-only comparison would have passed. `validate.log` appeared in `check_rep2`'s residue diff for runs 2 *and* 3, with a different hash each time.
- **`check_rep2` observes one layer of the suite, not the suite.** A run of the whole suite contains this check, so it would recurse; what a run can contain is the layers below. `component` is the layer of those that builds artefacts, and a run that writes into the checkout does it while building rather than while evaluating. Measured: `3 checks passed` in 21s cold, then 8s and 6s, byte-identical stdout all three times, exit 0 all three times.
- **A state root of its own per entry is what makes "the second entry happened" observable.** The reach comes from the session's own audit record, and one shared root would leave two entries' records indistinguishable — the check would then be asserting that one entry equals itself. With a root each, "exactly one `claude` session under this root" is both the selector and the confirmation.
- **The whole of Rep1 costs 10s and Rep2 39s**, after the copy, which is free. Rep1 enters and starts the agent twice: `env -0` and `exec claude --version` in the same entered shell, so the environment observed is the one the agent started from.
- **The checkout carries tracked paths, so an untracked file does not travel — including, at the moment this landed, `scripts/checks/e2e.sh` itself.** `check_rep2` therefore ran a suite with no end-to-end layer at all, which `validate.sh` handles by skipping a layer file that does not exist. Uncommitted *edits* to tracked files do travel, since the copy takes working-tree content rather than `HEAD`. Both halves are the right semantics for this layer — a stranger receives what is committed — and both are worth knowing before a check is debugged for the wrong reason. It also means the two checks cannot recurse into themselves even structurally.
- **shellcheck reads the check file as one scope.** A `local rootfile=$2` in one function and a `local -a roots=()` in another collided as SC2178/SC2128 while the names matched, which is worth knowing before it is diagnosed as a real array bug.

With `check_rep1` and `check_rep2` defined, `check_sc3` reports `scenario with no check: j7_1` — down from `j7_1 rep1 rep2`, and the last of the three is `M9c`'s. The whole suite is at `2 of 33 checks failed` in 12m45s: `check_sc3` for that one scenario, and `check_j1_1` still waiting on a human to push.

### M9c — The claims are checked on clean machines, per platform (Status: DONE)

**Scenario**: Journey 7.1

**RED**: `check_j7_1` at e2e asserts the suite ran unattended and reported success, then plants a registry entry and asserts the expected set changed with the check unedited.

**Preconditions, measured**: there is no `.github/`, so this starts from nothing. The sentence to amend is `AGENTS.md`'s "There is no cloud, no Kubernetes, no CD pipeline and no deployed service", and it appears once. The substituter checkbox below is not speculative — a clean run was seen to print `ignoring untrusted flake configuration setting 'extra-substituters'`, so without the flag or a machine-level setting a runner compiles three agents from source ([research.md](research.md#m9--preconditions-for-the-end-to-end-layer-measured-before-it-exists)).

- [x] Check written and seen to FAIL — `there is no verification workflow at .github/workflows/verify.yml, so nothing runs the suite on a clean machine (FR-13)`
- [x] `.github/workflows/verify.yml` runs `scripts/validate.sh` on `ubuntu-latest` and `macos-latest`, unattended, on a machine with no prior agent state (FR-13) — the matrix's `system` set is diffed against `nix eval .#agentBinaries --apply builtins.attrNames`, each row's runner image is required to match its system's family, and no string in the document may say `self-hosted`
- [x] Exit status alone separates a passing commit from a failing one; no human reads the output (SC-4) — no job carries `environment`, no map anywhere carries `continue-on-error`, and the suite step has no `if`, no `||` and no `; true`
- [x] FR-20 and SC-8 asserted together: the same command asserts the same properties on both platforms, and the resolved reach is compared **across** the two jobs and must be equal — the suite step names neither `matrix.` nor `runner.os`, so one command runs on both; a second job `needs` the first, downloads both reports and diffs them
- [x] Planting a registry entry changes the expected set without the check being edited — the third `Then` of Journey 7 — `comm -13` between the reach resolved before and after the plant is exactly the planted path
- [x] The substituter and its key are passed to the runner explicitly, since a CI user is not a trusted user and an input's `nixConfig` reaches neither; without them a runner builds every agent from source — every token of `flake.nix`'s own `nixConfig`, read with `nix eval --file ./flake.nix nixConfig`, must appear among the workflow's strings
- [x] Violation planted (the workflow runs only the cheapest layer), seen to FAIL, reverted, recorded in [plan.md](plan.md#planted-violations)
- [x] `AGENTS.md`'s "no CD pipeline" sentence amended to permit non-deploying CI, retaining the prohibition on deployment

The second arm is what makes this checkable at all: exit 0 alone is also what a suite that ran nothing produces, which is why `validate.sh` treats "no checks ran" as a failure ([M1a](#m1a--the-scenario--check-bijection-status-done)). The cross-platform comparison is the one assertion in the suite that no single machine can make, so it lives here rather than in a check.

**Checkpoint**: `check_sc3` passes for the first time — every scenario has its check, and the bijection is closed. The set it has been naming since [M1a](#m1a--the-scenario--check-bijection-status-done) is empty for the first time. Its size is deliberately not written down here: it was twenty when this line was first drafted, it was already twenty-two, and Journey 8 made it twenty-four. The check derives it from `spec.md`, which is the point.

**Findings**

- **The check reads the workflow as a parsed document, never as text, and the first draft proved why.** Written as `grep` over the file, the `continue-on-error` arm failed against a workflow that does not use it — it had matched the comment saying so. Every textual arm now reads the strings the document *says*, via `yq -r '[.. | select(tag == "!!str")] | .[]'`, so a workflow may explain itself without failing the check that reads it. This is the same class of defect as [`M9a`](#m9a--a-stranger-enters-from-the-reference-status-done)'s purity guard counting its own text, arriving through a different door.
- **`on` has to be quoted.** YAML 1.1 reads a bare `on` as a boolean, so the key becomes `true` and both `yamllint` and any arm asserting `push`/`pull_request` are looking at a key that is not there — against a file GitHub itself accepts. The quoting is load-bearing for the observer, not for the runner.
- **The platform set is derived, not written down.** The matrix's `system` values are diffed against `nix eval .#agentBinaries --apply builtins.attrNames`, so adding a platform to the flake fails this check until the workflow carries it, and removing one fails it until the workflow drops it. The runner images are then controlled per row — a `linux` system must map to an image beginning `ubuntu` and a `darwin` one to `macos` — because a matrix of two rows both landing on `ubuntu-latest` satisfies a set comparison perfectly while verifying one platform twice.
- **The cross-platform comparison drops every store path, and that is the assertion rather than a concession.** One platform's substrate legitimately carries a locale archive and a tracer the other has no use for, so a byte comparison of the two descriptions could never be equal and an equality over them would have to be abandoned or faked. What survives the filter is the project's own grant, whatever the leak registry justifies, and the `$WORKDIR` state redirection — which is precisely the set FR-20 requires both platforms to agree on, expressed in terms neither platform's semantics decides.
- **The `reach` step is executed, not read.** `workflow_step` pulls the step's `run` body out of the document, reads its `shell:`, reconstructs GitHub's own `{0}` substitution and runs the result in a `stranger_checkout`. Asserting on a copy of the pipeline kept beside the check would have proved the copy correct; running the workflow's own text is what makes the arm an observation of the artefact. It then reads the artefact path off the *upload* step rather than assuming `reach.json`, requires it non-empty, and requires a key for every agent `nix eval <copy>#agents` names.
- **The third `Then` is checked by re-derivation.** `expected_reach` takes the flake reference as an argument, so the same pipeline — substrate closure plus the registry filtered to that agent — can be pointed at a copy with an entry planted in it. `plant_registry_entry` goes through `checkEntry`, so the plant is a valid entry rather than a syntactic edit, and `cmp -s` confirms the substitution landed before the file is moved into place. `comm -13` between before and after must be exactly the planted path. Two `Git tree … is dirty` warnings appear from the copy, both *after* the plant, which independently confirms both that the plant landed and that the pre-plant evaluations ran against a clean tree.
- **An equality is easiest to satisfy with nothing on either side, so the before-set is controlled for content**: it must hold at least one `/nix/store/` path and the project directory itself. Without that, a registry that resolved to nothing would make the difference arm agree forever — [D9](plan.md#decisions)'s vacuity again.
- **The forbidding arms forbid things that are possible.** Before rejecting `--layer` in the suite step, the check asserts that `validate.sh` still *accepts* `--layer`. A prohibition on something the driver cannot do would pass forever and protect nothing.
- **Two configuration files the plan did not anticipate, and both are consequences of AGENTS.md §3 rather than preferences.** `yamllint`'s defaults cannot pass this workflow: the trusted-public-key line is 104 characters and `nix.conf` syntax has no continuation, and a GitHub workflow carries no `---`. `yamlfmt`'s default collapses every blank line, which would fuse a heavily commented workflow into one block. Since the repository has to lint identically for someone with none of our dotfiles, the departures belong in checked-in `.yamllint.yml` and `.yamlfmt` with a justification per line, not in a local invocation.
- **`set -u` on a missing positional kills the shell rather than failing the condition.** `workflow_step` called without its fifth argument inside `if ! …` exited the check with *no output at all* and stopped `xtrace` mid-function — which reads exactly like a `nix` invocation dying silently. Worth knowing before the next hour is spent on the wrong suspect.
- **The comparison job carries its own two vacuity guards**, in the workflow rather than in the check: fewer than two reports, or a report that is empty, both make a diff agree forever. `fail-fast: false` is there for the same reason — cancelling the second platform the moment the first goes red would leave the comparison with one side.
- **The macOS denial-set coverage gap stays open, and this is the decision [plan.md](plan.md#coverage-gap) deferred to here.** `check_substrate_denials` uses `strace`, which is Linux-only, so it reports SKIP on `darwin`. Closing it needs the same differential written against a macOS tracer, and that cannot be settled from a Linux checkout — neither the tracer's availability on a hosted runner nor its behaviour under it is measurable here. So the gap is left documented rather than closed by something unverified, and what would close it is named: a `darwin` differential, once a `darwin` machine exists to write it against.
- **What this check does *not* establish is that a runner accepts the workflow.** Every arm asserts the workflow *describes* the right run; only a push proves GitHub agrees. That is the same shape as `check_j1_1`'s outstanding failure, and the same push settles both.

The suite is at `1 of 34 checks failed`: `check_sc3` green for the first time, and `check_j1_1` still waiting on a human to push the reference.

### M9d — On macOS there is nowhere to put the outside (Status: IMPLEMENTED)

**Scenario**: the same Journey 7.1 as [M9c](#m9c--the-claims-are-checked-on-clean-machines-per-platform-status-done), for the platform that run left unmeasured.

**The limitation, in plain words**

- To prove that a session cannot read your SSH key, a check plants a fake key somewhere the session is not allowed to look, and then tries to read it from inside the session. That somewhere has to be outside the project, because the project is the one place a session *is* allowed to look.
- The property being checked is a difference, not a denial. `check_r1` runs the same probe twice against the same planted key: with the shipped description the read must be refused, and with the key's directory added to that description it must succeed. **Keys are unreachable by default and reachable when the description says so**, and neither half means anything without the other.
- On Linux there is somewhere to put that fake key: `$XDG_RUNTIME_DIR`, which is `/run/user/1001` on the runner and which nothing grants.
- On macOS there is no temporary directory that works at all. The floor grants `/private` for reading, and `/tmp`, `/var/folders` and `$TMPDIR` all resolve under `/private` there. So wherever `mktemp` puts the fake home, the session may already read it — and the mechanism then refuses to start, because a path it was asked to grant overlaps the state root it protects.
- The consequence is that **23 of 33 checks fail on macOS, and every one of them fails before a session exists**. Confinement on macOS is therefore unmeasured in both directions: not the denial, and not the whitelisting. What is broken is the harness's ability to fabricate an outside, not the product.
- The only writable place on macOS that nothing grants is under `/Users` — inside the real home. Using it would contradict this repository's own rule that nothing is written outside the project. The repository does already carry one exception of exactly this shape, the mechanism's own `$XDG_STATE_HOME/nono`, an accepted leak recorded in [lib/leak-registry.nix](../../lib/leak-registry.nix) and the handbook because it cannot be granted even in principle. Whether the harness's fake home is a second instance of that exception or something the rule must refuse is the open question, and it is a decision rather than a measurement.
- So this task does not start with a directory to pick. It starts with whether the harness may have an outside at all, and that is what the directive below is for.

**Measured** — third CI run, commit `e189d82`, the temporary probe step on both runners. `TMPDIR` is project-local on both platforms because the devshell sets it, so plain `mktemp` inside the environment is the one candidate that fails everywhere.

| candidate | Linux | macOS |
| --- | --- | --- |
| `$XDG_RUNTIME_DIR` | ungranted, session starts | unset |
| `$TMPDIR`, i.e. `<project>/.tmp` | granted, refused | granted, refused |
| `/tmp` | write-granted, session starts | read-granted via `/private`, refused |
| `$RUNNER_TEMP`, `$HOME` | ungranted, session starts | ungranted, session starts |

The Linux column is the second finding: it is green only because the runner image happens to export `$XDG_RUNTIME_DIR`, and `/tmp` passes only because `system_write_linux` grants it write-only. Both platforms rest on the same unmeasured accident, and one image change turns Linux red the same way.

**Research directive** — to be answered before anything here is implemented.

```
Research Directive: Establish where, on macOS, a verification harness can fabricate a
host home that the confinement mechanism grants nothing on — or establish that no such
location exists and what the assertion must become instead.

Context: agent-sandbox confines coding agents with nono 0.74.0, granting a session its
own project directory and nothing else. Its integration layer proves the boundary by
planting a canary — an SSH private key, a credential, a shell history — in a fabricated
host home outside the project, then reading it from inside a session and requiring the
read to be refused; a second arm adds that directory to the description and requires the
read to succeed. The fabricated home therefore has to sit somewhere the session is not
granted. nono additionally treats $HOME/.nono as a protected state root candidate and
refuses to start when any granted path overlaps it. On Linux $XDG_RUNTIME_DIR satisfies
this. On macOS nothing conventional does: the floor group system_read_macos grants
/private, system_write_macos grants /private/tmp, /var/folders and $TMPDIR, and every
macOS temporary directory resolves under /private. Measured on a GitHub macos-26-arm64
runner, 23 of 33 checks fail with either "Refusing to grant '/private' (source:
group:system_read_macos) because it overlaps protected nono state root
'/private/tmp/.../home/.nono'" or the same refusal naming the checkout, before any session
starts. The only writable ungranted class found was /Users, which is the user's real home
and which the project's own rule — nothing written outside the project — would forbid.

Objective: Decide what the macOS integration layer should use as its outside, with the
answer resting on measurement rather than on preference, and with the cost to the
project's isolation rule stated explicitly if the answer lies outside the project.

Core Investigation Areas:
* How nono resolves its protected state root on darwin: which variables are consulted,
  whether the candidate set includes $HOME/.nono unconditionally, and whether any flag or
  variable lets a caller declare that root explicitly instead.
* Whether the macOS floor groups are optional. Can system_read_macos be declined or
  narrowed so /private is not granted wholesale, what stops working on darwin if it is,
  and is the floor a property of nono or of the profile.
* Whether a deny rule can override a group's grant for one subtree, making a path inside
  /private ungranted again, and whether deny-overlap is enforceable on darwin at all —
  the Linux refusal says it is not enforceable there, and the darwin answer is unknown.
* Writable macOS locations outside both /private and /Users: getconf DARWIN_USER_TEMP_DIR
  and DARWIN_USER_CACHE_DIR, a mounted disk image, an APFS volume, a directory created at
  the root of the boot volume, and which of these a GitHub-hosted runner permits.
* What macOS enforcement nono actually applies — Seatbelt, EndpointSecurity, something
  else — and what tier of guarantee that gives compared with Landlock, since FR-11 has to
  name it per platform either way.
* Whether the assertion can be restructured to need no ungranted directory: for instance
  a canary the session is granted to read but that the resolved policy must not name, or
  an observation at the policy layer rather than at enforcement. State plainly what such
  a restructuring stops proving, because the integration layer exists precisely to watch
  enforcement rather than to read a description.
* Whether the same reasoning leaves Linux fragile: $XDG_RUNTIME_DIR is a runner-image
  accident and /tmp passes only because the grant there is write-only, so a portable
  answer should hold on both platforms rather than fixing one.

Deliverable Requirements: A recommendation naming one mechanism, with the measurement
that supports it quoted verbatim — command, host, output — and the runner-up rejected on
evidence rather than on taste. It must say whether the chosen location is inside the
project or outside it; if outside, it must say what the project's isolation rule now
permits that it did not, in the form the accepted-leak list already uses for
$XDG_STATE_HOME/nono. It must also say what the answer is on Linux, so one mechanism
serves both platforms, and it must name what remains unverifiable on macOS so that the
gap is recorded rather than discovered.
```

- [x] The scratch root is **derived** rather than written down: no check names a directory that happens to work on one platform, and the derivation fails loudly rather than falling back to a granted path
- [x] `integration.sh`'s precondition 2 restated to say what that directory is for and why macOS constrains it
- [x] Violation planted — a root the description grants — seen to FAIL, reverted, recorded in [plan.md](plan.md#planted-violations). Two of them, because the two granted roots fail differently: the project, which the derivation rejects without asking, and `/tmp`, which nono answers `insufficient_access` for and which a session on Linux nevertheless starts in
- [x] Sessions start on macOS, measured in CI: the fourth run takes `$RUNNER_TEMP` as the root and the failures drop from 23 to 11, none of them a refusal to start
- [ ] The directive above answered, and its decision recorded in [plan.md](plan.md#decisions). **No longer a precondition on the checks, and that is a deliberate reversal**: the derivation asks the question of the host at run time instead of settling it in advance, so the harness stops depending on an answer nobody has. What the directive would still change is the *candidate list* — a macOS location better than the real home, or a restructuring that needs no ungranted directory at all — so it is carried into [M10a](#m10a--close-out-status-pending) for reconsideration rather than blocking here

The three criteria this task used to carry about the macOS job being green now belong to [M9e](#m9e--the-eleven-failures-the-macos-arm-found-status-pending), because the derived root is what made them reachable in the first place.

**What landed, ahead of the directive**

`outside_root <label>` in [scripts/validate.sh](../../scripts/validate.sh) — in the driver rather than in a layer, because both the integration and the end-to-end layer fabricate host homes. It tries `$XDG_RUNTIME_DIR`, then `$RUNNER_TEMP`, then `$HOME/.agent-sandbox`, rejects any candidate under the checkout without asking, and takes the first that is writable and that `nono why --op readwrite` answers `path_not_granted` for. Anything else — a partial grant included — is refused with the verdict every candidate got. All 23 call sites now read `outside=$(outside_root <label>) || return 1`; `check_r6` and `check_substrate_denials`, which took an ambient `XDG_RUNTIME_DIR` directly, take theirs from the same helper. `check_j7_1` deliberately keeps a project-local directory, since it reads a file and starts no session.

Two things this leaves open, both for [M10a](#m10a--close-out-status-pending) rather than for here. The last candidate writes under the real home, which is a write outside the project and so is the accepted-leak question the directive was posed to settle. And the derivation's answer is only as good as the list it tries: on a host offering none of the three, the suite refuses to run rather than reporting a boundary it could not observe — the right failure, but a failure.

______________________________________________________________________

### M9e — The eleven failures the macOS arm found (Status: PENDING)

**Scenario**: the same Journey 7.1. With [M9d](#m9d--on-macos-there-is-nowhere-to-put-the-outside-status-implemented)'s derived root in place, sessions start on darwin and the suite reaches the assertions for the first time. Eleven of them fail, and they are four unrelated things wearing one colour.

The evidence is in [research.md § M9d](research.md#m9d--the-macos-arm-and-the-eleven-failures-behind-it), which is written to be read cold. What follows is only what has to change. Each class is one commit; C is a change to the product and is the one to do first.

| class | checks | what is actually wrong |
| --- | --- | --- |
| A | `check_r1` `check_r2` `check_r8` | the assertion greps `Permission denied`; Seatbelt says `Operation not permitted` |
| B | `check_j6_2` `check_r11` `check_j8_1` `check_r9` | they need `strace`, which the darwin substrate does not carry |
| C | `check_j2_1` `check_j3_1` | the pre-flight writes a canary into `$HOME` when `$XDG_RUNTIME_DIR` is unset — the check is right and the product is wrong |
| D | `check_opencode` `check_pi` | the bun agents cannot read the capture files they were handed, because those now sit somewhere the session is granted nothing |

**C — the pre-flight's canary, which is a defect and not a fixture problem**

- [ ] `lib/preflight.sh` derives its canary location instead of falling back to `$HOME`, and refuses with `cannot verify confinement` rather than proceeding when no location qualifies. **Both halves are measured**: with `XDG_RUNTIME_DIR` unset the canary lands in the home directory, and with it pointing anywhere inside the project assertion 3's confined write *succeeds* and the pre-flight accuses a correctly confined session — `confinement is not enforced: a confined process wrote outside the project.` So the requirement is the same one `outside_root` meets, writable and granted nothing, and the failure mode is worse here because it is the user who reads it
- [ ] The derivation stays inside the pre-flight's budget. It is embedded in every wrapper by `lib/confined-agent.nix` and runs before every agent start, so it may not spend a `nix build` or a second `nono` invocation the way the harness's helper does
- [ ] Whether the answer on macOS is unavoidably under `/Users` is stated, and if it is, `$HOME/.agent-sandbox` — or whatever the answer turns out to be — is enumerated in the leak registry or in `P1`'s accepted-leak list with its justification, and the handbook says starting an agent writes there. This is the same question [M10a](#m10a--close-out-status-pending) already carries for the harness, and the two answers should be the same answer
- [ ] `check_pf`'s arms cover the two new cases: no qualifying location, and a qualifying one that a session is granted. The second is the false-alarm case and it has no coverage today
- [ ] Violation planted and recorded: the canary put somewhere granted, seen to produce the false alarm, reverted

**A — one denial, two spellings**

- [ ] The three checks accept either wording, and the acceptance is derived rather than a second literal — the platform decides which errno its enforcement returns, so a check that lists both is stating a fact about `EACCES` and `EPERM` and should say so in a comment
- [ ] The refusal message a reader sees still names what was refused, not which errno was matched
- [ ] Violation planted: a probe that fails for a reason other than permission, which must still fail the check on both platforms

**B — an instrument per platform, chosen per assertion**

The four sites do not want the same thing, and reading them as one is what makes this look impossible:

| site | what it observes | substitute measured on Linux |
| --- | --- | --- |
| `commit_session` (`check_j6_2`, `check_r11`) | that the denied set is empty, plus a control that the trace is non-empty | nono's supervisor trailer carries the assertion; the control needs replacing, and `git log` already shows the commit happened |
| `check_j8_1` first arm | that a declared surface *was read* | none — no positive observation exists on darwin without disabling SIP |
| `check_j8_1` grant arm, `check_r9` | `--read`/`--allow`/`--write` in the wrapper's `execve` argv | the capability banner on the session's own stderr, which lists mode and path for every grant |

- [ ] The denial-set assertions use `strace` on Linux and the supervisor trailer on darwin, behind one helper, with the platform split in one place. Both feeds are the same code in one binary — Landlock starves it and Seatbelt feeds it, confirmed from the strings in the Linux binary — so this is one property observed two ways, not two properties
- [ ] Every assertion that reads grants out of argv reads the banner instead, on both platforms, so the split shrinks to the denial checks alone. The banner prints hundreds of `/nix/store/` lines and a check must drop them
- [ ] `check_r9`'s control that the wrapper reached the mechanism at all survives the change — the banner exists only if a session started, which is the same proof by another route
- [ ] `check_j8_1`'s positive read arm either finds an observation that works on darwin or **skips on darwin with the reason**, and the gap is named in `docs/HANDBOOK.md` rather than left to be discovered. `check_substrate_denials` is the precedent for the skip and for where the `uname` gate goes
- [ ] Violations planted per instrument: a session that touches something outside its grants must fail through the trailer as it does through `strace`, and a wrapper missing a declared grant must fail through the banner

**D — the captures the bun agents cannot read**

- [ ] `check_opencode` and `check_pi` capture somewhere the session can read, without making their own anti-vacuity control vacuous. `mapfile -t landed < <(find "$project" -mindepth 1 …)` is the control at stake, and capturing into the project satisfies it by construction — so a dedicated subdirectory excluded from that listing, or a pipe through an unconfined reader so the child holds no path at all. **Measured**: the identical command with its capture inside the granted project exits 0 and answers correctly, so this is where the file lives and nothing else
- [ ] The comparison of the fabricated home and of the project excludes whatever the harness itself wrote there, and the exclusion is narrow enough that a real write by the agent to the same directory is still caught
- [ ] Why the two bun agents need this and `claude-code` does not is recorded in a comment: Seatbelt checks by path and bun resolves the path of its own standard descriptors at startup, while Landlock does not re-check a descriptor that is already open
- [ ] Violation planted: the capture put back where a session is granted nothing, seen to reproduce the startup failure

**Closing the arm**

- [ ] The temporary instrumentation is gone — `dbg` from `scripts/validate.sh`, `dbg_watch_start`/`dbg_watch_stop` and their call sites from `scripts/checks/integration.sh`, and the probe step from `.github/workflows/verify.yml`, whose answer now lives in `outside_root`
- [ ] The macOS job green, or every remaining macOS failure named in `docs/HANDBOOK.md` as a coverage gap with the reason it cannot be closed
- [ ] `scripts/validate.sh` passes on both platforms, and the cross-platform reach comparison in the second job runs for the first time
- [ ] `docs/HANDBOOK.md` states the per-platform instrument split, so a reader who runs the suite on a Mac knows which assertions their run does not make
- [ ] FR-11's per-platform enforcement tiers, which [M10a](#m10a--close-out-status-pending) already owes, gain the sentence this task measured: the two enforcements differ in what they *report*, not only in what they permit

**What a fresh session should not redo.** Four things were measured and hold: the pre-flight canary reproduces the macOS symptom on Linux with `XDG_RUNTIME_DIR` unset; nono reports no denials on Linux and enumerates them on darwin from the same binary; the audit trail records no denied paths at all, so it is not a third instrument; and the capability banner carries command-line grants. Four things cannot be closed without a macOS runner and should be answered in one push rather than four: whether the trailer enumerates writes and is complete, whether any positive read observation is possible on darwin, whether the banner prints identically there, and which capture relocation keeps the `landed` control honest.

______________________________________________________________________

## M10 — Documentation

### M10a — Close out (Status: PENDING)

- [ ] `docs/HANDBOOK.md` updated: how to use what landed, the accepted leak **`$XDG_STATE_HOME/nono`** with its justification, and the coverage gap from [plan.md](plan.md#coverage-gap)
- [ ] Known drift entries retired and deleted: the Kafka leftovers, the six leftover variables, `system = "x86_64-linux"` hardcoding, the four devcontainer bind mounts, orphaned `ai.nix`, the stray `^`, missing `scripts/validate.sh`, missing `README.md`, absent `shellcheck`/`shfmt`, absent `statix`/`deadnix`, no `justfile`, and the wrong canonical ref which FR-19 corrects
- [ ] Anything from that list still true is *moved* rather than deleted, so a gap stays a known gap
- [ ] Root `README.md` written: component table taken from the code, one `flowchart LR` for structure, one `sequenceDiagram` per phase including **a refused case of its own** (AGENTS.md §6), checked by eye in both themes
- [ ] The migration path for a consumer with a host-global setup is documented (FR-21) — which half of their setup comes with them and which does not, how to declare the authoring surface once for the machine (FR-25), that the prior-art arrangement granted the authenticating agent's state read-write and that [D14](plan.md#decisions) replaces it, so a migrating consumer knows what they are giving up and what they get back
- [ ] SC-9: for every agent, either the surface reaches every location that agent reads extensions from, or the location it does not reach is **named**. A consumer must not have to find out by experiment which of their own extensions came with them
- [ ] FR-26: why an executable extension is a larger grant than a declarative one is stated, along with the FR-15 route for a consumer who wants their own anyway
- [ ] FR-11: the supported platforms are named, each with the enforcement tier its operating system provides, and a weaker guarantee says so with the difference named
- [ ] FR-14 and FR-12: every claim the automated run cannot reach is listed with its procedure, and the handbook describes what a human runs without restating the assertions anywhere
- [ ] The way to run an agent unconfined — by not invoking the confined entry point — is described rather than concealed (FR-10)
- [ ] Every open question in `spec.md` resolved in place with a one-line outcome, including the two assumptions the plan was still to confirm
- [ ] The handbook names what the automated run cannot reach: an unattended token flow, the second platform, and a consumer's own trust settings for the substituter
- [ ] **Egress is mediated, not restricted**, and the handbook says so rather than letting a reader infer otherwise from the filesystem confinement: raw TCP is denied but arbitrary HTTPS through the injected proxy succeeds, so a session that asks an agent to fetch a package reaches the registry ([M8d](#m8d--pi-and-pre-provisioned-extensions-status-implemented)). The drift entry this task retires is the absence of that sentence, not the behaviour
- [ ] The stranger's copyable command carries `--accept-flake-config`, because the declared substituter is ignored for anyone who is not a trusted user — measured, not assumed ([research.md](research.md#m9--preconditions-for-the-end-to-end-layer-measured-before-it-exists))
- [ ] `docs/CONSTITUTION.md` P1's accepted-leak list amended to its second entry
- [ ] **The harness's own outside reconsidered**, which [M9d](#m9d--on-macos-there-is-nowhere-to-put-the-outside-status-implemented) shipped ahead of its research directive. `outside_root` derives the location from the host rather than naming one, so the mechanism is not in question; the candidate list is. Three things to settle with the directive's answer in hand: whether `$HOME/.agent-sandbox` — a write outside the project, and the last resort on any host without `$XDG_RUNTIME_DIR` or `$RUNNER_TEMP`, which is every developer macOS — is a second accepted leak in P1's list beside `$XDG_STATE_HOME/nono` or something the rule must refuse; whether a macOS location exists that is neither under `/private` nor under `/Users`, which would remove the question entirely; and whether the directory the helper creates should be removed when the suite is done rather than left behind empty. If it stays a leak, it is enumerated with its justification like the other, and the handbook says a verification run writes there
- [ ] `research.md` consolidated to what is still true, per AGENTS.md §1 — the decisions and the criteria kept, the record of how each was checked dropped; the `codex` findings kept, since they are the follow-up feature's head start
- [ ] Touched files formatted and linted per [AGENTS.md](../../AGENTS.md#4-verify-every-change)
- [ ] `scripts/validate.sh` passes

The accepted leak is named precisely here because it was named wrongly for most of this feature's life: the mechanism anchors its supervisory state at `$XDG_STATE_HOME/nono`, and one of the two research rounds asserted `$HOME/.nono`. It is an accepted leak rather than a fixable one because the mechanism refuses to grant any path overlapping its own state root, so relocating it into the project would make the project ungrantable ([D13](plan.md#decisions)).
