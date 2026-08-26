# Feature Specification: Confined agent sessions per project

**Directory**: `specs/001-agent-sandbox/` | **Branch**: `001-agent-sandbox` | **Created**: 2026-08-18 | **Status**: Draft

**Prompt**: Based on the provided drafts @draft1.md @draft2.md , create a spec for a reusable sandbox utilizing nono with batteries included for project based isolations. for clarification: it seems that we can get the same isolation with nono on the host system instead so we don't need devenv with containers. If anything is unclear, ask first. Research and double check feasability as well.

## Overview

Today this repository keeps *its own tools* inside the project. It does nothing to keep an *agent* inside the project. An agent entered from here reads the whole home directory, inherits every host secret in its environment, and writes session state that the next project will see.

This feature makes agent confinement the product. A project points at this repository and gets three coding agents — `claude-code`, `opencode`, `pi` — confined by the operating system: they read and write inside the checkout and nowhere else, they inherit no host secret, their state stays in the checkout, and no credential material reachable from inside the boundary authenticates from outside it.

It also removes the container. The repository currently reaches confinement — badly — by generating a devcontainer that bind-mounts four host agent directories read-write, sharing credentials and session state with every other consumer of that home. Host-level confinement removes both the container and the leak.

Every claim is checked by one command, run unattended on clean machines, on every supported platform. Confinement that cannot be enforced fails loudly instead of running open.

## Goals / Non-Goals

**Goals**

- A stranger with no dotfiles reaches a confined agent session in one command.
- A confined agent's filesystem reach is the project directory plus a short, published, justified registry of exceptions.
- A confined agent inherits no host secret through its environment.
- Agent state written during a session stays in the project directory, or is a registered exception.
- No credential material readable inside the boundary authenticates from outside it.
- Authenticating happens once per machine, not once per project.
- A host that cannot enforce confinement refuses to start an agent.
- The ordinary toolchain — notably pushing over HTTPS — keeps working inside the boundary.
- Extensions a consumer authored on their machine come with them into every project of theirs, without any project asking for them and without a stranger inheriting them.
- Every claim above is proved by one command on clean machines, per platform, on every change.

**Non-Goals**

- **Not an anonymity boundary.** A confined agent still sees the username, the home path, the machine's hardware and the package store. Confinement limits reach, not knowledge.
- **Not a general network policy engine.** Beyond what credential substitution requires, choosing which hosts an agent may contact is a separate concern.
- **Not protection against a malicious agent binary.** The confinement mechanism is trusted; the agent under it is not.
- **Not editor integration.** Giving a confined agent a channel back to the host editor is machine-specific, and both drafts carry it only as a convenience.
- **Not a second confinement backend.** One mechanism, one test matrix.
- **Not resource limiting.** Memory and process caps are out.

## Vocabulary

| Term | Means | Replaces |
| --- | --- | --- |
| **Project isolation** | The existing property that the environment's own tools write only inside the checkout. Constitution P1. | — |
| **Agent confinement** | The operating-system-enforced boundary stopping an *agent* reading or writing outside the project directory. A different property from project isolation, and the subject of this feature. | the drafts' unqualified "sandbox" |
| **Confined session** | One run of one agent inside that boundary. | the drafts' "sandbox wrapper" invocation |
| **Project directory** | The checkout a confined session is bound to. | the drafts' "project", "projectName" |
| **Agent state** | What an agent writes to survive a run: configuration root, sessions, conversation history, per-agent caches, logs. | the drafts' "state dir" and "cache dir", treated as two unrelated things |
| **Confinement description** | The reviewable statement of what one agent may reach. | the drafts' "profile", "profileBuilder" |
| **Execution substrate** | The programs a session runs and everything they need to run: the agent, the shell it spawns, every tool it shells out to, and their libraries and data. Derived from the session's own definition rather than written down, and immutable. | — |
| **Leak registry** | The single file enumerating every path outside the project directory and outside the execution substrate a confined session may reach, each with a written justification. | the drafts' `sharedCredentials`, `extraAllowPaths` |
| **Registered exception** | One entry in the leak registry. Constitution P1's "accepted leak", given a home. | — |
| **Credential material** | Anything an agent can read that is presented to a provider as proof of identity — a file, or a variable in its environment. Deliberately covers both, because one shipped agent has no credential file. | the drafts' `sharedCredentials.claude` |
| **Substitute credential** | Credential material that authenticates only from inside the boundary and is useless copied out. | — |
| **Enforcement tier** | How strong the operating system's confinement guarantee is on a given platform. Distinct from whether that platform is verified. | — |
| **Pre-flight check** | The executable probe run before an agent starts, which establishes that confinement can actually be enforced on this host. | `devenv.nix`'s unverified platform claims |
| **Consumer** | A downstream project that points at this repository. | the handbook's "downstream flake" |
| **Host-global agent configuration** | Configuration a consumer has already installed in their home directory to serve every project on the machine, independent of this repository. | — |
| **Authoring surface** | The part of a host-global agent configuration a consumer wrote themselves to shape how an agent works: skills, subagents, commands, prompts. Declarative — it tells an agent what to do, rather than being code the agent runs. The one part of a host-global configuration a session may reach. | the drafts' `extraAllowPaths`, for this one use |
| **Executable extension** | An extension an agent loads into its own process, running with everything the session can reach. Distinguished from the authoring surface because granting one grants far more than instructions. | the drafts' unqualified "plugin" |

## Scenarios

### Journey 1 — A stranger gets a confined agent (P1)

The entry point. Without this nothing else is reachable, and it is the journey that proves the repository is consumable rather than merely present.

**Independently verifiable by**: entering from the canonical reference on a clean machine and asserting the started session's granted reach against the execution substrate and the leak registry.

1. **Given** a machine with none of the author's dotfiles and no prior agent state
   **When** the stranger enters the environment from this repository's canonical published reference and starts an agent
   **Then** the agent starts
   **And** the session's granted filesystem reach consists only of the project directory, the session's own execution substrate, and paths in the leak registry.

### Journey 2 — Agent state stays in the project (P1)

