# Debugging the macOS arm

Both jobs of `.github/workflows/verify.yml` went green together in run 8, and stayed green in run 9 once the temporary instrumentation came out, which closes this arm.
What the document is for now is the record of how that happened: the failing checks with the output each one actually produced, the harness for reproducing a confined session by hand, and the list of things already ruled out so they are not measured twice.

It is a debugging record, so it holds symptoms and commands.
The findings drawn from them are in [research.md](research.md) § M9d and § M9e, the measures are in [tasks.md](tasks.md) § M9e, and neither is repeated here.
The class letters below are that task's, so a row and its fix are found by the same key.

## Where the arm stands

The workflow is new in `M9`, so no run predates the feature and there is no green macOS run to bisect back to.

| run | commit | Linux result | macOS result |
| --- | --- | --- | --- |
| 1 | `5d221cc` | 34 passed | died in the nix installer, before the suite |
| 2 | `4c362f8` | 34 passed | 23 of 33 failed, no session started |
| 3 | `e189d82` | 34 passed | the same 23, plus the candidate-path probe's answers |
| 4 | `518ed2d` | 34 passed | **11 of 33 failed, sessions start** |
| 5 | `a8316ed` | 34 passed | the same 11, with tracing |
| 6 | `413e849` | 34 passed | the same 11 again |
| 7 | `fb0333b` | **1 of 35 failed** | **3 of 33 failed** |
| 8 | `a1f5ea4` | **35 passed** | **33 passed, 2 skipped** |
| 9 | `d797e91` | **35 passed** | **33 passed, 2 skipped** |
| 10 | `ea5a94f` | **35 passed** | **33 passed, 2 skipped** |

Run 1's cause is worth keeping because it is not this repository's bug: `cachix/install-nix-action@v27` installed nix 2.22.1, whose darwin installer assigns `_nixbld1` the UID 301 that macOS 15 reserves. Nix 2.24.7 moved the range to 351. The action is now pinned.

Run 7 is the first run of the five class fixes — `ec31fbe`, `66edce3`, `937b979`, `61ffb2c` and `fb0333b`, whose intent is in [tasks.md](tasks.md) § M9e.
It moved macOS from eleven failures to three and Linux from none to one.
Classes A, B and C are settled: `check_r1`, `check_r2`, `check_r8`, `check_j2_1`, `check_j3_1`, `check_r9`, `check_j8_1`, `check_opencode` and `check_pi` all pass on Linux, and on macOS every class A, B and C row either passes or skips for a reason the platform forces.

What remained was two root causes, neither of them a confinement defect.
Both were defects in what the checks *measure*, and each is described in its own section below.

**Both were fixed, and run 8 is the run that answered them.**
`d5d333d` moved every capture a confined child inherits into the project (class D); `dc5e938` gave each commit arm a session of its own so the denial assertion covers the commit Journey 6.2 names (class E).
Two plants are owed to the runner rather than to a host, and both are stated where they belong in [tasks.md](tasks.md) § M9e: class D's, because Landlock cannot express it, and class E's literal Ubuntu case, because a NixOS `gpg` is `path_not_granted` and the `execve` fails before the locale read.

Run 8 carried both rows away, and the `platforms` job ran for the first time and passed.
The two macOS skips are the platform's, not the fixes': `check_substrate_denials` because a syscall trace of a confined session is Linux-only, and `check_j8_1` because the substrate carries no tracer and a successful read leaves no observation on darwin.
Both now belong in the usage document rather than here, per FR-14.

Run 9 is the same tree with the temporary instrumentation deleted — the probe step that asked where a state root can live, and the `dbg` and `dbg_watch_*` calls the class C hunt had left behind.
It matters because those deletions touched two checks that had been failing on macOS as recently as run 6: the watcher in `check_j2_1` and `check_j3_1` had *replaced* each check's own cleanup trap, so removing it had to restore the original rather than drop it.
Run 9 answers that both checks still pass on both platforms, so the arm closes on a tree carrying no scaffolding.
It is also the first run whose logs are the suite's own output and nothing else.

