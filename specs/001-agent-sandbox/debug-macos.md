# Debugging the macOS arm

The `aarch64-darwin` job of `.github/workflows/verify.yml` has never been green.
This document is what a session picking the work up needs in front of it: the eleven failing checks with the output each one actually produced, the harness for reproducing a confined session by hand, and the list of things already ruled out so they are not measured twice.

It is a debugging record, so it holds symptoms and commands.
The findings drawn from them are in [research.md](research.md) § M9d and § M9e, the measures are in [tasks.md](tasks.md) § M9e, and neither is repeated here.
The class letters below are that task's, so a row and its fix are found by the same key.

## Where the arm stands

Linux has reported 34 passed on every run.
The workflow is new in `M9`, so no run predates the feature and there is no green macOS run to bisect back to.

| run | commit | macOS result |
| --- | --- | --- |
| 1 | `5d221cc` | died in the nix installer, before the suite |
| 2 | `4c362f8` | 23 of 33 failed, no session started |
| 3 | `e189d82` | the same 23, plus the candidate-path probe's answers |
| 4 | `518ed2d` | **11 of 33 failed, sessions start** |
| 5 | `a8316ed` | the same 11, with tracing |
| 6 | `413e849` | the same 11 again — every symptom quoted here is from this run |

Run 1's cause is worth keeping because it is not this repository's bug: `cachix/install-nix-action@v27` installed nix 2.22.1, whose darwin installer assigns `_nixbld1` the UID 301 that macOS 15 reserves. Nix 2.24.7 moved the range to 351. The action is now pinned.

Run 6 is the first run of the amended tracing commit, and its failing set is identical to run 5's, so the eleven are stable rather than drifting with each push.
Five commits have landed against them since — `8983986`, `a1cd5f8`, `83c4825`, `f98d91e` and `c1d63b7` — and **none of them has been run in CI**, so every symptom below is still the last thing the runner said rather than the current state of the code.
What each one changed is in [tasks.md](tasks.md) § M9e.

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

## Reading a CI log

Run artifacts are not kept in the repository. Fetch them:

```sh
gh run list --workflow verify.yml              # find the run
gh run view <id> --log > .tmp/verify.log       # both jobs, gitignored and denied to a session
```

- Strip the timestamps first: `sed 's/^2026[^ ]* //'`.
- `run_check` prints a check's output **only when it fails or skips**, so a diagnostic added for a failure on one platform is invisible on the platform where the check passes.
- A macOS log is roughly twice the Linux length for the same suite, because nono prints its whole capability table to each session's stderr and every failure message quotes it. That bulk is the evidence, not noise: the capability banner and the supervisor trailer are the two instruments darwin has.
- `nix build .#nono.src` fails here (`cannot open SQLite database … fetcher-cache-v4.sqlite`), so nono's behaviour has to be established from its binary and its own subcommands.

## The eleven failures

Line numbers are from `scripts/checks/integration.sh` as of `413e849` and drift with every edit to that file — re-derive them rather than trusting them.
The five commits listed above have since moved every one of them.

