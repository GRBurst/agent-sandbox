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
- The pre-flight passes no `--allow-cwd`, and it does not need to because it writes nothing inside the project — its canary is deliberately outside. **The reason first recorded here was wrong** and is corrected in place: `workdir.access = "readwrite"` sets what the working-directory consent is *worth*, not whether it was given, so without `--allow-cwd` a non-interactive session reaches no part of the project at all. `M4b` measured that, and the agent wrapper passes the flag for exactly that reason. `die` spells the Landlock version constraint `>=` rather than `≥`, so the message a user reads survives a terminal without the glyph.

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
- **`--allow-cwd` is the consent; `workdir.access` is only the level.** Without the flag a non-interactive session is granted no part of the project, and a confined write inside it silently leaves no file. The wrapper passes it, and `M4a`'s note giving `workdir.access` as the reason the pre-flight can omit it is corrected above.
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

### M5f — A host-global configuration does not reach an undeclared session (Status: PENDING)

**Scenario**: Journey 8.2

This task was written against R9 and is now the *undeclared* half of the pair R9 became. A machine with no declaration is the state every consumer starts in and the only state a stranger is ever in, so it belongs here, with the rest of the boundary, and needs none of the mechanism `M8f` builds. R9 itself is the declared half and is a difference between two runs, which is why it moved to [`M8g`](#m8g--the-declared-surface-is-exactly-what-arrives-status-pending).

**RED**: `check_j8_2` plants a whole host-global agent configuration in the fake `$HOME` — an authoring surface among it — declares nothing, and compares the session's granted reach to `{project} ∪ registry`.

- [ ] Check written and seen to FAIL
- [ ] The assertion is the **set equality**, not the absence of an error. `~/.agents/skills` and `~/.claude/skills` were measured being read `$HOME`-relative rather than through any XDG variable, so an extension can reach a session that granted nothing and "no grant was added" has to be observed instead of inferred ([D17](plan.md#d17))
- [ ] The agent starts, works, and reports none of the planted extensions — rather than failing on their absence (FR-21)
- [ ] **Control**: an extension planted *inside* the project is reported in the same session, so "none of them arrived" cannot be satisfied by an agent that reports nothing at all
- [ ] Violation planted (the wrapper reads the declaration from a file inside the project instead of the calling environment), seen to FAIL, reverted, recorded in plan.md

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
- [ ] Every root the agent will write to is covered, not only the ones the devShell happens to redirect. `opencode debug paths` reports `home data bin log repos cache config state tmp`, and `state` was measured resolving to `$HOME/.local/state/opencode` inside the environment, because [D13](plan.md#d13) leaves `XDG_STATE_HOME` on the host on purpose. Inside a session that path is denied, so the agent **fails instead of relocating** — the case `M1f` named as the worst of both
- [ ] The state root is redirected in the session's `set_vars` rather than in the shell hook, which is what makes it safe: the supervisor resolves its own protected state root from the ambient value before the child's environment applies, so the child can be moved without making `$WORKDIR` ungrantable ([D13](plan.md#d13)). Asserted by observation, not by assuming the two resolutions are independent
- [ ] **Control**: the writes are found where they were redirected to, under `$WORKDIR`, so an agent that wrote nothing at all cannot pass as state landing in the project ([D9](plan.md#d9))
- [ ] Violation planted (drop the state variable), seen to FAIL, reverted, recorded in plan.md
- [ ] Violation planted (redirect every root **except** `state`), seen to FAIL, reverted, recorded in plan.md — a per-root check is the only kind that bites here, since a single blanket variable leaves exactly this hole

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

### M7f — A commit needs no key (Status: PENDING)

**Scenario**: Journey 6.2, R11

Unsigned commits are the default, and a key that is genuinely needed arrives from an agent or a secret service rather than from a granted directory ([D16](plan.md#d16)). Not hypothetical: every commit made while implementing this feature failed exactly this way — `M3c`, `M3d`, `M4a` and the `M4b` precondition commit, four for four — `gpg` denied its temporary file beneath `$HOME/.gnupg`, and `git` then reporting `fatal: failed to write commit object`. It fires on the first commit, so a consumer meets it immediately.

**Which half of this task those failures belong to has been measured, and it is the half FR-24 configures away.** The demand comes from the *global* `~/.gitconfig`; under [D11](plan.md#d11)'s redirection the setting is not present anywhere, and a commit in a throwaway checkout then succeeded unsigned with no override. So `check_j6_2` is expected to pass on the mechanism already shipped in `lib/confinement.nix`, and the RED it starts from is the absence of the check rather than a missing capability. `check_r11` correspondingly **must set its demand in the checkout's own `.git/config`** — a demand set globally is erased by `GIT_CONFIG_GLOBAL`, so a check that plants it there would assert nothing and still pass. That is what makes the criterion's wording *a checkout whose own configuration demands a signature* load-bearing, and it is the first thing to get right when this task starts.

**RED**: `check_j6_2` and `check_r11`, in one session, each the other's control ([D9](plan.md#d9)).

- [ ] `check_j6_2`: a commit made inside the session exists afterwards, carries no signature, and the configuration this environment wrote is confirmed not to ask for one (FR-24)
- [ ] `check_r11`: in a checkout whose *own* configuration demands a signature, the commit fails, the message names the key material that could not be reached, and no commit object was created
- [ ] The two run in the same session and stand as each other's control — `check_r11`'s failure is attributable to the demand only because `check_j6_2` committed successfully beside it
- [ ] Neither check grants a key store, and this task leaves the leak registry unchanged; `check_sc1` is re-run to prove it
- [ ] `bash scripts/validate.sh --layer integration` passes
- [ ] Violations planted for both checks, seen to FAIL, reverted, recorded in plan.md

Where a consumer does want signatures, the route is the forwarded socket [D16](plan.md#d16) names, supplied at invocation under FR-15. This task does not build that route: it fixes the default and makes the refusal legible. Building it is a new feature number, not an extension of this one.

______________________________________________________________________

## M8 — The remaining agents

`claude-code` is already confined, from `M4b`. What is left is its own awkward corners, then the two agents that depend on it. The order is `claude-code` → `opencode` → `pi`, and it is the order [D14](plan.md#d14) forces rather than a preference.

The consumer's own authoring surface (FR-25) closes this group rather than opening it. It has to be enumerated per agent before it can be granted for any, so it depends on all three being confined — which is also why `M5f` keeps only the undeclared half, the half that needs no mechanism at all.

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
- [ ] `opencode debug paths` is the observable, and **every** root it reports lands under `$WORKDIR`. Run inside the environment it already reports `state` under `$HOME`, which `M6a` fixes for the agent table; this task is where the claim is checked for `opencode` specifically, against the agent's own answer rather than against a list of variables
- [ ] It takes its credential from the mediated route, and no grant on `claude-code`'s state is added to make it work ([D14](plan.md#d14))
- [ ] Seen to FAIL before the fix

Two roots were measured to relocate cleanly and one not. `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` and `TMPDIR` are all honoured, and credentials are already separated from settings by directory: `auth.json` and `mcp-auth.json` sit under the data root with `opencode.db`, `storage` and `log`, while the config root holds only settings and extensions. `XDG_STATE_HOME` is honoured too — a probe pointing it at a scratch directory moved `state` there — which is why [D13](plan.md#d13)'s deliberate host value is a hole rather than a non-issue. Reading the binary for variable names yielded nothing, the bundle being compiled; occurrence has now failed to predict this agent's behaviour as often as it failed for `claude-code`.

`opencode`'s base URL is a config key rather than a variable — `provider.<id>.options.baseURL`, with config winning over the environment — so pointing it at the mediated route is a file this environment writes, not a variable it exports.

### M8d — `pi`, and pre-provisioned extensions (Status: PENDING)

**Scenario**: Journey 2.1 for `pi`, plus FR-22.

Shaped by `M1d`: relocation holds through the single variable `PI_CODING_AGENT_DIR`, so `pi` needs no registry entry. `PI_CODING_AGENT_SESSION_DIR` does not exist and is not set.

- [ ] Extensions provisioned through Nix before the session, never fetched from inside it (FR-22)
- [ ] `PI_OFFLINE` is set, because `pi` installs missing packages automatically on startup, and its own install path reached the registry even under that variable — which disables startup operations only
- [ ] It takes its credential from the mediated route, via `providers.<id>.baseUrl` in the file this environment writes ([D14](plan.md#d14))
- [ ] The path for a consumer who must install an extension — outside the confined entry point — is documented rather than left to be discovered
- [ ] Seen to FAIL before the fix

### M8e — Spike: where does each agent read its declarative extensions from? (Status: PENDING)

**Scenario**: none — a spike. It exists because this feature has now been wrong three times about a location by reading rather than measuring, and FR-25 cannot be implemented against a guess.

**`opencode` is already measured, in [research.md](research.md) § `M8e`.** That section is a partial answer to this task's question, written when the requirement was drafted, and this spike starts from it rather than re-deriving it: the six skill roots and which are `$HOME`-relative, the two-arm differential that proved the blanket `XDG_CONFIG_HOME` hides the config root while `~/.agents` survives it, the `skills.paths` mechanism and the `OPENCODE_CONFIG_DIR` trap beside it, and the split of `~/.config/opencode` into a surface half and an executable half. What remains is `claude-code` and `pi`, whose layouts are **unmeasured** because the session that went looking was itself confined and got `Permission denied` on `~/.claude`, `~/.config/pi` and `~/.pi`.

Do not trust an agent's own listing command alone for the two unmeasured ones. `opencode debug skill` reports what it *resolved*, so a root that was denied and a root that was empty look identical from outside — which is the mistake this spike exists to stop making.

**Question**: for each of the three agents, which locations does it read declarative extensions from, which of those are `$HOME`-relative rather than XDG-derived, and what is the sanctioned way to name an additional root?

- [ ] Every location enumerated per agent, by observation — the agent's own listing command where it has one, `strace -f -e trace=openat` where it does not
- [ ] Each location classified: authoring surface (FR-25) or executable extension (FR-26). For `opencode` this splits `~/.config/opencode` rather than granting it, since the same directory holds `plugin/` and `node_modules/`
- [ ] The redirection interaction recorded per location: which survive the blanket `XDG_CONFIG_HOME` ([C1](plan.md#c1)) because they are `$HOME`-relative, since those are the ones that can arrive without being declared
- [ ] For each agent, the mechanism that names an extra root, and whether it covers the whole surface. `opencode`'s `skills.paths` does for skills; `OPENCODE_CONFIG_DIR` does **not**, because the documented list is agents, commands, modes and plugins with skills absent — a mechanism that covers part of a surface while looking like it covers all of it is the failure mode here
- [ ] Findings written to `research.md`, and [D17](plan.md#d17) corrected where they contradict it

### M8f — A declared authoring surface arrives (Status: PENDING)

**Scenario**: Journey 8.1

**RED**: `check_j8_1` declares an authoring surface holding one extension per location `M8e` enumerated, starts a session, and asks the agent to report the extensions it has.

- [ ] Check written and seen to FAIL
- [ ] The declaration comes from the calling environment, never from a file inside a project — the same channel as `source_up_if_exists`, which keeps R5 intact by construction ([D17](plan.md#d17))
- [ ] The grant names the enumerated authoring directories individually and **no ancestor of them**, so nothing FR-26 excludes and no credential store arrives with the surface
- [ ] The agent is *pointed* at the granted roots by the configuration this environment writes; nothing is copied into the project, so there is no reconciliation step and no staleness (P8)
- [ ] Second arm: the surface is byte-identical before and after a session that tries to write to it — FR-25 lends it rather than handing it over
- [ ] **Control**: an extension planted at a location that was *not* declared is asserted absent in the same session
- [ ] Both violations planted (remove the configuration key while keeping the grant; make the grant read-write), each seen to FAIL, reverted, recorded in plan.md

### M8g — The declared surface is exactly what arrives (Status: PENDING)

**Scenario**: R9

The half of R9 that needs `M8f` to exist. A grant that brings the surface *and* something else satisfies `M8f` completely, so the property is a difference and one observation cannot carry it — the shape `check_j6_1` and `M4c` both arrived at independently.

**RED**: `check_r9` runs the same planted host configuration twice, once with the surface declared and once without, and subtracts the readable sets.

- [ ] Check written and seen to FAIL
- [ ] The difference set is asserted **equal** to the declared locations, in both directions: `⊇` is the surface arriving, `⊆` is nothing arriving with it
- [ ] Stored credentials, conversation history and session state are planted under the same host root and asserted unreachable in both arms (FR-21)
- [ ] No host confinement description takes part in deciding reach, asserted by comparing granted paths against a run with the host description removed — the self-referential case `M1e` found, where host configuration decides what a session may reach
- [ ] **Control**: the session starts and works in both arms, so an agent that read nothing cannot pass
- [ ] Both violations planted (widen the declaration to the locations' common ancestor; grant the host's confinement description directory), each seen to FAIL, reverted, recorded in plan.md

**Checkpoint**: FR-1 is satisfied; all three agents are confined and `check_sc1` still passes without being edited, which is the property SC-1 asserts. FR-25 holds for every agent, and SC-9's obligation — that any location the surface does *not* reach is named in the usage document rather than discovered by experiment — is carried into `M10a`.

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

**Checkpoint**: `check_sc3` passes for the first time — every scenario has its check, and the bijection is closed. The set it has been naming since [M1a](#m1a--the-scenario--check-bijection-status-done) is empty for the first time. Its size is deliberately not written down here: it was twenty when this line was first drafted, it was already twenty-two, and Journey 8 made it twenty-four. The check derives it from `spec.md`, which is the point.

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
- [ ] `docs/CONSTITUTION.md` P1's accepted-leak list amended to its second entry
- [ ] `research.md` consolidated to what is still true, per AGENTS.md §1 — the decisions and the criteria kept, the record of how each was checked dropped; the `codex` findings kept, since they are the follow-up feature's head start
- [ ] Touched files formatted and linted per [AGENTS.md](../../AGENTS.md#4-verify-every-change)
- [ ] `scripts/validate.sh` passes

The accepted leak is named precisely here because it was named wrongly for most of this feature's life: the mechanism anchors its supervisory state at `$XDG_STATE_HOME/nono`, and one of the two research rounds asserted `$HOME/.nono`. It is an accepted leak rather than a fixable one because the mechanism refuses to grant any path overlapping its own state root, so relocating it into the project would make the project ungrantable ([D13](plan.md#decisions)).