**Independently verifiable by**: snapshot the home directory, run a session, diff, subtract the leak registry; the remainder must be empty.

1. **Given** a confined session that has written conversation history
   **When** the session ends and the home directory is compared against a snapshot taken before it started
   **Then** the agent state appears inside the project directory
   **And** the only home-directory paths that changed are registry entries.

### Journey 3 — Two projects at once share nothing (P1)

**Independently verifiable by**: running both sessions, writing in one, asserting an empty diff in the other.

1. **Given** two checkouts of two different projects, each running a confined session of the same agent
   **When** one session writes conversation history
   **Then** the other project directory is unchanged
   **And** neither session's granted reach includes the other's project directory.

### Journey 4 — A stolen credential is worthless (P1)

The strongest observable in this file, and the reason confinement is worth having at all: a boundary that keeps files in but lets a working key out has not protected anything.

**Independently verifiable by**: asserting the readable credential values match the substitute form, and that a value copied out fails to authenticate. The substitute-form half runs unattended against mock credentials; the live provider-rejection half is hand-verified under FR-14.

1. **Given** the user has authenticated once on the machine
   **When** a confined session reads the credential material it is granted
   **Then** every credential value it can read is a substitute
   **And** a request made with a value copied out of the boundary is rejected by the provider.

### Journey 5 — Authenticate once, use everywhere (P2)

"Everywhere" is two axes, and both matter. Across projects, because authenticating per checkout would make the environment worse than the host setup it replaces. Across agents, because the three ship together and are used interchangeably, so a credential obtained by one serves all three.

**Independently verifiable by**: starting a session in a second checkout and asserting each agent reports an authenticated state.

1. **Given** the user has authenticated for one project, with one agent
   **When** they start a confined session in a second, unrelated project
   **Then** that agent is authenticated with no further login
   **And** the other agents are authenticated too, without a login of their own.

### Journey 6 — The toolchain still works (P2)

This journey exists because credential substitution inspects encrypted traffic, and the documented failure mode is that the agent keeps working while ordinary tools reject the interception certificate — which users misread as a filesystem denial.

**Independently verifiable by**: the exit status of an ordinary tool's HTTPS exchange with that remote.

1. **Given** a confined session in a checkout with a remote
   **When** the session exchanges with that remote over HTTPS
   **Then** the exchange succeeds.

1. **Given** a confined session in a checkout this environment configured
   **When** the session commits
   **Then** the commit succeeds
   **And** it carries no signature
   **And** nothing outside the session's reach was read in order to produce it.

The exchange is one that needs no credential. Nothing here supplies the version-control toolchain with a credential, and every host store it would otherwise read is denied outright, so a push would fail for want of a credential whatever the inspecting authority did — which is the opposite of what this journey is for. Trust in the inspecting authority is the property, and FR-17 is the requirement; authenticating the toolchain is a separate concern, addressed under Out of scope.

Signing is the second step's subject, and it is this journey's failure mode rather than a new one: a signature needs a key, every store a key lives in is denied, so a toolchain configured to sign fails partway through an otherwise ordinary commit and reads as the checkout being unwritable. Unsigned is therefore what the environment configures, and FR-24 says where a signature is wanted the key arrives as a forwarded agent socket or a secret-service request rather than as a granted directory. R11 is the refused half, for the checkout that demands a signature anyway.

### Journey 7 — The claims are checked on clean machines (P1)

**Independently verifiable by**: the exit status, plus planting a registry entry and observing the expected set change without the check being edited.

1. **Given** the repository at a commit
   **When** the verification command runs unattended on a clean machine for each supported platform
   **Then** it exits zero
   **And** its exit status alone separates a passing commit from a failing one
   **And** the expected reach it compares against is derived from the execution substrate and the leak registry rather than restated inside the check.

### Journey 8 — The consumer's own extensions come with them (P2)

Confinement that costs a consumer the skills and subagents they wrote is confinement they will stop using, and the environment they fall back to is the unconfined one. This journey is what keeps the boundary adoptable, and it is the one place a host path is read on purpose rather than by accident.

The distinction it rests on is what the host file *does*. An authoring surface is the consumer's own instruction to their own agent, in the same class as the parent `.envrc` the environment already accepts reading: a personal, machine-level concern. Credentials, conversation history, session state and any host confinement description are a different class, and R9 keeps them out.

**Independently verifiable by**: declaring an authoring surface, starting a session, and asking the agent to enumerate what it loaded; then asserting the same session with no declaration enumerates none of it.

1. **Given** a consumer who has authored agent extensions on their machine to serve every project, and has declared that surface once for the machine
   **When** they start a confined session in any project directory
   **Then** the agent reports those extensions as available to it
   **And** the surface is unchanged afterwards, so a session cannot rewrite what it was lent.

1. **Given** a machine with no such declaration, as a stranger who cloned the project has
   **When** a confined session starts
   **Then** the session's granted reach is the project directory and registry entries, unchanged
   **And** the agent starts and works with none of those extensions, rather than failing on their absence.

### Refusal scenarios

1. **R1 — Credentials outside the project are unreachable.**
   **Given** a confined session and an SSH private key in the user's home directory
   **When** the session attempts to read that key
   **Then** the read fails
   **And** the session's command exits non-zero, and no key material appears in its output.

1. **R2 — Writes outside the project are refused.**
   **Given** a confined session
   **When** it attempts to create a file in the user's home directory outside the leak registry
   **Then** the attempt fails
   **And** the file does not exist afterwards.

1. **R3 — Host secrets do not cross the boundary.**
   **Given** a host environment carrying a provider API key
   **When** a confined session prints its own environment
   **Then** that key's value does not appear in the output.

1. **R4 — An agent cannot widen its own confinement.**
   **Given** a running confined session whose project directory contains the source of its confinement description
   **When** the session edits that source to grant the whole home directory
   **Then** the running session's reach is unchanged
   **And** a newly started session's reach is unchanged until a human re-enters the environment.