Run 10 is `ea5a94f`, the documentation commit that closed run 9's record, and it carries the same counts on both platforms.
It adds nothing to the argument about confinement — the tree it ran is run 9's plus two spec files — and it is here only so that the last recorded run is the one at the head of `main`.
Its two `reach.json` artefacts are the first pair anyone has held side by side, and what they say is under *What the green runs left standing*.

What runs 8 and 9 do not settle is recorded under *What the green runs left standing* below.
The sections that follow it remain the description of what was wrong, kept because the same symptom will read the same way if it returns.

## What the green runs left standing

A green run says the suite agrees with itself on both platforms. It does not say the suite measures everything the spec asks for. Auditing the green runs against the spec found five things, none of them introduced by the class fixes and none of them visible as a failure.

**The cross-platform comparison is weaker than SC-8 reads.** The `platforms` job diffs a per-platform `reach.json` built by stripping every `/nix/store/` string out of each agent's confinement description. Measured here: `filesystem.read` is *entirely* store paths, `filesystem.allow` and `groups.include` are empty, and `nix eval .#leakRegistry` is `[]`. So the artefact that survives the strip is one platform-independent nix expression holding `$WORKDIR` placeholders, `workdir.access` and the state redirection. It can differ only if someone adds a platform conditional under `lib/`. SC-8 asks that "the effective reach observed is the same on both", and an identical description is not an observation of reach.

Run 10's two artefacts confirm this from the product rather than from the reasoning: `diff` over the downloaded `reach-x86_64-linux/reach.json` and `reach-aarch64-darwin/reach.json` reports **no difference at all**, and in both of them `filesystem.read` is `[]` for all three agents — the strip does not thin that list, it empties it. So the job's `diff` compares two files that carry no filesystem grant of any kind.

Worse, and new: the reach the group confers is invisible to *every* artefact-based instrument, not just to the stripped one. `nono profile show --format manifest --json` over the shipped description lists no non-store grant whatsoever, while `nono -s why --path /usr/bin --op read` against the same description answers `{"status":"allowed","reason":"granted_path"}`. A comparison built by diffing descriptions or manifests therefore cannot see the one thing the two platforms differ on, however it is filtered. Only `nono why`, asked path by path, sees it.

The per-platform `check_sc1` equalities do read the resolved grant, but each subtracts a floor derived by resolving a `{meta}`-only description — and the floor is exactly where the platform difference lives, since nono's `system_read_macos` grants `/private` and `system_read_linux_core` grants `/usr/bin` and two dozen more wherever they exist on the host. The one thing that differs between platforms is therefore subtracted on both sides of every equality. The host-dependence of that grant is already carried to `M10a`; its consequence for FR-20 and SC-8 is what is new.

**The same job can pass having compared nothing.** Its two guards catch a missing report and an empty one, but `for a in $(nix eval …)` cannot trip `set -e`, and `jq -s add` over no input writes `null` — five bytes, which `[ ! -s "$r" ]` accepts. A broken evaluator on both runners is a pass. The step's comment also claims the surviving artefact carries "whatever the leak registry justifies", which is precisely what the store-path strip removes; it reads as true today only because the registry is empty.

**Journey 8.1 is measured by a different instrument than the spec names.** The scenario's *Independently verifiable by* is "asking the agent to enumerate what it loaded", which needs no tracer and works on both platforms. `check_j8_1` instead observes the read with `strace`, which is why it skips on darwin. `check_opencode` and `check_pi` do enumerate, and both passed on darwin, so arrival for `opencode` is in fact covered there by another check. What darwin genuinely loses is arrival for `claude-code` and `pi`, and the absence-of-neighbours arm for all three — less than the skip message claims.

**`check_r9`'s `nohost` arm depends on a fallback it does not document.** The arm plants the host description at `$home/.config/nono/profiles/host.json` while the session runs with `XDG_CONFIG_HOME=$outside/cfg`, and nothing creates that directory. The arm works because nono then falls back to the host's `$HOME/.config` behind a warning, which is where the description is. Should anything ever create `$outside/cfg`, the arm goes vacuous silently.

