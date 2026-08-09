# Tasks: [FEATURE NAME]

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

<!-- Copy this file to specs/NNN-short-name/tasks.md and delete the guidance
comments.

One task is one commit and one independently verifiable step. Tasks are in
dependency order, and each carries the RED → GREEN → CLEAN cycle of
Constitution P2 inside it.

Tick a checkbox only when its command has actually passed. Do not paste output
you have not seen. An unticked box is not backlog: it is work this feature
still owes. -->

## Rules for this file

- **One scenario per task.**
  A task that covers two scenarios is two tasks.
- **RED before GREEN.**
  The first sub-step of every task is a check that fails, and the task records what the failure said.
- **A new check is not done until its violation has been planted**, watched to FAIL, and recorded in [plan.md](plan.md#planted-violations).
- **A refactor is its own task**, per Constitution **P6**, and carries the before-and-after eval diff that proves it changed nothing.
- **Roughly 50 lines of Nix or shell is the ceiling.**
  Past it, split the task.
- The last task is always documentation.

## Phase 1 — [foundation / whatever must exist first]

<!-- Only what genuinely blocks every scenario. If nothing does, delete this
phase rather than inventing setup work. -->

### T001 — [title]

**Scenario**: [which scenario from spec.md, by number]

**RED**: [the check to write, and the failure it must produce first]

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md
- [ ] `nixfmt` / `shfmt` clean on what was touched

______________________________________________________________________

## Phase 2 — Journey 1 (P1)

<!-- The MVP slice. After this phase, journey 1 works on its own and could be
handed to a consumer even if nothing else lands. -->

### T002 — [title]

**Scenario**: Journey 1.1

**RED**: …

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md

### T003 — [title]

**Scenario**: Refusal 1

<!-- The denial scenarios usually belong in the earliest phase that can carry
them, because they are what the feature exists to guarantee. -->

**RED**: …

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes, and the denial is observable rather than merely logged
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md

**Checkpoint**: Journey 1 is independently verifiable by `<command>`.

______________________________________________________________________

## Phase 3 — Journey 2 (P2)

### T004 — [title]

**Scenario**: Journey 2.1

**RED**: …

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes

**Checkpoint**: Journeys 1 and 2 are both independently verifiable.

______________________________________________________________________

## Phase N — Documentation

<!-- Always last, and always present. This is where truth moves out of the
spec and into the docs, per AGENTS.md step 5. -->

### T00n — Close out

- [ ] `docs/HANDBOOK.md` updated: how to use what landed, and the coverage gap from plan.md
- [ ] Known drift entries this feature retired are deleted from `docs/HANDBOOK.md`
- [ ] The affected `README.md` updated, with its component table taken from the code and its diagrams checked by eye in both themes
- [ ] Every open question in `spec.md` resolved in place with a one-line outcome
- [ ] `docs/CONSTITUTION.md` amended, or confirmed to need no amendment
- [ ] Touched files formatted and linted per [AGENTS.md](../../AGENTS.md#4-verify-every-change)
- [ ] `scripts/validate.sh` passes