1. **R5 — An untrusted repository cannot grant itself paths.**
   **Given** a checkout containing an agent configuration file that requests access to the home directory
   **When** a confined session starts in it
   **Then** the granted reach is unchanged by that file.

1. **R6 — A host that cannot enforce confinement refuses.**
   **Given** a machine lacking a required confinement primitive
   **When** the user starts an agent
   **Then** nothing is started
   **And** the failure names the missing primitive, and the exit status is `77`.

1. **R7 — The previous project's configuration is gone.**
   **Given** the repository at this feature's completion
   **When** the environment is entered
   **Then** no package, variable or ignore rule belonging to the prior Kafka project is present.

1. **R8 — A stale credential is not mistaken for a denied path.**
   **Given** a confined session whose stored substitute credential is no longer valid
   **When** the agent makes a provider request
   **Then** the resulting message identifies it as an authentication failure
   **And** it is distinguishable from a confinement denial.

1. **R9 — The rest of a host-global agent configuration does not reach the session.**
   Journey 8's counterpart, and the harder half: the surface a consumer authored is theirs to carry, and reaching for it must not drag in the installation it sits inside. The self-referential case is the sharpest — a host confinement description that took part in deciding a session's reach would let configuration outside the boundary define the boundary.
   **Given** a machine whose home directory already configures these agents for every project — stored credentials, conversation history, session state and confinement descriptions among them — and whose consumer has declared their authoring surface
   **When** a confined session starts in a project directory
   **Then** nothing outside the declared authoring surface is readable from inside the session
   **And** no host confinement description takes part in deciding that session's reach
   **And** the session starts and works regardless, rather than depending on any of it or failing on its absence.

1. **R10 — A host tool configuration does not direct the session.**
   The counterpart for the ordinary toolchain, and the case where Journey 8's licence does not transfer. An authoring surface is a consumer instructing their own agent, deliberately. The version-control toolchain's host configuration is read by a tool the session runs incidentally, and it can name a program for the tool to run, so nothing here asks for it and it stays out entirely.
   **Given** a machine whose home directory configures the version-control toolchain with a directive that runs a program
   **When** a confined session runs that toolchain
   **Then** the toolchain reads no configuration file from outside the project directory
   **And** its effective configuration is one this environment wrote, so the host directive does not run.

1. **R11 — A signature the session cannot produce is refused, loudly.**
   FR-24's refused half, and the one case the environment cannot configure away: a checkout's own configuration outranks the global file this environment writes, so the demand for a signature survives into the session while the key does not.
   **Given** a confined session in a checkout whose own configuration demands signed commits, and no key forwarded into the session
   **When** the session commits
   **Then** the commit fails
   **And** the message names the key material that could not be reached, so the failure is not mistaken for the checkout being unwritable
   **And** no unsigned commit is created in its place.

### Repetition scenarios

1. **Rep1 — Entering twice changes nothing.**
   **Given** the environment has been entered once
   **When** it is entered a second time
   **Then** the project directory's tracked files are unchanged
   **And** the granted reach is identical.

1. **Rep2 — Verifying twice changes nothing.**
   **Given** the verification command has run and passed
   **When** it runs again against an unchanged repository
   **Then** it passes again
   **And** it leaves no residue a third run would trip over.

1. **Rep3 — Authenticating twice is harmless.**
   **Given** the user is already authenticated
   **When** they authenticate again
   **Then** the result is an authenticated state with substitute credentials, indistinguishable from the first.

### Edge cases

- **The project directory is wiped.** Agent state lives in the checkout, so deleting untracked files destroys conversation history. Accepted; documented, not mitigated.
- **`pi` relocates, through one variable rather than two.** Two rounds of research disagreed, so the plan verified it against the agent itself before relying on it. It relocates: a single documented override redirects the configuration root, and everything `pi` persists — settings, credentials, sessions and installed extensions — lives beneath it. `pi` therefore needs no registry entry, and installs its extensions inside the project like any other state. The second round was itself half wrong: the separate session-storage override it reported is documented but absent from the agent, so setting it does nothing. Neither round could be taken on trust.
- **`claude-code` partially escapes its own override.** Its configuration-root variable is documented as having fallback cases in subagent and lock paths. Those fallbacks are either confined by other means or registered; they are not ignored.
- **The two platforms enforce differently.** One is allow-list only, the other permits deny-inside-allow, so an identical description yields different effective reach. Per-platform enforcement strength is recorded rather than smoothed over.
- **The registry grows.** Every addition is a reviewable diff with a justification, so length is itself a signal. The bound is not a number but a kind: an entry is admissible only where the tool structurally cannot be redirected, never because redirecting it is inconvenient.
- **A consumer needs an unpredicted path.** There is a documented way to widen one project's reach without editing this repository, and it is not a file inside the project.
- **An agent reads its extensions from several places.** An agent may scan its own configuration root and also shared roots that other agents read, so a consumer's skills can sit in any of them. Every location an agent reads is covered, or the uncovered one is named — otherwise a consumer whose extensions live in the uncovered root concludes the declaration did nothing.
- **The same extension exists in two of those places.** Which copy an agent prefers is the agent's behaviour, not this environment's, so the environment grants the locations and does not attempt to arbitrate between them. What it must not do is silently drop a location and change which copy wins.

## Requirements

