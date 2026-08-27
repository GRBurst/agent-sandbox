# Constitution

This is the law every change in this repository is measured against.

It is derived from [xp-clean-code](https://github.com/HivemindTechnologies/xp-clean-code) and adapted to a repository whose only languages are Nix, shell and generated JSON.
The adaptation is deliberate and recorded: [Where the upstream skill does not apply](#where-the-upstream-skill-does-not-apply) names every upstream rule that has no meaning here and what stands in for it.
An inapplicable rule that is quietly ignored looks exactly like one that was forgotten, so it gets written down instead.

Principles are numbered so a plan can cite them.
They are non-negotiable defaults.
Deviate only where the plan's Complexity Tracking table names the principle, the need, and the simpler alternative that was rejected and why.

## How this is used

- Every `plan.md` carries a **Constitution Check** gate, filled before the work starts and re-checked before the feature closes.
- A recorded violation is a decision.
  An unrecorded one is a defect.
- Amending the constitution is itself a feature.
  It gets a spec, and the amendment states which principle changed and which landed specs it invalidates.
- The repository has almost no code yet, so most principles bind on the *first* code that reaches each area rather than describing something already true.
  Where a principle names a file that does not exist, the gap is listed in [docs/HANDBOOK.md](HANDBOOK.md#known-drift) rather than assumed to be handled.

______________________________________________________________________

## P1 — Isolation is the product

Most repositories treat "keep tool state out of `$HOME`" as housekeeping.
Here it is the domain, so it is the first principle and the one with the sharpest tests.
Everything this repository ships exists so that one project's agents, credentials, caches and history cannot be seen from another.

- **No program may read or write config, cache, state or temp files outside the project.**
  Derived data lives in `.tmp/` and `.cache/`, both gitignored.
  Committed tool config lives in the repository, next to whatever it configures.
- **A tool that reads `$HOME` gets a project-relative variable, or it does not enter the environment.**
  Prefer the tool's own variable over a blanket `XDG_CONFIG_HOME`.
  The blanket covers neither the tools that hardcode a path nor the ones that read a differently-named variable, and it makes every future tool look handled when it is not.
- **`XDG_CACHE_HOME` is the one blanket that is allowed**, because it holds purely derived data that can be deleted at any time.
- **The bootstrap is the one exception, and it is three variables.**
  `TMPDIR`, `XDG_CACHE_HOME` and `XDG_DATA_HOME` are exported before the environment is evaluated, because the evaluator needs them to read its own configuration.
  The third is there because nix records the flake configuration a user has accepted under `XDG_DATA_HOME`, and writes there before it will evaluate a flake that declares `nixConfig` at all — which this one does.
  It is a blanket, so it is also a violation of the rule above, recorded rather than claimed away.
  The three must **resolve** to the same value in both places, and a check evaluates both files rather than comparing their text: nix's indented strings escape where a shell does not, so byte-identical source is the wrong criterion.
- **`TMPPREFIX` matters as much as `TMPDIR`.**
  zsh writes heredoc bodies to `$TMPPREFIX*` rather than to `$TMPDIR`, so a stale value fails every heredoc with `can't create temp file for here document` while `$TMPDIR` still looks correct.
- **A settings file that cannot expand variables gets absolute paths, and the duplication is checked.**
  Agent configuration whose `env` block is literal, and whose shells never run direnv, has to repeat the variable list.
  Two lists that must agree are a defect unless something fails when they drift.
- **Accepted leaks are enumerated, justified and few.**
  A leak that is written down is a decision; a leak that is discovered is a bug.
  Today there are three, and they are not the same kind of thing: the first is on every path into the environment, the second on the path a confined session takes, and the third only on the path that verifies the repository.
  1. `source_up_if_exists` reads a parent `.envrc` above the checkout, kept because that is a personal, machine-level concern and direnv carries on when the read is denied.
  1. **`$XDG_STATE_HOME/nono`**, where the confinement mechanism anchors its own supervisory state. It is accepted rather than fixed because the mechanism refuses to grant any path overlapping that root, so relocating it into a project would make the project ungrantable — the one leak that cannot be expressed as a grant, and therefore cannot be a leak-registry entry either. Every confined session writes there.
  1. **`$HOME/.agent-sandbox`**, and only on a host offering neither `$XDG_RUNTIME_DIR` nor `$RUNNER_TEMP`. The verification suite needs somewhere outside the project that a confined session is granted *nothing* on, in order to plant a thing and watch a session fail to reach it. It derives that location from the host rather than naming one, and this is the last of three candidates. Nothing a consumer runs writes here — only the suite does — which is what makes it acceptable where the entry above would not be if it were optional.
- **"Local" means the filesystem, not offline.**
  Fetching inputs and downloading tools still need the network.
- **Isolation is asserted, never assumed.**
  Every isolation claim has a check that fails when the claim is broken, and P2 governs how that check earns the right to be believed.

## P2 — Test first, and prove the check bites

Never write production code without a failing check that demands it.

```
RED   → write a check that describes the desired behaviour, and watch it fail
GREEN → make the smallest change that passes it, and nothing more
CLEAN → refactor for clarity, separately, under P6
```

Each phase completes before the next begins.
Mixing them is the main source of configuration that cannot be tested after the fact.

- **What counts as a check, per language.**
  In Nix, a `nix eval` on the value, an `assertions` entry, or a `nix flake check` case.
  In shell, a test case or a check in the repository's validation script.
  In generated JSON, a schema validation or a `jq` assertion against the emitted file.
- **Verify RED.**
  A check that has never failed proves nothing about the code and nothing about itself.
- **The guard rule.**
  When the thing being added *is* a check — a deny rule, a drift comparison, a required-value assertion — the test that demands it must fail when the guard is removed.
  If you cannot make it fail, the guard is untested or unreachable, and you do not yet get to claim it protects anything.
- **Anti-vacuity is that same rule from the other side, and it is where a shell-based check layer rots.**
  A check that greps a file that has since moved, or parses a structure that has changed shape, matches nothing, exits 0, and reports OK.
  A green run then means "nothing was tested", which is strictly worse than a red one.
  So: plant the violation the check exists to catch, watch it FAIL, revert, and record the planted violation in the plan.
- **A check with no recorded planted violation is not finished.**
  This applies with full force to every isolation check under P1, because those are the ones whose failure mode is silence.

## P3 — Scenarios are the success criteria

All non-trivial behaviour is specified as Given/When/Then scenarios **before** any check or code exists.

```
Given  a context or precondition that is true
When   one action or event occurs
Then   an observable outcome results
```

- **The `Then` must be observable.**
  An exit status, a path that exists or does not, a value in generated output, a write that was denied, an empty diff.
  "Works correctly", "is isolated" and "is clean" are not outcomes; they are hopes.
- **One `When` per scenario.**
  Two triggers are two scenarios.
  `And` extends a `Given` or a `Then` rather than cramming conditions onto one line.
- **Every scenario becomes exactly one executable check**, and the check names the scenario it came from, so a failure points at intent rather than at a line number.
- **At least one scenario per feature is a refusal.**
  In a repository whose product is isolation, the interesting behaviour is what must *not* happen: the write that must be denied, the variable that must not resolve into `$HOME`, the state that must not survive a teardown, the credential that must not be visible from the next project.
  A spec with only happy paths has not specified this repository.
- **If you cannot write the scenario, you do not understand it well enough to build it.**
  Stop and ask.
  An unanswered question is marked `[NEEDS CLARIFICATION: the specific question]` and resolved in review, not guessed at.

## P4 — One step at a time

One scenario → one failing check → the minimum change → refactor → commit.

- Never more than one failing check at a time.
- Never implement ahead of a scenario.
  There is no "the option will need this later".
- A task that changes more than roughly 50 lines of Nix or shell is too large, so split the scenario.
  A module option together with its type, its assertion and its check is one step.
- **One task per commit, and a checkbox is ticked only when its command has actually passed.**
  Do not paste output you have not seen.

## P5 — Clean code invariants, in Nix and shell

Configuration is read far more often than it is written, and it is read by someone trying to work out why their environment is broken.

- **Names reveal intent.**
  Option paths read as the domain, not as the implementation.
  No abbreviations the domain does not itself use.
  Predicates read as questions — `hasCredentials`, `isSandboxed` — and shell predicates return a status rather than printing one.
  Shell functions that act are verbs.
- **One thing only.**
  A `let` binding that needs "and" to describe it is two bindings.
  A function that validates and then writes is two functions, and the caller composes them.
- **Comments explain why, never what.**
  The comment worth writing is the one recording why a path must *not* be granted, or why an ordering cannot change, or which of two plausible merge semantics a boundary actually has.
  That reasoning is invisible in the code and expensive to rediscover; the code already says what it does.
- **Delete commented-out code.**
  Version control is the history.
- **Keep it small.**
  A `let` block you must scroll past to find its `in` is too large.
  A shell function longer than a screen is doing more than one thing.
- **No surprise side effects.**
  A function named `check_*` reports and does not repair.
  An expression that computes a value does not also write a file.

## P6 — Refactor as a separate phase

Refactoring improves structure **without changing behaviour**.
It is a distinct, protected phase, not a feature and not cleanup.

- All checks green before it starts, all green when it ends.
- No new option, no new grant, no new variable, no new file in a user's tree.
  Discovering needed behaviour means stopping, writing a scenario, and coming back.
- **Nix gives you a mechanical proof, so use it.**
  Evaluate the configuration before and after and diff the two: `nix eval --json .#<attr> | jq -S .` on each side.
  An empty diff *is* the definition of behaviour-preserving, so a Nix refactor that cannot produce one is not a refactor.
- Smallest safe steps — rename, extract, move, inline — re-checking after each.
- A refactor and a feature never share a commit.
- Do not clean code you did not come to change.

## P7 — Ubiquitous language and modelled options

The domain model is the core.
Structure follows the domain, not the tooling that happens to implement it.

- **One precise name per concept, identical in Nix, shell, docs, specs and conversation.**
  When the docs say *workspace*, the option is not called `env`.
  Divergence between the spoken word and the code is a defect, not a matter of taste.
- **Primitive obsession here is `attrsOf str`.**
  A stringly-typed option that encodes structure is the Nix form of passing five related primitives, and the compiler cannot stop you swapping them.
  Model it as a `submodule` with named, typed fields.
  The option type is the domain contract, and unlike a comment it is checked.
- **Constrain the type to the domain.**
  `enum` where the set is closed.
  `path` where it is a path.
  `nullOr` only where absence is meaningful, per P9.
  `types.str` is the `Object` of Nix and is nearly always a missed modelling opportunity.
- **Boundaries are not shared.**
  Per-agent configuration is a separate model per agent, even where two agents overlap today.
  Merge behaviour at a boundary is part of the contract: a list that appends across bases and a set that replaces on override are different kinds of thing, and assuming the wrong one silently drops whatever the other side declared.
  Write down which it is wherever you rely on it.
- Entities, aggregates and domain events do not apply here; see the exclusions.

## P8 — Purity, effects at the boundary, and idempotency

- **Evaluation is pure, so keep it pure.**
  No `builtins.getEnv`, no `builtins.currentTime`, no unpinned fetch, no `--impure` in anything committed.
  Inputs are pinned and the lock is committed.
  An impure evaluation is not reproducible, and an environment that is not reproducible is not isolated in any sense worth claiming.

- **Effects live in named phases and nowhere else**: build, activation, shell hook, and setup scripts.
  An expression that decides *and* acts cannot be evaluated by a test, which is precisely why P2 is expensive to satisfy in code shaped that way.

- **Compute in `let`, act in one place.**
  Shell functions take arguments and print; they do not read or mutate globals.
  I/O sits at the top level of a script, where it can be seen.

- **Idempotency is mandatory here, not desirable.**
  This repository's job is to set an environment up — from a fresh clone, from a stale one, repeatedly, and sometimes over a half-finished previous run.
  `f(f(x)) = f(x)` for every activation step, every `mkdir`, every generated file, every append.

- **Every state transition gets an explicit double-application scenario.**

  ```
  Given a workspace that has already been set up
  When setup runs a second time
  Then the generated files are byte-identical to the first run
   And no entry is duplicated
  ```

  Appending to a file is the usual offender.
  Generating the file instead is usually the fix.

- **Prefer generating a file over editing one in place.**
  A file this repository writes into a user's tree is declared, so it can be regenerated, compared and removed.
  A file it appends to can only grow.

## P9 — Explicit outcomes, no silent fallbacks

Nix has no `Option` or `Either`.
What it has is `types.nullOr`, `types.enum`, `submodule`, `assertions`, `lib.throwIf`, `lib.warnIf`, and evaluation failure.
The upstream rule survives in that vocabulary: **an outcome the caller may need to distinguish must never be collapsed into a default.**

- **`or` is Nix's silent failure channel.**
  `config.a.b.enable or false` cannot tell "disabled" from "the module is absent" from "the attribute name is a typo", and the typo is the one that costs an afternoon.
  It is permitted where absence is genuinely expected, and then it carries a one-line reason at the site.
  Everywhere else, let evaluation fail, or raise an `assertion` whose message names the fix.
- **A missing required value is an assertion with a sentence a human can act on**, not a default that makes the wrong thing work quietly.
  A default that papers over misconfiguration is worse than a crash, because the environment then comes up *looking* isolated.
- **`mkDefault` is a decision about who may override**, so state it wherever that is not obvious.
- **In shell, the exit status is the `Either`.**
  `set -euo pipefail` at the top of every script.
  `|| true` and `2>/dev/null` each swallow an outcome, and each needs a reason on the line or it is a defect.
- **A `case` over a closed set has no silently-succeeding catch-all.**
  The final branch exits non-zero and prints the unexpected value.
  That is the shell form of exhaustive matching: a new case that nobody handled must fail loudly, and `*) ;;` guarantees it will not.
- **Generated JSON is a boundary representation.**
  Validate it against its schema at the boundary, never hand-edit it, and never let a generator and a human both own the same file.
- **Failures still come in two kinds.**
  Evaluation failure and `throw` are for broken invariants and misconfiguration, where the caller passed something that cannot exist.
  Exit status and reported check results are for expected outcomes the caller can act on.
  A swallowed default reports neither.

______________________________________________________________________

## Where the upstream skill does not apply

| Upstream rule | Status here | What stands in for it |
| --- | --- | --- |
| `Option` / `Either` / `Result` return types | Inapplicable — no such types | P9: `nullOr` and `enum` for absence, `assertions` for failure, exit status in shell |
| Monadic composition, `map` / `flatMap`, `?` | Inapplicable | `lib.pipe` and ordinary function composition in Nix; pipelines under `pipefail` in shell |
| Newtypes with private fields and smart constructors | Partly applies | P7: a `submodule` with typed fields, plus an `assertion` that enforces the invariant once |
| Entities, identity, aggregates, domain events | Inapplicable | Nothing runs, so there is no state to transition or audit. Configuration is values only |
| Immutability by default, frozen dataclasses | Already free | Nix values are immutable. The rule survives only for files on disk, under P8 |
| `mypy --strict`, `pyright`, `clippy` lint gates | Substituted | Module type checking at evaluation, `nix flake check`, `shellcheck`, `shfmt --diff` |
| Exhaustive match, `assert_never` | Substituted | P9: `enum` plus a catch-all branch that fails |
| Banned `unwrap` / `expect` / `RefCell` | Substituted | P9's ban on `or`, `\|\| true` and `2>/dev/null` without a stated reason |
| Test-first, BDD scenarios, small steps, refactor phase | Applies unchanged | P2, P3, P4, P6 |
| Ubiquitous language | Applies unchanged | P7 |
| Idempotency scenarios | Applies, and matters more | P8, because setup is the product |

## Quick reference

```
Before any code:    Write the scenario (Given/When/Then), with an observable Then
Before production:  Write the check and watch it FAIL (RED)
To pass it:         Smallest change only (GREEN)
After green:        Refactor separately, prove an empty eval diff (CLEAN)
Commit unit:        One scenario, green and clean

Isolation:          Nothing outside the project. Own variable per tool, not a blanket
                    Three variables in the bootstrap, resolved rather than compared, checked
                    Leaks are enumerated and justified, never discovered
Guards:             A check earns belief only by failing when its guard is removed
                    Plant the violation, watch it FAIL, revert, record it in the plan
Scenarios:          One When each. Then is observable. At least one refusal per feature
Names:              Domain vocabulary, identical in Nix, shell, docs and specs
Types:              submodule over attrsOf str; enum over str; nullOr only if absence means something
Purity:             No getEnv, no currentTime, no unpinned fetch, no --impure
Effects:            Build, activation, shell hook, setup scripts — nowhere else
Idempotency:        f(f(x)) = f(x), with a written double-application scenario
Outcomes:           No bare `or`, no `|| true`, no `2>/dev/null`, no silent catch-all
                    Assertions carry a message naming the fix
Comments:           Why, never what — especially why a path is not granted
```
