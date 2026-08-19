# Feature Specification: Confined agent sessions per project

**Directory**: `specs/001-agent-sandbox/` | **Branch**: `001-agent-sandbox` | **Created**: 2026-08-18 | **Status**: Draft

**Prompt**: Based on the provided drafts @draft1.md @draft2.md , create a spec for a reusable sandbox utilizing nono with batteries included for project based isolations. for clarification: it seems that we can get the same isolation with nono on the host system instead so we don't need devenv with containers. If anything is unclear, ask first. Research and double check feasability as well.

## Overview

Today this repository keeps *its own tools* inside the project. It does nothing to keep an *agent* inside the project. An agent entered from here reads the whole home directory, inherits every host secret in its environment, and writes session state that the next project will see.

This feature makes agent confinement the product. A project points at this repository and gets four coding agents — `codex`, `claude-code`, `opencode`, `pi` — confined by the operating system: they read and write inside the checkout and nowhere else, they inherit no host secret, their state stays in the checkout, and no credential material reachable from inside the boundary authenticates from outside it.

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
| **Leak registry** | The single file enumerating every path outside the project directory a confined session may reach, each with a written justification. | the drafts' `sharedCredentials`, `extraAllowPaths` |
| **Registered exception** | One entry in the leak registry. Constitution P1's "accepted leak", given a home. | — |
| **Credential material** | Anything an agent can read that is presented to a provider as proof of identity — a file, or a variable in its environment. Deliberately covers both, because one shipped agent has no credential file. | the drafts' `sharedCredentials.claude` |
| **Substitute credential** | Credential material that authenticates only from inside the boundary and is useless copied out. | — |
| **Enforcement tier** | How strong the operating system's confinement guarantee is on a given platform. Distinct from whether that platform is verified. | — |
| **Pre-flight check** | The executable probe run before an agent starts, which establishes that confinement can actually be enforced on this host. | `devenv.nix`'s unverified platform claims |
| **Consumer** | A downstream project that points at this repository. | the handbook's "downstream flake" |
| **Host-global agent configuration** | Configuration a consumer has already installed in their home directory to serve every project on the machine, independent of this repository. | — |

## Scenarios

### Journey 1 — A stranger gets a confined agent (P1)

The entry point. Without this nothing else is reachable, and it is the journey that proves the repository is consumable rather than merely present.

**Independently verifiable by**: entering from the canonical reference on a clean machine and asserting the started session's granted reach against the leak registry.

1. **Given** a machine with none of the author's dotfiles and no prior agent state
   **When** the stranger enters the environment from this repository's canonical published reference and starts an agent
   **Then** the agent starts
   **And** the session's granted filesystem reach consists only of the project directory and paths in the leak registry.

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

**Independently verifiable by**: starting a session in a second checkout and asserting the agent reports an authenticated state.

1. **Given** the user has authenticated for one project
   **When** they start a confined session in a second, unrelated project
   **Then** the agent is authenticated with no further login.

### Journey 6 — The toolchain still works (P2)

This journey exists because credential substitution inspects encrypted traffic, and the documented failure mode is that the agent keeps working while ordinary tools reject the interception certificate — which users misread as a filesystem denial.

**Independently verifiable by**: the exit status of an ordinary tool's HTTPS exchange with that remote.

1. **Given** a confined session in a checkout with a remote
   **When** the session exchanges with that remote over HTTPS
   **Then** the exchange succeeds.

The exchange is one that needs no credential. Nothing here supplies the version-control toolchain with a credential, and every host store it would otherwise read is denied outright, so a push would fail for want of a credential whatever the inspecting authority did — which is the opposite of what this journey is for. Trust in the inspecting authority is the property, and FR-17 is the requirement; authenticating the toolchain is a separate concern, addressed under Out of scope.

### Journey 7 — The claims are checked on clean machines (P1)

**Independently verifiable by**: the exit status, plus planting a registry entry and observing the expected set change without the check being edited.

1. **Given** the repository at a commit
   **When** the verification command runs unattended on a clean machine for each supported platform
   **Then** it exits zero
   **And** its exit status alone separates a passing commit from a failing one
   **And** the expected reach it compares against is derived from the leak registry rather than restated inside the check.

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