- **FR-1** The environment MUST provide confined sessions for `claude-code`, `opencode` and `pi`. All three are required, and `claude-code` is the reference case — not because it is the easiest, but because the other two obtain their credential from it, so nothing about FR-6 or FR-7 can be demonstrated until it works. That ordering front-loads the risk rather than deferring it: `claude-code` is also the agent whose configuration root is least certain to relocate, and building the credential story on an agent whose state is still escaping would be building twice.
- **FR-2** A confined session's granted filesystem reach MUST be the project directory, the session's own execution substrate, and leak-registry entries, and nothing else. The substrate is a category of its own rather than a registry entry because it is not a leak: it is the programs the session runs, derived from the session's own definition, immutable, and reviewable as a single artefact. It MUST be derived rather than written down, so that adding a tool to the session adds it to the substrate and nothing else does, and it MUST NOT be granted by way of any ancestor that would also grant what the session does not run. That is the reach with no override in force, which is what a stranger gets and what the checks assert; FR-15 is the only thing that widens it, and FR-25 the only widening this feature ships.
- **FR-3** The leak registry MUST be a single file. Every entry states why the path is granted and why a narrower grant does not work. It carries no expiry mechanism. An entry is admissible only where the tool structurally cannot be directed elsewhere; convenience is never a justification. The execution substrate is not admissible as an entry: an entry owes a justification a human writes and reviews, and the substrate is derived from what the session runs, so entries for it would be neither reviewable nor stable. An empty registry is the healthy state, not a sign the file is unused.
- **FR-4** Agent state MUST be written inside the project directory. Where an agent cannot be directed to do so, its state path MUST be a registry entry under FR-3.
- **FR-5** A confined session MUST NOT inherit host environment variables carrying provider credentials.
- **FR-6** No credential material readable from inside a confined session MUST authenticate from outside the boundary. This constrains the outcome, not the mechanism: an agent that authenticates by token flow and an agent that authenticates by key in its environment may satisfy it differently.
- **FR-7** Authenticating once on a machine MUST serve every project on that machine, and every agent shipped. One agent performs the login; the other two obtain what they need from it without a login of their own. How is the plan's business, but FR-6 and FR-3 together already exclude the obvious shortcut: letting the other agents read the authenticating agent's credential store would put a credential that works outside the boundary inside it, and a grant for that store would rest on convenience rather than on the tool being structurally impossible to redirect.
- **FR-8** Concurrent confined sessions in different project directories MUST share no agent state and MUST NOT reach each other's project directory.
- **FR-9** Modifying the confinement description from inside a confined session MUST alter neither that session's boundary nor any later session's boundary until a human re-enters the environment.
- **FR-10** Before an agent starts, a pre-flight check MUST establish that confinement can be enforced on this host. If it cannot, nothing starts, the message names the missing primitive, and the exit status is `77`. The literal is pinned because a caller branches on it. No flag, variable or configuration makes the confined entry point proceed unconfined. Running an agent without confinement stays possible only by not invoking the confined entry point at all — a deliberate and visible act, which the usage document describes rather than conceals.
- **FR-11** The repository MUST name its supported platforms and, for each, the enforcement tier its operating system provides. A platform whose guarantee is weaker says so, in the usage document, with the difference named.
- **FR-12** One command MUST verify every scenario in this spec, and MUST be the only place those assertions live.
- **FR-13** The verification MUST run unattended on a clean machine with no prior agent state, for every supported platform, on every change.
- **FR-14** Every claim the automated verification cannot reach MUST be listed in the usage document as verified by hand, with the procedure.
- **FR-15** A consumer MUST be able to widen one project's granted reach only through an override supplied at invocation by the human or the calling environment. No file inside a project directory may widen reach. FR-25's authoring surface is declared by the calling-environment route, which is why it is present for the consumer who declared it and absent for everyone else.
- **FR-16** An authentication failure MUST be distinguishable, from its output alone, from a confinement denial.
- **FR-17** Credential substitution MUST NOT silently break tools inside the boundary. Where it inspects encrypted traffic, inspection applies uniformly and trust in the inspecting authority reaches every runtime inside the boundary. Exempting a destination from inspection is a fallback, permitted only where propagating trust to a given runtime proves impossible, and recorded where it is used.
- **FR-18** The environment MUST carry no packages, variables or ignore rules belonging to the prior Kafka project.
- **FR-19** The canonical published reference MUST be named identically in every document. The usage document currently names a different owner and a different repository; that is corrected.
- **FR-20** The confinement description MUST be authored so that both supported platforms enforce the same effective reach, expressed in the semantics of the more restrictive one. A platform whose enforcement is weaker is described under FR-11; weakness is never licence for a wider reach.
- **FR-21** A pre-existing host-global agent configuration MUST NOT direct a confined session, and MUST NOT prevent one from working. Its confinement descriptions MUST take no part in deciding a session's reach, on pain of letting configuration outside the boundary define the boundary; its credentials, conversation history and session state MUST stay unreachable, which is FR-6 and P1 applied to the case a migrating consumer actually presents. The consumer's own authoring surface is the sole exception, governed by FR-25. A consumer who already configures these agents for their whole machine adopts this environment for one project without changing the rest, and the usage document states that path.
- **FR-22** Where an agent extends itself by fetching code at run time, that extension MUST be provisioned before the session rather than fetched from inside it.
- **FR-23** A confined session's version-control toolchain MUST be directed at configuration this environment wrote, rather than left to search the home directory for it. Withholding the grant would already stop the host file being read, but it would leave the outcome dependent on what the host happens to contain, and it would leave the session without a commit identity. Directing the toolchain instead makes the effective configuration the same on every machine, which is what the repetition scenarios ask for, and gives that identity somewhere to live. The author's name and address are copied out of the host once, at setup: they are not credential material, the copy is visible in the file it produces, and a consumer may supply their own values in place of the host's.
- **FR-24** A confined session's commits MUST NOT depend on key material outside its reach. Unsigned is the default, and the configuration this environment writes does not ask for a signature. Where a consumer wants signatures, the key MUST reach the session as a forwarded agent socket or a secret-service request supplied at invocation under FR-15 — never as a granted directory. FR-3 excludes that grant anyway: `ssh` and `gpg` both take a key from an agent over a socket, so a key directory is redirectable and the grant would rest on convenience. A checkout that demands a signature the session cannot produce fails visibly, per R11 and **P9**, rather than being committed unsigned.
- **FR-25** A consumer MUST be able to make their authoring surface available inside a confined session — for every agent shipped, and at every location that agent reads such extensions from, or with the uncovered location named. The declaration is made once for the machine under FR-15, so a consumer's every project picks it up without repeating it and a stranger who clones one of those projects gets none of it. No file inside a project directory may make the declaration, per R5. The surface is lent, not handed over: a session MUST NOT be able to modify what it reads there, so a compromised session cannot rewrite the instructions every later session will read. This is a grant of directives rather than of data — an extension can tell an agent to run a program — and that is precisely why the declaration belongs to the consumer and to the machine, never to a project.
- **FR-26** An agent's executable extensions MUST NOT arrive by FR-25's declaration. Where the environment needs one, it provisions it inside the project directory under FR-22 rather than granting the host location the agent would otherwise load it from. A consumer who wants their own supplies it under FR-15 as a widening of its own, and the usage document states why that is a larger grant than FR-25's: such code runs with everything the session can reach, whereas an authoring surface only tells the agent what to do.

