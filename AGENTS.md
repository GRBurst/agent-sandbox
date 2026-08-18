# Agent Rules

This repository is a **consumable development environment**.
Pointed at from a flake, a devenv configuration or a devcontainer, whether from GitHub or a local checkout, it sets a project up with agents already configured.
**Project isolation is the product**: nothing — credentials, caches, history, agent state — leaks between the projects that use it.

There is no cloud, no Kubernetes, no CD pipeline and no deployed service.
The goal of every change is a reproducible, verifiable environment that a stranger can enter with one command.

This file describes **how we work**.
[docs/CONSTITUTION.md](docs/CONSTITUTION.md) describes **what the code must be like**, and every plan is gated on it.

## 1. Source of truth

1. **The code** — `flake.nix`, `devenv.nix`, `.envrc`, the modules and the scripts.
   Behaviour is whatever they say.
1. **[docs/HANDBOOK.md](docs/HANDBOOK.md)** — how to use the repository today, including what it does not yet do.
1. **[docs/CONSTITUTION.md](docs/CONSTITUTION.md)** — the principles every change is measured against.
1. **This file** — how we work.
1. **`specs/`** — in-flight and historical work.
   **Unchecked boxes are not backlog.**

When a document and the code disagree, fix the document or fix the code.
Do not assume the document is right.

A landed spec may be edited to correct drift, such as a stale layout or a decision the code now contradicts.
Apply the correction where the wrong statement is, rather than appending a note that contradicts the text above it.
Once every task has landed, a spec may be consolidated down to what is still true: keep the decisions and the criteria, drop the record of how each one was checked.

## 2. The workflow

Planned work is spec-driven, in five steps.

1. **Prompt.** Every feature starts as a prompt.
1. **Spec.** Pathfind, then draft `specs/NNN-short-name/spec.md` from [specs/templates/spec.md](specs/templates/spec.md).
   It states the *what* and *why* as Given/When/Then scenarios, and names nothing about implementation.
   Then draft `plan.md` from [specs/templates/plan.md](specs/templates/plan.md) for the *how*, and `tasks.md` from [specs/templates/tasks.md](specs/templates/tasks.md) for the increments.
1. **Review.** A human edits and approves before any implementation.
   Every `[NEEDS CLARIFICATION: …]` marker and every box on the spec's review checklist must be resolved first.
   The plan's Constitution Check must pass, or carry a Complexity Tracking row justifying each violation.
1. **Implement.** One task per commit, in the order `tasks.md` gives.
   Tick a checkbox only when its command has actually passed.
1. **Close out.** Resolve the open questions, then move truth out of the spec and into `docs/HANDBOOK.md` and the affected README.
   The spec stays as history.

### Layout and numbering

```text
specs/
├── templates/            # spec.md, plan.md, tasks.md — copied, never edited in place
├── 001-short-name/
│   ├── spec.md           # what and why, in scenarios. No implementation detail
│   ├── plan.md           # how, plus the Constitution Check gate and the test strategy
│   └── tasks.md          # the increments, in dependency order, one per commit
└── 002-short-name/
```

- `NNN` is the next unused three-digit number, and the branch is named after the directory.
- One feature per directory.
  Extend a directory only while its feature is still in flight; a follow-up is a new number.
- `research.md` or `data-model.md` may be added beside them when pathfinding produced something worth keeping.
  Do not create them empty.

### Artifact contract

This table is the **only** declaration of the layout.
Tooling and agent skills read it rather than hardcoding paths, so changing the layout means changing this table and nothing else.

| Key | Value |
| --- | --- |
| `templates` | `specs/templates/spec.md`, `specs/templates/plan.md`, `specs/templates/tasks.md` |
| `feature-dir` | `specs/NNN-short-name/`, `NNN` the next unused three-digit number |
| `branch` | the feature directory's own name, `NNN-short-name` |
| `artifacts` | `spec.md` the what and why · `plan.md` the how and the gate · `tasks.md` the increments |
| `principles` | `docs/CONSTITUTION.md`, cited as `P1`…`P9` |
| `usage-doc` | `docs/HANDBOOK.md` |
| `read-first` | `AGENTS.md`, `docs/CONSTITUTION.md`, `docs/HANDBOOK.md`, every existing `specs/*/spec.md` |
| `verification` | `scripts/validate.sh` |
| `task-group-id` | `M<n>` on an H2, as `## M1 — title` |
| `task-id` | `M<n><suffix>` on an H3, as `### M1a — title`. The suffix starts with a letter, so `M<digits>` stays unambiguous |
| `task-status` | `(Status: <STATE>)` closing every H3, `STATE` one of `PENDING`, `IMPLEMENTING`, `IMPLEMENTED`, `DONE` |
| `qualified-ref` | `NNN.M<id>`, as `001.M4c`, wherever the feature could be ambiguous. Numbering is local to each `tasks.md` |
| `gate spec → plan` | no `[NEEDS CLARIFICATION]` remains, and the spec's review checklist is resolved |
| `gate plan → tasks` | the Constitution Check passes, or every violation carries a Complexity Tracking row |
| `gate task → DONE` | its command has actually passed, and any new check has its planted violation recorded in `plan.md` |

`IMPLEMENTING` exists so that an abandoned session leaves a record of where things stood rather than silence.
A task is marked `DONE` only on explicit human confirmation; the agent may take it as far as `IMPLEMENTED`.

## 3. Environment and tooling