1. **R9 — A host-global agent configuration does not reach the session.**
   **Given** a machine whose home directory already configures these agents for every project, as a consumer migrating from a global setup would have
   **When** a confined session starts in a project directory
   **Then** no part of that host-global configuration is readable from inside the session
   **And** the session starts and works regardless, rather than depending on it or failing on its absence.

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

## Requirements

- **FR-1** The environment MUST provide confined sessions for `codex`, `claude-code`, `opencode` and `pi`. All four are required. `codex` is the reference case, because its configuration root relocates wholly through one documented variable and that relocation is the best attested of the four.
- **FR-2** A confined session's granted filesystem reach MUST be the project directory plus leak-registry entries, and nothing else.
- **FR-3** The leak registry MUST be a single file. Every entry states why the path is granted and why a narrower grant does not work. It carries no expiry mechanism. An entry is admissible only where the tool structurally cannot be directed elsewhere; convenience is never a justification.
- **FR-4** Agent state MUST be written inside the project directory. Where an agent cannot be directed to do so, its state path MUST be a registry entry under FR-3.
- **FR-5** A confined session MUST NOT inherit host environment variables carrying provider credentials.
- **FR-6** No credential material readable from inside a confined session MUST authenticate from outside the boundary. This constrains the outcome, not the mechanism: an agent that authenticates by token flow and an agent that authenticates by key in its environment may satisfy it differently.
- **FR-7** Authenticating once on a machine MUST serve every project on that machine.
- **FR-8** Concurrent confined sessions in different project directories MUST share no agent state and MUST NOT reach each other's project directory.
- **FR-9** Modifying the confinement description from inside a confined session MUST alter neither that session's boundary nor any later session's boundary until a human re-enters the environment.
- **FR-10** Before an agent starts, a pre-flight check MUST establish that confinement can be enforced on this host. If it cannot, nothing starts, the message names the missing primitive, and the exit status is `77`. The literal is pinned because a caller branches on it. No flag, variable or configuration makes the confined entry point proceed unconfined. Running an agent without confinement stays possible only by not invoking the confined entry point at all — a deliberate and visible act, which the usage document describes rather than conceals.
- **FR-11** The repository MUST name its supported platforms and, for each, the enforcement tier its operating system provides. A platform whose guarantee is weaker says so, in the usage document, with the difference named.
- **FR-12** One command MUST verify every scenario in this spec, and MUST be the only place those assertions live.
- **FR-13** The verification MUST run unattended on a clean machine with no prior agent state, for every supported platform, on every change.
- **FR-14** Every claim the automated verification cannot reach MUST be listed in the usage document as verified by hand, with the procedure.
- **FR-15** A consumer MUST be able to widen one project's granted reach only through an override supplied at invocation by the human or the calling environment. No file inside a project directory may widen reach.
- **FR-16** An authentication failure MUST be distinguishable, from its output alone, from a confinement denial.
- **FR-17** Credential substitution MUST NOT silently break tools inside the boundary. Where it inspects encrypted traffic, inspection applies uniformly and trust in the inspecting authority reaches every runtime inside the boundary. Exempting a destination from inspection is a fallback, permitted only where propagating trust to a given runtime proves impossible, and recorded where it is used.
- **FR-18** The environment MUST carry no packages, variables or ignore rules belonging to the prior Kafka project.
- **FR-19** The canonical published reference MUST be named identically in every document. The usage document currently names a different owner and a different repository; that is corrected.
- **FR-20** The confinement description MUST be authored so that both supported platforms enforce the same effective reach, expressed in the semantics of the more restrictive one. A platform whose enforcement is weaker is described under FR-11; weakness is never licence for a wider reach.
- **FR-21** A pre-existing host-global agent configuration MUST neither reach a confined session nor prevent one from working. A consumer who already configures these agents for their whole machine adopts this environment for one project without changing the rest, and the usage document states that path.
- **FR-22** Where an agent extends itself by fetching code at run time, that extension MUST be provisioned before the session rather than fetched from inside it.