**Non-functional.**
The change honours [docs/CONSTITUTION.md](../../docs/CONSTITUTION.md), and the plan's Constitution Check records how.
**P1** governs the whole feature: nothing writes config, cache, state or temp outside the project except a registry entry, and isolation is asserted rather than assumed.
**P8** requires purity and idempotency — no impure evaluation, every external input pinned with its lock committed, no confinement description fetched from a network registry at run time, effects confined to activation and setup, and repeated application observably inert; Rep1 through Rep3 exist to prove the last.
**P9** forbids silent fallbacks: FR-10 and R6 are its direct expression, exit status carries the outcome, and no unenforceable confinement degrades quietly into an open one.

## Success criteria

- **SC-1** For every agent shipped, with no override in force, every granted filesystem path resolves under the project directory, belongs to that session's execution substrate, or matches a leak-registry entry. The substrate half is an equality rather than a containment, so a grant wider than what the session runs fails even though every path in it is a substrate path. The property holds as agents are added, without editing the check.
- **SC-2** The registry is countable in one place, every entry carries a justification, and no entry rests on convenience, so erosion is visible in review rather than discovered later.
- **SC-3** Every scenario here maps to exactly one executable check, and every check maps back to a scenario.
- **SC-4** The verification command's exit status is sufficient to accept or reject a commit; no human reads its output to decide.
- **SC-5** A stranger on a clean machine reaches a confined agent session in one command from the canonical reference, with no step depending on the author's configuration.
- **SC-6** No value that authenticates against a provider from outside the boundary exists at rest inside any project directory.
- **SC-7** Two consecutive verification runs on an unchanged repository produce the same result.
- **SC-8** Each supported platform is verified by the same command asserting the same properties, and the effective reach observed is the same on both. Where a platform's enforcement strength is weaker, the difference is documented; a platform that is neither verified nor documented as weaker is not claimed.
- **SC-9** For every agent shipped, a declared authoring surface arrives at every location that agent reads extensions from, or the location it does not arrive at is named in the usage document. A consumer never has to discover by experiment which of their extensions came with them.

## Assumptions & Constraints

**Constraints given by the prompt or by intake**

- **The confinement mechanism is `nono`.** The prompt names it, so it is a constraint, not a decision this spec reopens. How it is wired belongs to the plan.
- **No container.** The prompt's premise is accepted: the devcontainer is removed, not kept alongside.
- **Supported platforms are `x86_64-linux` and `aarch64-darwin`**, both verified on clean machines. "Experimental" applies to the *enforcement guarantee* on macOS, not to whether macOS is verified.
- **Agent state lives in the checkout**, accepting that wiping untracked files destroys history.
- **Credential substitution is in scope**, rather than deferred behind a simpler credential grant, and the intended mechanism is uniform across all three agents. An agent for which it proves unreachable ships with the weaker guarantee documented, rather than being dropped.
- **Confinement has no override.** When it cannot be enforced, nothing starts. The unconfined agent stays reachable only by declining to use the confined entry point.
- **The leak registry records justifications only** — no expiry, no issue ID, reviewed in the diff.

**Assumptions validated by research**

- The confinement mechanism ships from the repository's existing pinned package source, at a real released version, permissively licensed, built for both supported platforms.
- Operating-system-level confinement is available on current Linux and on macOS; no container runtime is required.
- Grants and injected environment values can be bound to the current project directory without generating anything per project, so per-project variance needs no code generation.
- Which host environment variables reach a confined session is controllable. FR-5 rests on this.
- Configuration roots relocate through a documented variable for `opencode` at directory granularity, and — verified against the agent itself, the two research rounds having disagreed — for `pi` fully. `claude-code` exposes many such variables rather than one, and three of them, verified against the agent, cover everything a session writes; nothing survives beneath the home directory. FR-4 admits registry entries because some agent may yet resist relocation, not because any one is known to — and none is.
- A relocated configuration root takes the credential with it, so an agent authenticated on the host is not authenticated inside a project confined to its own root. FR-7 therefore cannot be met by relocation, and rests entirely on the credential reaching the session by a route other than the filesystem.
- The mechanism ships no confinement description for any named agent — only descriptions for language runtimes — so this environment authors its own, in the locally authored tier, alongside the network registry tier it declines to use. Nothing need be fetched from the registry, so P8's ban on unpinned run-time fetching costs no capability. A locally authored description is versioned with this repository rather than with the mechanism, which is the stronger position: it cannot drift under a mechanism upgrade, and it cannot inherit a grant the mechanism's own packaged description chooses to make.
- A description inherits the mechanism's floor whether or not it names a parent, so it declares every grant it wants and names no parent. The floor is the same either way, and naming one would suggest an inheritance that is not what is happening.
- The mechanism anchors its own supervisory state at a fixed path beneath the home directory, which cannot be relocated, and refuses to start if a grant overlaps it. That path is therefore state the mechanism writes outside the checkout rather than reach granted to a session, and so it is enumerated as an accepted leak but is **not** a registry entry — the registry describes granted reach, and this path is the one path that cannot be granted. The home directory is never granted broadly.
- Granting the project directory is not automatic at the level a session needs. The mechanism's convenience grant of the working directory is read-only unless the description says otherwise, so the description states the level rather than inheriting it.
- The mechanism refuses to start, fatally, when a grant would expose its own supervisory state, rather than starting open. This is a fail-closed behaviour the pre-flight check can rely on.
- Interception of encrypted traffic is a documented cause of ordinary tools rejecting certificates, and trust in the inspecting authority does reach the runtimes inside the boundary — observed, not merely documented, as a set of standard trust-bundle variables naming an authority minted for that one session. FR-17 rests on this.
- Interception is per-destination and is off unless a destination asks for it. That bounds FR-17: the obligation to propagate trust attaches wherever inspection is switched on, and a session that inspects nothing has nothing to propagate. It also means a check that merely observes an ordinary tool succeeding proves nothing, because a tool talking to an uninspected destination succeeds by validating the real authority. Only the difference between trusting and not trusting is evidence.

