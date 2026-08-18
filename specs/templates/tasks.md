# Tasks: [FEATURE NAME]

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

<!-- Copy this file to the feature directory as tasks.md and delete the
guidance comments. The IDs, the status states and the gates are defined by the
Artifact contract in AGENTS.md; this file only instantiates them.

One task is one commit and one independently verifiable step. Tasks are in
dependency order, and each carries the RED → GREEN → CLEAN cycle of
Constitution P2 inside it. -->

## Rules for this file

- **One scenario per task.**
  A task covering two scenarios is two tasks.
- **RED before GREEN.**
  The first sub-step of every task is a check that fails, and the task records what the failure said.
- **A new check is not done until its violation has been planted**, watched to FAIL, and recorded in [plan.md](plan.md#planted-violations).
- **A refactor is its own task**, per Constitution **P6**, carrying the before-and-after eval diff that proves it changed nothing.
- **Roughly 50 lines of Nix or shell is the ceiling.**
  Past it, split the task.
- **Status moves `PENDING` → `IMPLEMENTING` → `IMPLEMENTED` → `DONE`.**
  Set `IMPLEMENTING` when work starts, so an abandoned session leaves a record rather than silence.
  Only a human moves a task to `DONE`.
- **Implementation Details** is added to a task after it is implemented, never during planning.
- The last task group is always documentation.

______________________________________________________________________

## M1 — [what must exist before any scenario can be checked]

<!-- Only what genuinely blocks every scenario. If nothing does, delete this
group rather than inventing setup work. -->

### M1a — [title] (Status: PENDING)

**Scenario**: [which scenario in spec.md, by number]

**RED**: [the check to write, and the failure it must produce first]

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md
- [ ] Formatted and linted per [AGENTS.md](../../AGENTS.md#4-verify-every-change)

______________________________________________________________________

## M2 — Journey 1 (P1)

<!-- The MVP slice. After this group, journey 1 works on its own and could be
handed to a consumer even if nothing else lands. -->

### M2a — [title] (Status: PENDING)

**Scenario**: Journey 1.1

**RED**: …

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md

### M2b — [title] (Status: PENDING)

**Scenario**: Refusal 1

<!-- Denial scenarios belong in the earliest group that can carry them,
because they are what the feature exists to guarantee. -->

**RED**: …

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes, and the denial is observable rather than merely logged
- [ ] Violation planted, seen to FAIL, reverted, recorded in plan.md

**Checkpoint**: Journey 1 is independently verifiable by `<command>`.

______________________________________________________________________

## M3 — Journey 2 (P2)

### M3a — [title] (Status: PENDING)

**Scenario**: Journey 2.1

**RED**: …

- [ ] Check written and seen to FAIL with: `…`
- [ ] `<command>` passes

**Checkpoint**: Journeys 1 and 2 are both independently verifiable.

______________________________________________________________________

## Mn — Documentation

<!-- Always last, and always present. This is where truth moves out of the
spec and into the docs, per AGENTS.md step 5. -->

### Mna — Close out (Status: PENDING)

- [ ] `docs/HANDBOOK.md` updated: how to use what landed, and the coverage gap from plan.md
- [ ] Known drift entries this feature retired are deleted from `docs/HANDBOOK.md`
- [ ] The affected `README.md` updated, with its component table taken from the code and its diagrams checked by eye in both themes
- [ ] Every open question in `spec.md` resolved in place with a one-line outcome
- [ ] `docs/CONSTITUTION.md` amended, or confirmed to need no amendment
- [ ] Touched files formatted and linted per [AGENTS.md](../../AGENTS.md#4-verify-every-change)
- [ ] `scripts/validate.sh` passes