| check | class | what the log shows | cause | reproducible on Linux |
| --- | --- | --- | --- | --- |
| `check_r1` | its own | `DBG r1 shipped: EPERM wording present: 1`, **and** `the probe cannot read the key even when the boundary grants it (exit 1)` | asserts `Permission denied` at :525, and its granted arm requires a behaviour only Landlock has | the wording, no; the grant, **yes** — on Linux the grant wins and the key reads out |
| `check_r2` | A | `DBG r2 shipped: uname=Darwin errno wording: Operation not permitted/` | asserts `Permission denied` at :651 | no |
| `check_r8` | A | `cat: …/secret.txt: Operation not permitted`, beside its auth arm's `HTTP/1.1 401 Unauthorized` | asserts `Permission denied` at :2937 and :2941 | no |
| `check_j2_1` | C | `the session changed the home directory outside the leak registry: …/agent-sandbox-j2_1.72kP4U/home`, with `DBG j2_1 home diff: 1c1` | the pre-flight's canary, `lib/preflight.sh:35` | **yes**, with `XDG_RUNTIME_DIR` unset |
| `check_j3_1` | C | `two concurrent sessions shared state in the home directory, outside the leak registry: …/agent-sandbox-j3_1.TxVVHQ/home` | the same canary | **yes** |
| `check_j6_2` | B | seven `DBG substrate tracer <t>: absent` lines, then `the substrate for claude-code provides no strace, so what the commit reached for cannot be observed` | `commit_session` requires a tracer at :3444 | no — `strace` is present here |
| `check_r11` | B | the same message, though it never reads the trace | it calls `commit_session` and inherits that guard | no |
| `check_j8_1` | B | the same tracer refusal | needs a positive read observation at :4148, and reads `--read`/`--allow` out of `execve` argv at :4230 | no |
| `check_r9` | B | the same tracer refusal | reads `--read`/`--write` out of `execve` argv at :4434 | no |
| `check_opencode` | D | an 8-path trailer refusing `paths.out`, `paths.err`, the scratch directory and every ancestor up to `/Users`, all as **reads** | the capture sits outside the granted project, and bun resolves its own descriptors' paths at startup | no — Landlock does not re-check an open descriptor |
| `check_pi` | D | the same, 4 paths | the same | no |

`check_substrate_denials` also needs a tracer and already skips on darwin behind a `uname` gate, which is the precedent for the two skips this work adds.
`check_j7_1` keeps a project-local directory deliberately, because it starts no session.

Two failures deserve their diff rather than a summary, because the size column is what identifies them.
`check_j2_1`'s home changed only in its own mtime — `1787564526.678024061` to `1787564531.437078681`, size 128 on both sides, with the fixture's `.claude` and its 26-byte `.claude.json` untouched.
`check_j3_1`'s home is **empty** throughout and still reports as shared state, mtime `1787564580.359287508` to `1787564581.834609547`, size 64 both sides.
A transient file created and removed inside a directory moves that directory's mtime and leaves nothing behind, which is exactly what the pre-flight canary does and why the two checks accuse a session that behaved.

`check_r1` is the row the class map got wrong.
Its wording assertion was the smaller of two defects: nono protects `$HOME/.ssh` of its own accord, so a key refused inside a session said nothing about the project boundary, and the granted arm asserting that the key becomes readable when granted encodes Landlock's answer as the requirement — macOS keeps it `[permanently restricted]` and cannot pass.
Deleting the wording assertion alone would therefore have left the check red.

One symptom in run 6 is an artifact of the debug instrumentation rather than a defect: `check_j3_1`'s second message, `expected one session record per concurrent agent session, found 3`, is the temporary third session the tracing block starts before the record scan.
Removing the instrumentation removes it.

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
- **`nix build .#nono.src`.** It fails in this environment; read the binary instead.
- **`NONO_CAP_FILE` as a capability-set instrument.** `--cap-file` is an *input* nono reads, a fully-resolved specification mutually exclusive with `--profile`, not an output it writes.
- **`nono profile show --format manifest` for what a session was granted.** It resolves a description, not a session.

## Risks still open

- None of the five fixes has been run in CI, so the arm's real state is unknown until the next push. Run 6 is the last measurement, and it predates all of them.
- `check_r9`'s `nohost` plant is unrun, so the one assertion that compares two sessions' capability sets is unproven. Three attempts were defeated by an intermittent `cannot open SQLite database … fetcher-cache-v4.sqlite`, which leaves a check reporting its own anti-vacuity control rather than the planted failure.
- Class D is not implemented, so `check_opencode` and `check_pi` will fail again exactly as they did.
- `outside_root` is only as good as its three-candidate list, and its last candidate writes under the real home. `M10a` carries this.
- The `+`-summarised group paths are never passed on to `check_r9`'s replayed session, so the FR-21 arm asserts unreadability of a session that was never granted them. Reading the grant off argv had the same hole, so this is inherited rather than introduced.
- The cross-platform reach comparison job has never run, because it is gated on both platform jobs passing. Whatever it finds will be found for the first time after these eleven are fixed.