**Assumptions the plan must confirm before building on them** — each is a feasibility question with a decided fallback, not an open decision.

Three that were on this list have been confirmed and moved above: that every agent can be pointed at a substituted credential endpoint — which turned out not to be what FR-6 depends on at all, since inspection reaches the real destination and endpoint substitution is only a fallback; that `pi`'s configuration root genuinely relocates, which it does; and that `claude-code`'s relocates far enough, which it does, its fallback of a registry entry going unused because nothing survives beneath the home directory. That last confirmation carried a finding its own fallback had not anticipated — the credential relocates too — which is recorded above as a fact of its own rather than as a gap here, because FR-7's arrangement never depended on reading it from the filesystem. **None remains.**

- ~~That the token-flow agent's credential is reachable at rest on both platforms.~~ **Confirmed unnecessary rather than confirmed true**, and the fallback it carried was never needed. Nothing is at rest to be reachable on either platform: the machine-side credential stays in the calling environment, outside the boundary, and a session receives only a substitute minted for it. So Journey 4's strongest observable is an *absence*, which is platform-independent by construction, and it is asserted identically on both. The corresponding risk below records the same finding from the risk's side.

**Constraints the repository imposes**

- The Constitution gates the plan, but P1, P8 and P9 already bind here and are written into the non-functional requirements.
- `AGENTS.md` states the repository has "no CD pipeline". FR-13 introduces continuous *integration*, which produces no artifact and mutates nothing. The sentence is amended at close-out to permit non-deploying verification while retaining the prohibition on deployment.
- `AGENTS.md` requires every independently consumable directory to carry one `README.md`. The root has none; close-out owes one.
- Verification lives in exactly one place. A second copy of these assertions is a defect.

## Out of Scope

- **Editor delegation.** Handing a confined agent a channel to a host editor, which both drafts carry.
- **General network egress policy.** Restricting which hosts an agent may contact beyond what credential substitution requires.
- **Authenticating the version-control toolchain.** Every host store it would read is denied and stays denied. Writing to a remote is work done outside the confined session. A consumer who wants it inside declares a substitution route of their own, which the mechanism already supports; shipping one would name a particular forge and demand a credential no requirement here asks for.
- **Resource limits.** Memory and process caps.
- **A second confinement backend**, and any abstraction anticipating one.
- **Agents beyond the three named**, `codex` among them. It was named in the first draft of this spec and is deliberately deferred to a feature of its own: it authenticates by its own token flow rather than deriving from `claude-code`, so it shares nothing with FR-7's arrangement and would be a second credential story carried alongside the first. What research established about it is kept, so the follow-up starts with that in hand. SC-1 exists so that adding it does not reopen the checks.
- **The home-manager module currently in the repository.** Its knowledge is absorbed and the module itself leaves; it continues to live in its author's own configuration, serving projects that have not adopted this environment. That coexistence is a requirement (FR-21 and FR-25), not a dependency. One thing the module did is now a requirement rather than a discard: it resolved its confinement descriptions from the author's own home directory, so a session carried what the author had written. FR-25 keeps the capability and FR-21 refuses the part of it that let host configuration decide a session's reach.
- **The drafts' option surface.** `projectName`, backend selection and per-agent enable flags are proposals, not requirements; nothing here depends on them.
- **The third-party name collision.** Another project publishes under a very similar name. Worth knowing; not this feature's problem.

## Risks & Open Questions

1. **Credential substitution may not reach every agent.** *Resolved, and the question it rested on was the wrong one.* This risk claimed FR-6 turns on whether each agent's provider endpoint is configurable, because an agent that performs no token exchange has no exchange to rewrite. It does not: inspection reaches the real destination, so the credential is supplied on the way past it and no endpoint needs substituting. Endpoint substitution exists as a documented fallback, and every agent shipped does expose it. Both routes keep the real secret outside the boundary, so neither is a degraded tier and FR-6 holds uniformly.

   What remains is narrower and sits under FR-7: the two derived agents obtain their credential from the reference agent, and that arrangement is unproven. Note that the fallback this risk originally named — routing one agent's authentication through another's by granting its credential store — is now *excluded* rather than held in reserve, because FR-6 forbids a credential inside the boundary that works outside it and FR-3 forbids a grant resting on convenience. *Fallback*: each agent authenticates for itself, once per machine. That costs FR-7's across-agents axis, which is a usability loss stated plainly, and costs nothing under FR-6.

   *Outcome*: the across-agents axis was neither met as described nor lost — the premise that the two derived agents obtain a credential from the reference agent was falsified, and each instead declares the service it needs and is minted a substitute of its own, which Journey 5 asserts across every agent in the table.

1. **`git` has no credential inside the boundary.** Journey 6 originally asserted that a push over HTTPS still works, but a host credential helper, a stored credentials file and a system keychain all sit outside the boundary, and the default deny groups cover them. *Resolved by taking the stated fallback*: none of the three is reachable, and no requirement here supplies a credential in their place, so Journey 6 narrows to an exchange that needs no credential and the version-control toolchain gets no registry entry. Authenticating it is Out of scope; `research.md` records what each of the three does under confinement.

   *Outcome*: all three host credential sources sit inside deny groups the mechanism marks required, so none is reachable, and Journey 6 stands as the credential-free exchange with no registry entry added for it.

