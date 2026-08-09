# Implementation Plan: [FEATURE NAME]

**Spec**: [spec.md](spec.md) | **Branch**: `[NNN-short-name]` | **Date**: [YYYY-MM-DD]

<!-- Copy this file to specs/NNN-short-name/plan.md and delete the guidance
comments. This file states the HOW. The spec must stay readable without it.

The Constitution Check below is a GATE: it is filled before any task starts,
and re-checked before the feature closes. A violation is allowed only with a
Complexity Tracking row. An unrecorded violation is a defect. -->

## Summary

<!-- The requirement from the spec, plus the approach in two or three
sentences. Someone who reads only this paragraph should be able to predict the
shape of the diff. -->

## Technical context

| | |
| --- | --- |
| **Languages touched** | [Nix / bash / generated JSON] |
| **Consumed as** | [flake input / devenv module / devcontainer / local checkout] |
| **Platforms that must work** | [e.g. x86_64-linux, aarch64-darwin] |
| **New inputs or tools** | [name and pinned version, or none] |
| **Effects introduced** | [build / activation / shell hook / setup script, or none] |
| **State written outside the checkout** | [paths, or none — and if none, say so, because it is the interesting answer] |

## Constitution Check

<!-- GATE. One row per principle. Mark PASS, N/A with a reason, or VIOLATION
with a Complexity Tracking row. Do not mark PASS on a principle you have not
actually thought about for this feature. -->

| Principle | Verdict | How |
| --- | --- | --- |
| **P1** Isolation is the product | | Which variables or paths this adds, and how each is proven to stay inside the checkout. Any new accepted leak, named and justified |
| **P2** Test first, prove the check bites | | Which check goes red first, and the planted violations recorded below |
| **P3** Scenarios are the success criteria | | Every scenario in the spec maps to exactly one check, listed below |
| **P4** One step at a time | | `tasks.md` is one scenario per task, and no task exceeds ~50 lines |
| **P5** Clean code invariants | | Naming, one-thing functions, and which comments record a *why* |
| **P6** Refactor as a separate phase | | Which tasks are refactors, and the eval diff that proves each preserved behaviour |
| **P7** Ubiquitous language, modelled options | | The spec's Vocabulary is used verbatim; option types are constrained rather than `str` |
| **P8** Purity, effects at the boundary, idempotency | | No impurity introduced; effects confined to named phases; the repetition scenario is covered |
| **P9** Explicit outcomes, no silent fallbacks | | No bare `or`, no `\|\| true`, no silent catch-all; assertions carry actionable messages |

## Decisions

<!-- Settled choices, one bullet each: the choice, a one-line rationale, and
the alternative considered with why it lost. Unsettled things belong under the
spec's Risks & Open Questions, not here. -->

- **…**, because …, over *alternative*, which lost because …

## Repository layout

<!-- (optional, only if files or directories are added, moved or removed.)
Show the tree as it will be, marking each entry new / moved / deleted. -->

```text
```

## Dependencies & impact

- **Files touched**: … <!-- ideally few; diffs stay minimal -->
- **Consumers affected**: … <!-- does a downstream flake have to change anything? -->
- **Inputs added or bumped**: … <!-- every one pinned, with the lock committed -->
- **Tools added to the environment**: … <!-- and why the work cannot be done without them -->
- **Docs to update at close-out**: `docs/HANDBOOK.md`, plus the affected `README.md` <!-- and which Known drift entries this retires -->

## Test strategy

<!-- Required. Per layer: what is covered and how. A layer that does not apply
says so and why, rather than being omitted.

The end-to-end row is the one that matters in this repository and the one that
is easiest to fake: a check run inside the developing checkout, with a warm
cache and a parent .envrc already loaded, has not tested a consumer's
experience. -->

| Layer | Where | Needs | Covers |
| --- | --- | --- | --- |
| **Unit** | `nix eval` / shell function harness | nothing | … |
| **Component** | one module or script against a stub | an evaluator | … |
| **Integration** | the environment built and entered | a build | … |
| **End to end** | consumed from a ref, into a clean home | a build, a clean machine | … |

### Scenario coverage

<!-- Every scenario in the spec, mapped to the one check that executes it. A
scenario with no check is not specified, it is hoped for. -->

| Scenario | Check |
| --- | --- |
| Journey 1.1 | … |
| Refusal 1 | … |
| Repetition 1 | … |

### Properties

<!-- Where a property is expressible, assert the property rather than a value,
and derive the expectation from the system under test.

  good: every path exported by the shell hook resolves under $PWD
  good: the mirrored variable lists are equal to each other
  bad:  TMPDIR == "/home/you/proj/.tmp"

Pin a literal only where the literal is itself the criterion, such as an error
message a user will read. -->

- …

### Planted violations

<!-- MANDATORY for every new check, per Constitution P2. A check that has
never failed proves nothing, and a shell check that greps a moved file exits 0
and reports OK, which makes a green run a lie.

For each new check: plant the violation it exists to catch, watch it FAIL,
revert, and record it here. Tick Verified only once you have seen the red. -->

| Check | Violation planted | Must FAIL with | Verified |
| --- | --- | --- | --- |
| … | … | … | [ ] |

### Coverage gap

<!-- What the automated run does not reach, and therefore what a human runs by
hand. This goes into docs/HANDBOOK.md at close-out, so a gap is known rather
than discovered. Writing "none" is a strong claim: justify it. -->

- …

## Complexity tracking

<!-- Fill ONLY where the Constitution Check records a VIOLATION. One row each.
An empty table means the gate passed cleanly; delete the table only if you
would otherwise be leaving it empty and have said so above. -->

| Principle | Violation | Why it is needed | Simpler alternative, and why it was rejected |
| --- | --- | --- | --- |
| … | … | … | … |