- The repository uses a nix flake with direnv, so commands usually run in the right environment already.
  If a tool is missing, `nix develop -c <cmd>` is the reliable escape hatch, then `direnv exec . <cmd>`, then `direnv reload`.
  The interactive shell is `zsh`; scripts are `bash`.
- The variables that keep every tool inside the project are the subject of Constitution **P1**, and they live in one place with a checked mirror.
  Never add a variable to only one of the two.
- Development happens in a sandbox that denies `$HOME`, so a tool that ignores the rule fails outright rather than quietly writing to a home directory.
  That failure is the feature.
- The repository must work for someone who has none of your dotfiles.
  A tool that resolves only because it is in your user profile is not available, and belongs either in the environment or in the known-drift list.

## 4. Verify every change

A change is not done until it proves itself.

- **State how each layer is covered, and cover the ones that apply.**
  A layer that does not apply says so, and why, rather than being left out.

  | Layer | What it exercises | Needs |
  | --- | --- | --- |
  | **Unit** | Pure evaluation — a function or an option value via `nix eval`, a shell function in a harness | Nothing. No build, no network, no `$HOME` |
  | **Component** | One module or one script against a stub configuration | An evaluator, no environment |
  | **Integration** | The environment built and entered: variables resolve, tools are present, isolation holds | A build |
  | **End to end** | The repository consumed the way a user consumes it — from a ref rather than a local path, into a clean home | A build and a clean machine state |

- **The end-to-end layer is the one that matters here and the one that is easiest to skip.**
  Everything can pass locally in a checkout whose `.cache/` is already warm and whose parent `.envrc` already exported half of what is needed.
  A claim about isolation that has only been checked from inside the developing checkout has not been checked.

- **Assertions target functionality, not particular values, and are property-based wherever the property is expressible.**
  `every exported path resolves under $PWD` holds for every variable and survives a new one being added; `TMPDIR == "/home/you/proj/.tmp"` holds for one machine and breaks on the next.
  Derive expected values from the system under test — compare the mirrored variable lists against each other rather than against a list written down in the check.
  Pin a literal only where the literal *is* the criterion, such as an error message a user will read.

- **A new check must be proven to bite**, per Constitution **P2**.
  Plant the violation, watch it FAIL, revert, and record the planted violation in the plan.

- **Verification lives in one place.**
  `scripts/validate.sh` is the entry point, with `docs/HANDBOOK.md` describing what a human runs by hand.
  Do not add a third copy of the same assertions.

- **State the coverage gap.**
  Whatever the automated run does not reach is listed in the handbook as verified by hand, so a gap is a known one rather than a surprise.

- **Format and lint what you touched.**

  | Files | Format | Lint |
  | --- | --- | --- |
  | `*.nix` | `nixfmt` | `nix flake check` |
  | `*.md` | `mdformat` | — |
  | `*.yaml` | `yamlfmt` | `yamllint` |
  | `*.sh` | `shfmt` | `shellcheck` |
  | `*.json` | `jq` | its schema, where one exists |

  Leave any file with YAML frontmatter out of the `mdformat` run, because mdformat destroys it.

## 5. Scope discipline

- Keep diffs minimal, and do not change unrelated code.
- Prefer deleting complexity over managing it.
  An environment does not need an abstraction layer for its second consumer until it has one.
- Comments record why, not what, per Constitution **P5**.
- Do not commit or push unless asked, and never rewrite published history.
- `refs/` holds read-only reference material from other projects.
  Never edit it, and do not mistake its conventions for this repository's.

## 6. Docs and diagrams

Every directory that a user can consume on its own has exactly one `README.md`, at its root, describing what actually runs.
That means a component table with every row taken from the code, a structure diagram, and a time-ordered diagram.

- **Mermaid only.**
  `flowchart LR` for structure, `sequenceDiagram` for anything time-ordered.
- **A diagram shows structure or time, and a list of commands is neither.**
  Write those as a `sh` block with a comment per line, which is the form a reader copies.
  A flowchart of enter, then verify, then exit only makes them retype it.
- **No `%%{init}%%` theme directives and no `fill:` or `stroke:` colour values.**
  They override the reader's light or dark theme, so a diagram that looks right for its author is unreadable for everyone else.
  `classDef` may set `stroke-width` and `stroke-dasharray` only.
- **A dashed stroke marks anything outside the project boundary**, which is the one distinction these diagrams exist to make and the only one the colour ban leaves a channel for.
- **No `subgraph`.**
  Flat diagrams only, using `<br/>` inside quoted labels instead.
- Programs and tools are boxes, written as `agent["opencode"]`.
  Paths and state stores are pills, written as `cache(["$PWD/.cache"])`.
- **Rank discipline in `flowchart LR`.**
  Declare nodes in left-to-right rank order and keep every edge pointing rightward, so the reader's eye and the data travel the same way.
  Nodes on the same rank must have **no edge between them**, because mermaid ranks by longest path and one peer edge staggers the whole row into a diagonal.
  Express a peer relationship as one shared node every peer points at, never as a cycle.
- **A time-ordered section is one diagram per phase**, each under its own `###` heading, as `### Bootstrap` then `### Case 1: …`.
  Each diagram declares only the participants it uses and restarts `autonumber`, so a case is numbered from 1 rather than continuing from step 14 of the bootstrap.
  One diagram covering setup and use together reads as a single wall, and the reader cannot tell which steps they still have to do.
- **A refused case is a case of its own.**
  Where the repository denies something on purpose, that denial is the demonstration, so give it its own diagram rather than a footnote.
- Nothing in the environment renders mermaid, so check diagrams by eye, in both themes.