**Non-functional.**
The change honours [docs/CONSTITUTION.md](../../docs/CONSTITUTION.md), and the plan's Constitution Check records how.
**P1** governs the whole feature: nothing writes config, cache, state or temp outside the project except a registry entry, and isolation is asserted rather than assumed.
**P8** requires purity and idempotency — no impure evaluation, every external input pinned with its lock committed, no confinement description fetched from a network registry at run time, effects confined to activation and setup, and repeated application observably inert; Rep1 through Rep3 exist to prove the last.
**P9** forbids silent fallbacks: FR-10 and R6 are its direct expression, exit status carries the outcome, and no unenforceable confinement degrades quietly into an open one.

## Success criteria

- **SC-1** For every agent shipped, every granted filesystem path resolves under the project directory or matches a leak-registry entry. The property holds as agents are added, without editing the check.
- **SC-2** The registry is countable in one place, every entry carries a justification, and no entry rests on convenience, so erosion is visible in review rather than discovered later.
- **SC-3** Every scenario here maps to exactly one executable check, and every check maps back to a scenario.
- **SC-4** The verification command's exit status is sufficient to accept or reject a commit; no human reads its output to decide.
- **SC-5** A stranger on a clean machine reaches a confined agent session in one command from the canonical reference, with no step depending on the author's configuration.
- **SC-6** No value that authenticates against a provider from outside the boundary exists at rest inside any project directory.
- **SC-7** Two consecutive verification runs on an unchanged repository produce the same result.
- **SC-8** Each supported platform is verified by the same command asserting the same properties, and the effective reach observed is the same on both. Where a platform's enforcement strength is weaker, the difference is documented; a platform that is neither verified nor documented as weaker is not claimed.

## Assumptions & Constraints

**Constraints given by the prompt or by intake**

- **The confinement mechanism is `nono`.** The prompt names it, so it is a constraint, not a decision this spec reopens. How it is wired belongs to the plan.
- **No container.** The prompt's premise is accepted: the devcontainer is removed, not kept alongside.
- **Supported platforms are `x86_64-linux` and `aarch64-darwin`**, both verified on clean machines. "Experimental" applies to the *enforcement guarantee* on macOS, not to whether macOS is verified.
- **Agent state lives in the checkout**, accepting that wiping untracked files destroys history.
- **Credential substitution is in scope**, rather than deferred behind a simpler credential grant, and the intended mechanism is uniform across all four agents. An agent for which it proves unreachable ships with the weaker guarantee documented, rather than being dropped.
- **Confinement has no override.** When it cannot be enforced, nothing starts. The unconfined agent stays reachable only by declining to use the confined entry point.
- **The leak registry records justifications only** — no expiry, no issue ID, reviewed in the diff.

**Assumptions validated by research**

- The confinement mechanism ships from the repository's existing pinned package source, at a real released version, permissively licensed, built for both supported platforms.
- Operating-system-level confinement is available on current Linux and on macOS; no container runtime is required.
- Grants and injected environment values can be bound to the current project directory without generating anything per project, so per-project variance needs no code generation.
- Which host environment variables reach a confined session is controllable. FR-5 rests on this.
- Configuration roots relocate through a documented variable for `codex` fully, for `claude-code` with known fallback cases, for `opencode` at directory granularity, and — verified against the agent itself, the two research rounds having disagreed — for `pi` fully as well. FR-4 admits registry entries because some agent may yet resist relocation, not because a particular one is known to.
- Usable confinement descriptions for the named agents ship compiled into the mechanism, alongside a locally authored tier and a network registry tier. Nothing need be fetched from the registry, so P8's ban on unpinned run-time fetching costs no capability, and the descriptions are versioned with the pinned mechanism rather than drifting under it.
- The mechanism anchors its own supervisory state at a fixed path beneath the home directory, which cannot be relocated, and refuses to start if a grant overlaps it. That path is therefore the registry's first entry, and the home directory is never granted broadly.
- The mechanism refuses to start, fatally, when a grant would expose its own supervisory state, rather than starting open. This is a fail-closed behaviour the pre-flight check can rely on.
- Interception of encrypted traffic is a documented cause of ordinary tools rejecting certificates, and trust can be propagated into the runtimes inside the boundary. FR-17 rests on this.

**Assumptions the plan must confirm before building on them** — each is a feasibility question with a decided fallback, not an open decision.