**The integration checks do not accept the flake's own configuration, and only macOS says so.** Run 9's darwin log carries 44 `ignoring untrusted flake configuration setting 'extra-substituters'` warnings, all 44 between the `SKIP  check_j8_1` line and its reason, because `run_check` prints a skipping check's captured output. They are 22 nix invocations × 2 settings. The cause is a split nobody declared: `scripts/checks/e2e.sh` passes `--accept-flake-config` at all thirteen of its nix call sites and `verify.yml` passes it at both of its own, while none of the 21 `nix eval` and `nix build` sites in `scripts/checks/integration.sh` pass it. On Linux the runner's user is trusted, so the setting applies and nothing is printed; on macOS it is not, so the declared substituter is ignored and those invocations resolve against `cache.nixos.org` or build from source instead.

The consequence is speed and noise rather than correctness, since the ignored settings are a substituter and its key — what gets built is unchanged. But it means the darwin job is not exercising the substituter path the flake declares, and it is why the darwin job runs about four minutes longer than the Linux one (17m36s against 13m44s in run 9). Deleting the probe step took the warning count down from roughly 180 to 44; the remaining 44 are the integration checks' own.

## Reproducing a confined session by hand

On Linux, from the entered environment. The profile is built once:

```sh
PROFILE=$(nix build --no-link --print-out-paths .#confinement-claude-code)
ST=/some/writable/path/outside/the/project     # nono's own state root
mkdir -p "$ST/nono/audit" && : > "$ST/nono/audit/ledger.ndjson"
env -u NONO_AUTO_MIGRATE -u NONO_CAP_FILE \
  TMPDIR="$PWD/.tmp/t" XDG_STATE_HOME="$ST" NONO_NO_UPDATE_CHECK=1 \
  nono run --profile "$PROFILE" --workdir "$PWD" --allow-cwd -- <cmd>
```

Four preconditions, each of which produces a misleading failure when missed:

- `TMPDIR` inside the project, or the child cannot write its own temporaries.
- `XDG_STATE_HOME` at a writable path outside the project that no group grants, which is the accepted leak `$XDG_STATE_HOME/nono`.
- `ledger.ndjson` existing **before** the run. A post-child migration failure replaces the child's exit status with `1`, which silently corrupts any assertion about what the child returned.
- `/nix/store` granted read, or `/bin/sh` exits 127.

Two more traps, both found the slow way:

- `NONO_NO_UPDATE_CHECK=1` or almost any invocation makes a network call.
- `XDG_CONFIG_HOME` must **exist** before nono runs, or it falls back to the host's `$HOME/.config` behind a warning.

A confined session cannot use its own `$HOME` as a control, because the session doing the measuring is itself confined.
Use a path the outer session can read and that `nono -s why --profile "$PROFILE" --op readwrite --json <path>` reports as `{"status":"denied","reason":"path_not_granted"}`, which is the same standing `$HOME` has for the profile under test.
`nono why` exits 0 whichever way it answers, and a query it could not answer still says `denied` with a `*_unavailable` reason, so read `.status` **and** `.reason`.

## Running and attributing one check

`scripts/validate.sh` has no `--check` filter, and `run_check` prints a passing check's output nowhere, so a diagnostic in a green check is invisible.
To run one check with its output on stderr, write a harness under `.tmp/` that re-declares validate.sh's `die`, `fail`, `pinned_bin`, `outside_root` and `SKIP_STATUS`, sources the four layer files, and calls the one function with `</dev/null` — the redirect is load-bearing, because an agent in print mode otherwise drains the caller's input.

Two techniques attribute a denial to a phase and a program, and both apply to any traced check:

- **Trace `execve` beside `openat`.** `-e trace=openat,execve` turns the trace into a process census, which is what distinguishes a nix-linked binary from a host one. Flagging every `execve` whose path is outside `/nix/store` found the single host binary in a 170-line span.
- **Put phase markers in the probe.** `mark() { : <"/AGENTSANDBOX_MARK_$1" 2>/dev/null || true; }` opens a path that cannot exist, so it leaves a labelled boundary in the trace and every syscall buckets into an arm. A span is then extracted with `awk '/MARK_PLAIN_COMMIT_DONE/ { exit } /MARK_PLAIN_COMMIT/ { on = 1 } on'`.

Both are temporary instrumentation and neither is in the tree.

## Reading a CI log

Run artifacts are not kept in the repository. Fetch them:

```sh
gh run list --workflow verify.yml              # find the run
gh run view <id> --log > .tmp/verify.log       # both jobs, gitignored and denied to a session
```

- Strip the timestamps first: `sed 's/^2026[^ ]* //'`.
- `run_check` prints a check's output **only when it fails or skips**, so a diagnostic added for a failure on one platform is invisible on the platform where the check passes.
- A macOS log is roughly twice the Linux length for the same suite, because nono prints its whole capability table to each session's stderr and every failure message quotes it. That bulk is the evidence, not noise: the capability banner and the supervisor trailer are the two instruments darwin has.
- The rest of a darwin log's bulk is not evidence. Filter it with `grep -vE "ignoring untrusted flake|Pass '--accept-flake-config'"` before reading, or a skipping check's reason is buried under its own nix warnings — in run 9 the `check_j8_1` reason sits 44 lines below the `SKIP` that introduces it.
- Any `nix` command run from a shell that has not entered the environment dies with `cannot open SQLite database … fetcher-cache-v4.sqlite`, because `XDG_CACHE_HOME` still points into the denied `$HOME`. Prefix with `direnv exec .` and it evaluates. This was first read as an intermittent evaluator fault; it is not intermittent and it is not a broken checkout, it is the wrong shell. Whether `nix build .#nono.src` itself succeeds inside the environment has not been retested, so nono's behaviour is still established from its binary and its own subcommands.

## What run 7 left

| check | platform | what the log shows | root cause |
| --- | --- | --- | --- |
| `check_j6_2` | Linux | `producing the commits reached for something outside the session:` `/usr/share/locale/locale.alias` | the traced span includes the demand arm, which execs host `gpg` on purpose |
| `check_j6_2` | macOS | the same message, naming `probe.err (read)` and `probe.out (read)` | class D — the capture sits outside the granted set |
| `check_opencode` | macOS | an 8-path trailer refusing `paths.out`, `paths.err`, the scratch directory and every ancestor up to `/Users`, all as **reads** | class D |
| `check_pi` | macOS | the same, 3 paths | class D |

Two checks also skip on macOS, both for a reason the platform forces rather than a defect: `check_substrate_denials` because a syscall trace is Linux-only, and `check_j8_1` because a successful read leaves no observation on darwin.

### The Linux regression: the demand arm is inside the span

`check_j6_2` and `check_r11` share `commit_session`, which runs two arms in one confined session — a **plain** commit that must succeed unsigned, and a **demand** arm that sets `commit.gpgsign true` and must be refused.
Commit `61ffb2c` widened the tracer from the plain commit alone to the whole session, so that the strace span would match the span nono's darwin trailer observes.
That pulled the demand arm inside the span, and the demand arm is *designed* to reach for signing material and fail.

Journey 6.2's third Then scopes the claim to the plain commit — "nothing outside the session's reach was read in order to produce **it**" — so a denial earned by the demand arm is not J6-2's to report.

The chain, measured on a NixOS host with `-e trace=openat,execve` and phase markers:

- `git commit` in the demand arm execs `gpg` by name from the inherited `PATH`, which `session_env` never sets, so it ends in host entries.
- On ubuntu-latest that resolves to `/usr/bin/gpg`, which the profile **grants** (`nono -s why … --path /usr/bin/gpg --op read` answers `granted_path`), so gpg starts. Its glibc startup calls `setlocale`, which opens `/usr/share/locale/locale.alias` — `path_not_granted` — and Landlock returns `EACCES`.
- On a NixOS host `gpg` resolves to `/run/current-system/sw/bin/gpg`, which is **not** granted, so the `execve` fails outright. No gpg process exists, so no locale read is ever attempted and the check passes.