1. **The credential at rest may be unreachable on one platform.** Journey 4 is the strongest observable here and asserts that what sits at rest inside the project authenticates nowhere. On macOS the token-flow agent may keep its credential in the system credential store, which the mechanism denies by default — leaving nothing at rest to assert against, and a substitution path that may never engage. *Mitigation*: make the observable platform-specific and assert, per platform, against what actually exists there. SC-8 already forbids claiming a platform that is neither verified nor documented as weaker.

   *Outcome*: the platform-specific observable was never needed, because nothing is at rest to be reachable — the machine-side credential stays outside the boundary entirely and a session reads only a per-session substitute — so Journey 4's observable is one absence, asserted identically on both platforms. This settles the last of the assumptions above with it.

1. **The supervisory state is immovable, and overlapping it is fatal.** The mechanism anchors its state beneath the home directory and refuses to start when any grant overlaps it. Fail-closed, and therefore welcome, but it constrains every grant and makes any harness that fakes a home directory quietly load-bearing. *Mitigation*: provoke the refusal deliberately and pin its message; it is a refusal check in its own right, and one of the few places a literal earns its pinning.

   *Outcome*: the refusal was provoked deliberately, and then turned out to be worth more than a pinned message. The harness derives, per host, a location the mechanism reports as granting nothing, and refuses to run at all where no such location exists — so no literal was pinned after all. Where that location may live is settled as an accepted leak under P1.

1. **The two platforms diverge semantically.** One enforces allow-list only; the other permits deny-inside-allow. The same description yields different effective reach, so a check asserting "reach is exactly X" can pass on both while the boundaries differ. *Resolved by FR-20*: the description is authored in the more restrictive platform's semantics so both enforce the same reach, and SC-8 asserts the same properties on both. Where the *strength* of enforcement still differs, FR-11 documents it; the reach does not differ.

   *Outcome*: reach did not diverge, and the reason is stronger than the mitigation claimed — the description carries no deny rule at all, so there is nothing for either platform to interpret differently. What did diverge was instrumentation: how a refusal reads, and which platform can observe a denial as against a permitted read.

1. **Minor-version drift on hosted macOS runners.** The runner label tracks a minor series, and which paths the system sandbox implicitly permits can change within it. A refusal check can begin passing for the wrong reason. *Mitigation*: assert the reason, not only the refusal — a denial and a missing file are not the same observation.

   *Outcome*: it realised on the very first macOS run, and the answer was to derive every reason from the host rather than pin it. The refusal wording is measured from a probe carrying its own readability control, so a missing file cannot pass as a denial; one wording assertion was deleted outright as unearned rather than made portable.

1. **The deprecated macOS facility is withdrawn.** The interface in use has been deprecated for several releases. This is a cliff, not drift. *Fallback*: the macOS claim is withdrawn, and SC-8 makes that a documentation change rather than a silent regression.

   *Outcome*: it did not happen. The macOS claim is kept and verified unattended on the current runner image, and what is conceded is enforcement *strength* alone, which FR-11 states as experimental. The fallback was never taken.

1. **Traffic inspection breaks a tool and the user blames confinement.** The documented failure mode: the agent works, a push fails with a certificate error, and the user reads it as a filesystem block. *Mitigation*: Journey 6 and FR-17 make it a first-class scenario rather than a support question.

   *Outcome*: the failure mode is now a permanent control rather than a support note. Journey 6 exhibits the certificate error a broken trust bundle produces alongside the success it replaces, so the two readings are on the record as distinguishable rather than as a thing a user has to guess between.

1. **Confinement is unavailable and the failure is quiet.** A user on an old kernel or inside a constrained container could get an open agent while believing otherwise — the worst outcome in this spec. *Mitigation*: FR-10 and R6 make it a hard, named, `77`-exiting failure, checked executably rather than asserted in a comment.

   *Outcome*: the quiet failure realised twice inside this feature itself, which is the strongest evidence the mitigation was worth having — the pre-flight wrote a canary into the home directory it was meant to prove unreachable, and on one host a missing binary was reported as a missing primitive. Both were fixed, and R6 now separates *cannot verify* from *not enforced*. A host that genuinely cannot enforce remains a stated gap rather than a claim.

1. **The registry grows until isolation is nominal.** Every unpredicted path is easiest to fix by granting it. *Mitigation*: SC-2 makes the list countable and every entry justified, and FR-3 bounds it by kind rather than by count — a path qualifies only where the tool structurally cannot be directed elsewhere. A count would be arbitrary and would invite spending the budget; the kind test is reviewable on each diff. Today no entry meets it: the one candidate the feature found, the execution substrate, turned out not to be a leak at all and became a category of its own under FR-2, and the mechanism's own supervisory state is an accepted leak the registry cannot express because the mechanism refuses to grant it. An empty registry is therefore the expected state, and the risk this records is a path being written into it that a redirection would have handled.

   *Outcome*: it shrank rather than grew. The one entry the feature ever held became a category of its own under FR-2, and SC-1's equality holds in both directions — so an entry granting nothing fails as loudly as a grant nobody registered.

1. **Substitutes are evicted after long disuse.** The substitution store has retention and capacity limits, so a user returning after months sees an authentication failure. *Mitigation*: FR-16 and R8. The store is not ours, so the requirement is that the *outcome* be distinguishable; we cannot demand a particular error shape from upstream.

   *Outcome*: distinguishability was made observable without waiting for retention — an invalidated substitute is answered locally, inside the authentication family and carrying none of the provider's own headers, which is exactly the distinction R8 asks for. Only the retention-driven case itself is hand-verified.

1. **`claude-code`'s configuration override does not fully hold.** Its subagent and lock paths are documented as falling back to the fixed home location. Journey 2 could pass for a simple session and fail once subagents run. *Mitigation*: exercise the fallback case explicitly, not just a plain session.

   *Outcome*: the fallback is real, and worse than documented — relocation *adds* the home-directory location rather than replacing it. Journey 2 therefore drives the subagent listing and a background spawn rather than a plain session, and no registry entry was needed, because every fallback resolves under a home the description grants nothing of.