- That every agent can be pointed at a substituted credential endpoint. The intent is settled and uniform; an agent for which it proves unreachable ships with the weaker guarantee, said plainly.
- That `pi`'s configuration root genuinely relocates. The finding reversed once between research rounds, so it is verified before FR-4 leans on it.
- That the token-flow agent's credential is reachable at rest on both platforms. One platform may hold it in a system credential store the mechanism denies by default, which would make Journey 4's strongest observable platform-specific.

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
- **Agents beyond the four named.** SC-1 exists so a fifth does not reopen the checks.
- **The home-manager module currently in the repository.** Its knowledge is absorbed and the module itself leaves; it continues to live in its author's own configuration, serving projects that have not adopted this environment. That coexistence is a requirement (FR-21), not a dependency.
- **The drafts' option surface.** `projectName`, backend selection and per-agent enable flags are proposals, not requirements; nothing here depends on them.
- **The third-party name collision.** Another project publishes under a very similar name. Worth knowing; not this feature's problem.

## Risks & Open Questions

1. **Credential substitution may not reach every agent.** The intent is settled and uniform, and so is the fallback: an agent it cannot reach ships with the weaker guarantee, said plainly. What is unverified is the route. Rewriting a token-endpoint response cannot apply to an agent that never performs that exchange, so those agents depend instead on proxy-side injection, which requires the agent to accept a substituted endpoint address. **Whether each agent's provider endpoint is configurable is what FR-6 actually turns on — not the credential's file format — and it is the first thing the plan should establish.** *Fallback*: the plugin approach already present in this repository, routing one agent's authentication through another's; failing that, a narrowly scoped short-lived key with egress filtering, recorded as the weaker tier.

1. **`git` has no credential inside the boundary.** Journey 6 originally asserted that a push over HTTPS still works, but a host credential helper, a stored credentials file and a system keychain all sit outside the boundary, and the default deny groups cover them. *Resolved by taking the stated fallback*: none of the three is reachable, and no requirement here supplies a credential in their place, so Journey 6 narrows to an exchange that needs no credential and the version-control toolchain gets no registry entry. Authenticating it is Out of scope; `research.md` records what each of the three does under confinement.

1. **The credential at rest may be unreachable on one platform.** Journey 4 is the strongest observable here and asserts that what sits at rest inside the project authenticates nowhere. On macOS the token-flow agent may keep its credential in the system credential store, which the mechanism denies by default — leaving nothing at rest to assert against, and a substitution path that may never engage. *Mitigation*: make the observable platform-specific and assert, per platform, against what actually exists there. SC-8 already forbids claiming a platform that is neither verified nor documented as weaker.

1. **The supervisory state is immovable, and overlapping it is fatal.** The mechanism anchors its state beneath the home directory and refuses to start when any grant overlaps it. Fail-closed, and therefore welcome, but it constrains every grant and makes any harness that fakes a home directory quietly load-bearing. *Mitigation*: provoke the refusal deliberately and pin its message; it is a refusal check in its own right, and one of the few places a literal earns its pinning.

1. **The two platforms diverge semantically.** One enforces allow-list only; the other permits deny-inside-allow. The same description yields different effective reach, so a check asserting "reach is exactly X" can pass on both while the boundaries differ. *Resolved by FR-20*: the description is authored in the more restrictive platform's semantics so both enforce the same reach, and SC-8 asserts the same properties on both. Where the *strength* of enforcement still differs, FR-11 documents it; the reach does not differ.

1. **Minor-version drift on hosted macOS runners.** The runner label tracks a minor series, and which paths the system sandbox implicitly permits can change within it. A refusal check can begin passing for the wrong reason. *Mitigation*: assert the reason, not only the refusal — a denial and a missing file are not the same observation.

1. **The deprecated macOS facility is withdrawn.** The interface in use has been deprecated for several releases. This is a cliff, not drift. *Fallback*: the macOS claim is withdrawn, and SC-8 makes that a documentation change rather than a silent regression.

1. **Traffic inspection breaks a tool and the user blames confinement.** The documented failure mode: the agent works, a push fails with a certificate error, and the user reads it as a filesystem block. *Mitigation*: Journey 6 and FR-17 make it a first-class scenario rather than a support question.