The check therefore fails only where the profile grants the gpg that `PATH` happens to find.
It is not the file's mere presence on Ubuntu: nix glibc has no `/usr/share/locale` compiled into it at all (`strings -a libc.so.6` gives only store-relative locale paths), so no nix-linked binary in the session could have produced that open.

Measured directly on the same run: the whole-session span yields the denial, while the plain-commit span alone yields `[0 paths, from 170 traced lines]`.
Narrowing the span back to the plain commit is what J6-2 asks for and is sufficient.

### The macOS remainder is one cause, not three

All three macOS failures are class D, described in [research.md](research.md) § M9e.
`check_j6_2` joins `check_opencode` and `check_pi` because its `probe.err` and `probe.out` are captures in the same position: outside the granted project, and named by the trailer as refused **reads**.

The noise floor `commit_session` subtracts on the darwin branch cannot cancel them.
The floor session redirects to `/dev/null` and `noise.err` while the measured session redirects to `probe.out` and `probe.err` — different filenames — and the subtraction is `grep -vxF`, which matches whole lines exactly.
A floor can only cancel a path it also produced.

That floor is also asymmetric: `ARMS_NOISE` is set unconditionally, but the file behind it is only ever created on the darwin branch, so on Linux the subtraction has nothing to subtract.
Harmless today, because only the darwin branch consumes it, and worth removing rather than remembering.

## History: the eleven failures of runs 4 to 6

Run 7 resolved all of these; they are kept because the reasoning cost more than the fixes did.
Line numbers are from `scripts/checks/integration.sh` as of `413e849` and have since drifted.

| check | class | what the log showed | cause |
| --- | --- | --- | --- |
| `check_r1` | its own | `DBG r1 shipped: EPERM wording present: 1`, **and** `the probe cannot read the key even when the boundary grants it (exit 1)` | asserts `Permission denied` at :525, and its granted arm requires a behaviour only Landlock has |
| `check_r2` | A | `DBG r2 shipped: uname=Darwin errno wording: Operation not permitted/` | asserts `Permission denied` at :651 |
| `check_r8` | A | `cat: …/secret.txt: Operation not permitted`, beside its auth arm's `HTTP/1.1 401 Unauthorized` | asserts `Permission denied` at :2937 and :2941 |
| `check_j2_1` | C | `the session changed the home directory outside the leak registry`, with `DBG j2_1 home diff: 1c1` | the pre-flight's canary, `lib/preflight.sh:35` |
| `check_j3_1` | C | `two concurrent sessions shared state in the home directory` | the same canary |
| `check_j6_2` | B | seven `DBG substrate tracer <t>: absent` lines, then `the substrate for claude-code provides no strace` | `commit_session` required a tracer at :3444 |
| `check_r11` | B | the same message, though it never reads the trace | it calls `commit_session` and inherited that guard |
| `check_j8_1` | B | the same tracer refusal | needed a positive read observation at :4148, and read `--read`/`--allow` out of `execve` argv at :4230 |
| `check_r9` | B | the same tracer refusal | read `--read`/`--write` out of `execve` argv at :4434 |
| `check_opencode` | D | an 8-path trailer refusing the capture and every ancestor | the capture sits outside the granted project |
| `check_pi` | D | the same, 4 paths | the same |

`check_j7_1` keeps a project-local directory deliberately, because it starts no session.

Two of them deserved their diff rather than a summary, because the size column is what identified them.
`check_j2_1`'s home changed only in its own mtime — `1787564526.678024061` to `1787564531.437078681`, size 128 on both sides, with the fixture's `.claude` and its 26-byte `.claude.json` untouched.
`check_j3_1`'s home was **empty** throughout and still reported as shared state, mtime `1787564580.359287508` to `1787564581.834609547`, size 64 both sides.
A transient file created and removed inside a directory moves that directory's mtime and leaves nothing behind, which is exactly what the pre-flight canary does and why the two checks accused a session that behaved.