1. **Journey 4 cannot be fully automated.** A live token flow needs a browser and a real account. *Mitigation*: FR-14 requires it be listed as hand-verified, and the structural half runs unattended against mock credentials — so the automated run checks substitution shape even though it cannot check a real login.

   *Outcome*: taken as written. The structural half runs unattended against a fabricated credential and asserts substitute form, per-session distinctness and absence at rest; the live login and the live rejection are listed as hand-verified with their procedures, which is what FR-14 asks and all it asks.

1. **Streamed responses may not survive interception.** Agents consume streaming responses, and an intercepting proxy is a plausible place for them to stall or truncate. A confined agent that works for short replies and hangs on long ones would be blamed on confinement. *Mitigation*: exercise a streamed response, not only a request-response round trip.

   *Outcome*: **this is the one risk here that closed as an open gap rather than as a resolution.** No automated check exercises a streamed response, because no check can make a live provider call at all, so the mitigation survives only as a hand step — listed, with its procedure, in the usage document.

1. **The cheap check may not be machine-readable.** SC-1 wants every granted path asserted without a real machine, which the mechanism's rehearsal mode can supply because it resolves the description in userspace before touching the kernel. If its output is prose rather than structured, the check parses text and becomes brittle across versions. *Mitigation*: prefer a structured interrogation of individual paths over scraping a summary.

   *Outcome*: it did not arise — the rehearsal output is structured, so SC-1's assertions are set equalities computed over it and nothing parses prose. The per-path interrogation the mitigation preferred is used only where a *verdict* is the question, and is deliberately barred from standing in for what the kernel enforces.

1. **Concurrent sessions may contend.** FR-8 requires two projects to run at once, and every supervised session writes beneath one shared supervisory state directory, so contention is plausible and would surface as an intermittent failure. *Mitigation*: Journey 3 runs both sessions genuinely concurrently rather than in sequence. Measured since: the shared directory is real and the supervisor guards its ledger with a lock, two concurrent sessions interfere in nothing observable, and the loopback port this risk was originally written around does not appear.

   *Outcome*: the two premises came apart. The shared directory is real and is lock-guarded, genuinely concurrent sessions interfered in nothing observable, and the port the risk was written around does not exist — so Journey 3 asserts mutual unreachability rather than the absence of contention.

1. **A migrating consumer sees two configurations and cannot tell which won.** FR-21 and FR-25 together mean part of a host-global setup arrives and the rest does not, which is a sharper version of the same hazard than the original, where none of it arrived. A consumer whose skill loaded but whose stored session did not will reasonably conclude the boundary is arbitrary. *Mitigation*: Journey 8 and R9 assert the two halves separately, so the line between them is executable rather than described, and SC-9 forbids leaving a location's status to be discovered by experiment. The usage document names the migration path rather than leaving it to be inferred.

   *Outcome*: the line is observable rather than described — the declared surface is asserted to be exactly what arrives and nothing more, with a separate arm proving a host confinement description sitting in that same home takes no part in deciding reach. What one platform has no instrument to observe is reported as a skip and named, not asserted weakly under the same name.

1. **The authoring surface is a directive channel, and the checks may only prove it is a data channel.** An extension can instruct an agent to run a program, so FR-25 grants rather more than the file bytes. The failure mode is a check that asserts the file is readable and calls the requirement met, while never establishing that only the consumer's own declaration can put something there. *Mitigation*: R5 and Journey 8's second scenario carry that weight — a project cannot declare the surface, and an undeclared machine gets nothing — and the grant is read-only, so a session that reads a directive cannot leave one behind for the next.

   *Outcome*: contained structurally rather than argued. Only the calling environment can declare the surface, a checkout's own description and configuration were measured to change reach by nothing, the grant is read-only with the surface observed byte-identical after an attempted write, and only skills are carried — so no executable location is lent at all, which is FR-26 held rather than merely stated.

1. **A shared extension root is read `$HOME`-relative and slips past the environment's redirection.** Some extension locations are agent-specific and move when the agent's own configuration root moves; others are shared between agents and anchored at the home directory, so they are reached by a different route and neither the redirection nor the grant treats them alike. An extension in the second kind can therefore appear inside a session that declared nothing, which is FR-2 violated by accident rather than FR-25 satisfied. *Mitigation*: enumerate the locations per agent before granting any, and let SC-1 assert the undeclared default rather than assuming the redirection covered everything.

   *Outcome*: the leak was real, and was found by observation rather than by reading — an undeclared session listed nine skills reached through a home-relative root. So the locations were enumerated per agent before anything was granted, and the undeclared default is asserted as a set equality against a fully populated host home rather than trusting that nothing was granted.

## Review checklist

- [x] Every scenario has exactly one `When`, and a `Then` that is observable
- [x] At least one refusal scenario is present, and it is a real denial rather than an error message — eleven are present, including a fail-closed platform refusal, an untrusted-repository refusal, a host-global-configuration refusal and a host-tool-configuration refusal
- [x] A repetition scenario is present, or the feature provably changes no state — three are present
- [x] Every requirement FR-1..n is covered by at least one scenario, with four stated exceptions rather than silent gaps: FR-14 and FR-19 are documentation obligations verified in review, and FR-22 and FR-26 constrain how the environment is built rather than how a session behaves, so both are verified as the absence of a thing — run-time fetching, which P8 already forbids, and a host executable-extension location among the grants, which SC-1 already asserts
- [ ] No implementation detail appears anywhere in this file — **not fully clean, deliberately.** The confinement mechanism is named because the prompt names it, and the exit status `77` is pinned because a caller branches on it. Both are confined to Constraints and to FR-10, and no scenario depends on the mechanism's identity. Flagged for the reviewer rather than hidden
- [x] Vocabulary names every new term, and no synonym for an existing one was introduced — `agent confinement` is deliberately distinguished from the repository's existing `project isolation`, and `enforcement tier` from whether a platform is verified
- [x] Goals and Non-Goals are stated, and Out of Scope names the areas left alone
- [x] Every `[NEEDS CLARIFICATION]` marker is listed under Risks & Open Questions — none remain. All four were resolved in review: two by research, two by decision with a recorded fallback. What survives them are risks with named mitigations, which is the correct place for a feasibility unknown that a plan discovers by building