1. **Confinement is unavailable and the failure is quiet.** A user on an old kernel or inside a constrained container could get an open agent while believing otherwise — the worst outcome in this spec. *Mitigation*: FR-10 and R6 make it a hard, named, `77`-exiting failure, checked executably rather than asserted in a comment.

1. **The registry grows until isolation is nominal.** Every unpredicted path is easiest to fix by granting it. *Mitigation*: SC-2 makes the list countable and every entry justified, and FR-3 bounds it by kind rather than by count — a path qualifies only where the tool structurally cannot be directed elsewhere. A count would be arbitrary and would invite spending the budget; the kind test is reviewable on each diff. Today exactly one entry meets it, the mechanism's own supervisory state, and that one is structural.

1. **Substitutes are evicted after long disuse.** The substitution store has retention and capacity limits, so a user returning after months sees an authentication failure. *Mitigation*: FR-16 and R8. The store is not ours, so the requirement is that the *outcome* be distinguishable; we cannot demand a particular error shape from upstream.

1. **`claude-code`'s configuration override does not fully hold.** Its subagent and lock paths are documented as falling back to the fixed home location. Journey 2 could pass for a simple session and fail once subagents run. *Mitigation*: exercise the fallback case explicitly, not just a plain session.

1. **Journey 4 cannot be fully automated.** A live token flow needs a browser and a real account. *Mitigation*: FR-14 requires it be listed as hand-verified, and the structural half runs unattended against mock credentials — so the automated run checks substitution shape even though it cannot check a real login.

1. **Streamed responses may not survive interception.** Agents consume streaming responses, and an intercepting proxy is a plausible place for them to stall or truncate. A confined agent that works for short replies and hangs on long ones would be blamed on confinement. *Mitigation*: exercise a streamed response, not only a request-response round trip.

1. **The cheap check may not be machine-readable.** SC-1 wants every granted path asserted without a real machine, which the mechanism's rehearsal mode can supply because it resolves the description in userspace before touching the kernel. If its output is prose rather than structured, the check parses text and becomes brittle across versions. *Mitigation*: prefer a structured interrogation of individual paths over scraping a summary.

1. **Concurrent sessions may contend.** FR-8 requires two projects to run at once. Each supervised session takes a loopback port and writes beneath a shared supervisory state directory, so collision or contention is plausible and would surface as an intermittent failure. *Mitigation*: Journey 3 runs both sessions genuinely concurrently rather than in sequence.

1. **A migrating consumer sees two configurations and cannot tell which won.** FR-21 requires a host-global setup to be neither used nor broken, which is precisely the situation in which a user misattributes behaviour. *Mitigation*: R9 asserts the property, and the usage document names the migration path rather than leaving it to be inferred.

## Review checklist

- [x] Every scenario has exactly one `When`, and a `Then` that is observable
- [x] At least one refusal scenario is present, and it is a real denial rather than an error message — nine are present, including a fail-closed platform refusal, an untrusted-repository refusal and a host-global-configuration refusal
- [x] A repetition scenario is present, or the feature provably changes no state — three are present
- [x] Every requirement FR-1..n is covered by at least one scenario, with three stated exceptions rather than silent gaps: FR-14 and FR-19 are documentation obligations verified in review, and FR-22 constrains how the environment is built rather than how a session behaves, so it is verified as the absence of run-time fetching that P8 already requires
- [ ] No implementation detail appears anywhere in this file — **not fully clean, deliberately.** The confinement mechanism is named because the prompt names it, and the exit status `77` is pinned because a caller branches on it. Both are confined to Constraints and to FR-10, and no scenario depends on the mechanism's identity. Flagged for the reviewer rather than hidden
- [x] Vocabulary names every new term, and no synonym for an existing one was introduced — `agent confinement` is deliberately distinguished from the repository's existing `project isolation`, and `enforcement tier` from whether a platform is verified
- [x] Goals and Non-Goals are stated, and Out of Scope names the areas left alone
- [x] Every `[NEEDS CLARIFICATION]` marker is listed under Risks & Open Questions — none remain. All four were resolved in review: two by research, two by decision with a recorded fallback. What survives them are risks with named mitigations, which is the correct place for a feasibility unknown that a plan discovers by building