`check_r1` is the row the class map got wrong.
Its wording assertion was the smaller of two defects: nono protects `$HOME/.ssh` of its own accord, so a key refused inside a session said nothing about the project boundary, and the granted arm asserting that the key becomes readable when granted encodes Landlock's answer as the requirement — macOS keeps it `[permanently restricted]` and cannot pass.
Deleting the wording assertion alone would therefore have left the check red.

One symptom in run 6 was an artifact of the debug instrumentation rather than a defect: `check_j3_1`'s second message, `expected one session record per concurrent agent session, found 3`, was the temporary third session the tracing block started before the record scan.

## The instruments, per platform

| instrument | Linux | darwin | observes |
| --- | --- | --- | --- |
| `strace` | present, from `flake.nix` under `lib.optionals isLinux` | **absent**, as are `ltrace dtruss ktrace dtrace sc_usage fs_usage` | syscalls, so denials and permitted reads both |
| nono's supervisor trailer | absent — `No path denials were observed during this session.` | present, `N paths blocked` with a line per path | denials only |
| nono's capability banner | present | present, identically | grants only |
| nono's audit trail | present | present | grants only, and mode-blind |

Both trailer strings live in the one Linux binary — `grep -a -c` on nono 0.74.0 finds `paths blocked` once and `No path denials were observed` once — so this is one reporting path that Landlock starves and Seatbelt feeds, not two features.

A trailer, verbatim, from `check_r2`:

```text
2 paths blocked
  /Users/runner/.CFUserTextEncoding (read)
  /Users/runner/work/_temp/agent-sandbox-r2.R03Y9w/home/outside/created.txt (write)
```

`check_r1`'s second line is `…/home/.ssh/id_ed25519 (read)  [permanently restricted]`, with the trailer adding `1 path is permanently restricted — override via a user profile with filesystem.bypass_protection.`
Trailers also print a `Fix flags:` line spelling the `--read`/`--read-file`/`--write` that would grant each blocked path.

The banner, with `--read`, `--allow` and `--write` given three different paths:

```text
   r+w  …/out/rw (dir)
   r    …/out/ro (dir)
   w    …/out/wo (dir)
```

## Ruled out — do not measure these again

- **The audit trail as a denial instrument.** With the denied path kept out of argv and the environment, `$XDG_STATE_HOME/nono/audit/<id>/audit-events.ndjson` held only `session_started` and `session_ended`. `nono audit show <id> --json` offers `command_policy_events`, `network_events`, `tracked_paths` and `merkle_roots`, none of them filesystem denials.
- **The audit trail as a read observation.** After a confined session read a file under a granted directory, `tracked_paths` did not list it, while the project directory and all ~130 `/nix/store` closure roots were there. It is the granted set under another name.
- **The audit trail as a grant instrument.** `tracked_paths` lists `--read`, `--allow` and `--write` paths identically, so it cannot serve the argv assertions.
- **A positive read observation on darwin at all.** `dtruss` needs SIP disabled and `fs_usage` needs root, neither available to a CI runner or acceptable to ask of a user.
- **Piping the captures through an unconfined reader.** Landlock does not re-check an already-open descriptor, so a Linux run proves nothing about whether bun resolves a pipe's path at startup on darwin. Unverifiable from here, and the project-subdirectory alternative is already supported by the run's own trailers.
- **`nix build .#nono.src`.** Read the binary instead. The SQLite failure that first ruled this out was the wrong shell rather than the build, so the ruling stands on cost rather than on impossibility.
- **`NONO_CAP_FILE` as a capability-set instrument.** `--cap-file` is an *input* nono reads, a fully-resolved specification mutually exclusive with `--profile`, not an output it writes.
- **`nono profile show --format manifest` for what a session was granted.** It resolves a description, not a session.
- **Reproducing the Linux `check_j6_2` failure on a NixOS host.** It cannot happen there. The denial requires the profile to grant the `gpg` that `PATH` finds, and on NixOS that is `/run/current-system/sw/bin/gpg`, which is `path_not_granted`, so the `execve` fails before any locale read. Attribute it from the `execve` census instead, which works on either host.
- **The presence of `/usr/share/locale/locale.alias` on Ubuntu as the explanation.** It is a precondition, not the cause. Every process in the session opens `locale.alias` at glibc startup, and the nix-linked ones resolve it inside their own store path, where it is granted. What distinguishes Ubuntu is which binary is running, not which file exists.

