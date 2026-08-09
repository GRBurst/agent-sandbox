# Feature Specification: [FEATURE NAME]

**Directory**: `specs/[NNN-short-name]/` | **Branch**: `[NNN-short-name]` | **Created**: [YYYY-MM-DD] | **Status**: Draft

**Prompt**: [the request this came from, verbatim]

<!-- Copy this file to specs/NNN-short-name/spec.md and delete the guidance
comments. This file states the WHAT and the WHY. It names nothing about
implementation: no file paths, no option names, no tool choices. Those go in
plan.md, and a reviewer must be able to disagree with the how without
reopening the what.

Sections marked (optional) may be deleted when they do not apply. Every other
section is mandatory; a section that does not apply says so and why, rather
than being removed.

Never guess. Anything unknown is marked inline as
[NEEDS CLARIFICATION: the specific question] and listed under Risks & Open
Questions. Every marker must be resolved in review, before implementation. -->

## Overview

<!-- The problem, why now, and what a consumer of this environment can do
afterwards that they cannot do today. A few sentences. -->

## Goals / Non-Goals

<!-- Goals are what success looks like, measurable where possible. Non-Goals
are things a reader could reasonably assume are in scope and deliberately are
not. They differ from Out of Scope, which lists whole areas left untouched. -->

**Goals**

- …

**Non-Goals**

- …

## Vocabulary

<!-- Constitution P7. One row per concept this feature introduces or renames,
with the single word that will be used for it in Nix, in shell, in the docs,
in these specs and out loud. Note any term this replaces, so the old word can
be hunted down. Delete no row just because the term feels obvious: the terms
that feel obvious are the ones that drift. -->

| Term | Means | Replaces |
| --- | --- | --- |
| … | … | — |

## Scenarios

<!-- Constitution P3. Group scenarios into user journeys, priority-ordered.
Each journey must be independently valuable, so that implementing only P1
leaves something a consumer can use.

Every scenario has exactly one When. Two triggers are two scenarios. `And`
extends a Given or a Then.

Every Then is OBSERVABLE: an exit status, a path that exists or does not, a
value in generated output, a write that was denied, an empty diff. "Works
correctly" and "is isolated" are not outcomes. -->

### Journey 1 — [brief title] (P1)

<!-- What this journey delivers, in plain language, and why it is P1. -->

**Independently verifiable by**: [the one command or observation that shows this journey works on its own]

1. **Given** …
   **When** …
   **Then** …
   **And** …

1. **Given** …
   **When** …
   **Then** …

### Journey 2 — [brief title] (P2)

**Independently verifiable by**: …

1. **Given** …
   **When** …
   **Then** …

### Refusal scenarios

<!-- MANDATORY, per Constitution P3. This repository's product is isolation,
so the interesting behaviour is what must NOT happen. At least one scenario
here, and it is usually the most important one in the file.

Write the denial as the outcome, not as an error to be handled: the write that
must be refused, the path that must not resolve, the state that must not
survive, the credential that must not be visible from the next project. -->

1. **Given** …
   **When** …
   **Then** the attempt fails
   **And** [what a human sees, and what was NOT written]

### Repetition scenarios

<!-- MANDATORY where this feature changes any state, per Constitution P8.
Setting an environment up is this repository's job, and it happens repeatedly,
over stale checkouts and half-finished previous runs. f(f(x)) = f(x). -->

1. **Given** [the feature has already been applied once]
   **When** it is applied a second time
   **Then** the result is byte-identical to the first
   **And** nothing is duplicated

### Edge cases

<!-- Boundaries and hostile inputs that are not yet scenarios. Anything left
here at review time either becomes a scenario or moves to Out of Scope. -->

- What happens when …?

## Requirements

<!-- Numbered, testable statements. No implementation detail. Every
requirement is covered by at least one scenario above, and the review
checklist asserts it. -->

- **FR-1** The environment MUST …
- **FR-2** A consumer MUST be able to …

**Non-functional.**
The change honours [docs/CONSTITUTION.md](../../docs/CONSTITUTION.md), and the plan's Constitution Check records how.
In particular: nothing resolves outside the project (**P1**), evaluation stays pure and pinned (**P8**), every state change is idempotent (**P8**), and no outcome is collapsed into a silent default (**P9**).

## Success criteria

<!-- Measurable, and expressed as what an outsider can observe. Prefer a
property that stays true as the repository grows over a value that is true
today. -->

- **SC-1** …
- **SC-2** …

## Assumptions & Constraints

<!-- Assumptions are unvalidated beliefs the feature rests on, so each one is
a latent risk: validate what research can settle and carry the rest under
Risks. Constraints are fixed limitations, such as the platforms that must
work, or offline behaviour. -->

- …

## Out of Scope

<!-- Whole areas deliberately untouched, so nobody mistakes silence for
backlog. -->

- …

## Risks & Open Questions

<!-- Numbered. Risks come from a pre-mortem: "this landed and a consumer's
project still leaked — what happened?" Include every assumption research could
not settle and every [NEEDS CLARIFICATION] marker from above.

Each gets a mitigation, a fallback, or a question for the reviewer, and is
resolved in place during implementation with a one-line outcome. -->

1. **…**: …

## Review checklist

<!-- Ticked honestly by the drafting agent before handing over. An unticked
box is information for the reviewer, not a failure. Every box and every
[NEEDS CLARIFICATION] marker must be resolved before implementation starts. -->

- [ ] Every scenario has exactly one `When`, and a `Then` that is observable
- [ ] At least one refusal scenario is present, and it is a real denial rather than an error message
- [ ] A repetition scenario is present, or the feature provably changes no state
- [ ] Every requirement FR-1..n is covered by at least one scenario
- [ ] No implementation detail appears anywhere in this file
- [ ] Vocabulary names every new term, and no synonym for an existing one was introduced
- [ ] Goals and Non-Goals are stated, and Out of Scope names the areas left alone
- [ ] Every `[NEEDS CLARIFICATION]` marker is listed under Risks & Open Questions