## Risks still open

- **`check_j1_1` fails on someone else's traffic.** It resolves `github:GRBurst/agent-sandbox` through the GitHub API, which allows sixty unauthenticated calls an hour per address. Four or five suite runs in an hour exhaust the quota and the check then reports `unable to download … HTTP error 403` with a rate-limit body, which reads as a broken end-to-end path and is not one — observed here after the audit's repeated runs, with `api.github.com/rate_limit` confirming `remaining: 0`. A shared address exhausts it faster. Pinning the ref to a revision would resolve without the API, at the cost of the check no longer proving that *`HEAD`* is consumable, which is the thing FR-19 cares about. `M10a` carries the choice.
- **A host-dependent check is a check that lies.** `check_j6_2` passed on a NixOS developer host and failed on ubuntu-latest for a reason neither host states, because the outcome turned on what `PATH` resolves `gpg` to. Narrowing the span fixed that instance. The general hazard is larger than `PATH` and is now measured: nono's own `system_read_linux_core` group grants read over `/bin`, `/usr/bin`, `/lib`, `/etc/ssl` and two dozen more **for every one of them that exists on the host**, while the shipped description declares `groups.include: []`. The same description is therefore a different boundary on every machine, and `flake.nix`'s sentence about `PATH` and grants is not true of a host that carries `/usr/bin`. `M10a` carries it.
- **Two plants are owed to a runner, not to a host.** Class D's — the capture put back outside the granted set — cannot bite on Linux at all, because Landlock does not re-check an already-open descriptor; that invisibility is why the class survived six runs. Class E's literal case needs a `gpg` the profile grants. Both are stood in for by weaker plants that do run here, recorded in [tasks.md](tasks.md) § M9e.
- **`find -printf` is GNU-only, and its absence is silent.** `check_opencode` and `check_pi` build their home manifests with it. Where it is unsupported both manifests are empty and the comparison passes having compared nothing.
- **`check_opencode`'s `landed` control is partly self-satisfied**, because the check seeds the skill-surface file into the project before the session runs. 22 of the 23 entries measured were the session's own, so it is not vacuous — but it does not assert what it says.
- ~~`check_r9`'s `nohost` plant is unrun.~~ Run and proven. Granting `$home/skills/gamma` to the `nohost` arm alone fails the check for all three agents, each naming the added line: `deleting the host confinement description changed what the claude-code session was granted, so configuration outside the boundary decided the boundary: 132a133 > r+w …/home/skills/gamma (dir)`. What had defeated three earlier attempts was running `nix` outside the entered environment, not an intermittent evaluator.
- `outside_root` is only as good as its three-candidate list, and its last candidate writes under the real home. `M10a` carries this.
- The `+`-summarised group paths are never passed on to `check_r9`'s replayed session, so the FR-21 arm asserts unreadability of a session that was never granted them. Reading the grant off argv had the same hole, so this is inherited rather than introduced.
- The cross-platform reach comparison job ran for the first time in run 8 and passed again in run 9, but what it compares cannot express a platform difference and can pass having compared nothing. Both are described under *What the green runs left standing*.
- **The integration checks ignore the flake's declared substituter wherever the user is untrusted**, which on the macOS runner is every one of them. It costs time rather than correctness, and it is the only reason a green darwin log still carries 44 warnings. Described in the same section; `M10a` carries it.
