# Scope

GitHub Spec Kit is used for substantive software engineering work. Read-only investigation, explanation, extremely small typo fixes, and very low-risk minor changes do not require the full lifecycle.

# Governed substantive-work entry

For substantive work, the upstream Spec Kit artifacts form the implementation contract. Before the first Feature in a project, ensure a usable project Constitution exists by invoking `/speckit-constitution` when it is absent or only a placeholder. The project may opt into committed high-assurance review evidence; adaptive short-path work does not create review ledgers solely because the request is substantive.

Requests to create, design, plan, or implement a substantive Feature, including “按 Spec”, “use Spec Kit”, “form a plan”, or equivalent wording, must first be classified. Undecided ideas use Assessment, known defects use Bug Fix, low-risk Features use the short path, and high-risk Features use the full upstream path. Before high-risk Feature artifacts are created or updated, ask whether to use the task-scoped `governed-sdd` profile or the adaptive full upstream path. Read-only investigation, explanation, trivial typo correction, and extremely small low-risk changes may remain outside SDD.

User approval phrases such as “the plan is acceptable” or “proceed with this approach” approve only the review object explicitly identified in the request. This approval does not authorize direct application-code edits that skip artifact alignment or later review gates; it authorizes the Agent only to advance that object into the governed upstream Spec Kit workflow.

When an approved direction is missing from or inconsistent with the current specification, plan, or tasks, the Agent must first use the upstream Spec Kit workflow to update the relevant artifacts. The Reference governance package must never edit `.specify/**`, `specs/**`, or native Agent-generated integration files to enforce this policy.

If the user is only discussing alternatives and has not expressed implementation intent, the Agent must remain in discussion. If implementation intent exists, the Agent may proceed automatically after artifact alignment without requiring the user to repeat “use Spec Kit”.

If implementation reveals a changed requirement, assumption, risk, public contract, data boundary, or affected component, the Agent must pause, update the upstream Spec Kit artifacts, and then resume from the resulting tasks. It must not silently expand the implementation scope.

# Discovery and routing contract

Before upstream specification for high-risk work, inspect the repository for facts and create `docs/spec-kit/features/<feature-id>/DISCOVERY.md`. For an undecided idea, use the official Assessment extension; for a known defect, use the official Bug Fix extension. Cover the business objective and cost of inaction; actors and permissions; primary, alternative, and negative journeys; inputs, outputs, ownership, lifecycle, retention, migration, and deletion; error, empty, loading, partial-failure, retry, and recovery behavior; security, privacy, compliance, accessibility, localization, performance, scale, availability, platforms, external dependencies, scope, non-goals, measurable acceptance, release gates, and required evidence when the selected route requires them.

Classify each discovery item as `CONFIRMED_FACT`, `USER_DECISION`, `ASSUMPTION_PENDING_APPROVAL`, `OPEN_QUESTION`, `OUT_OF_SCOPE`, or `DEFERRED_WITH_OWNER`. Ask one logical topic per round, investigate repository facts before asking the user, and continue until there is no blocking open question. Recommendations are allowed but never become decisions without user approval. Product behavior, release scope, security exceptions, privacy, and data retention must not be filled from an unstated default.

For high-assurance work, specification may begin only when high-impact assumptions are approved or excluded, scope and non-goals are explicit, at least one primary journey has a complete Given/When/Then skeleton, acceptance and failure evidence can be defined, and the user has approved the exact Discovery snapshot. Adaptive short-path and adaptive full-path work use the upstream Specify and Clarify contracts appropriate to their risk. A task-scoped high-assurance choice must not modify the project default configuration; both routes continue to use upstream Spec Kit.

# High-assurance artifact review gates

The required review objects are `DISCOVERY`, `SPECIFICATION`, `PLAN_BUNDLE`, `TASK_PACKAGE`, and `REMEDIATION` when analyze or implementation drift requires artifact changes. Their transitions are:

```text
DRAFT → REVIEW_REQUESTED → APPROVED → SUPERSEDED
                    ↘ CHANGES_REQUESTED → DRAFT
APPROVED + changed artifact hash → STALE
```

Each request must name the review object, artifact paths, content SHA-256 values, decision summary, open risks, and evidence reference. Store append-only events in `docs/spec-kit/features/<feature-id>/REVIEW_LEDGER.json`; derive current state from events and live artifact hashes. The `docs/spec-kit/features/**` subtree is project-local evidence and must survive governance synchronization byte-for-byte.

An Agent cannot approve on the user's behalf. A checklist pass, validator result, tests, another Agent's self-review, or ambiguous approval without an identified artifact set and hashes is not approval. A changed hash, superseded dependency, `CHANGES_REQUESTED`, or unresolved high-severity analyze finding blocks the next stage. Approval proves only that the identified artifact version was reviewed; it does not prove implementation or validation.

# Tiny-model task readiness

Every implementation task must remain compatible with the upstream checkbox, task ID, story, action, and path format, and must add a self-contained detail block containing one observable objective; traceability; minimum context; preconditions; exact allowed files; read-only references; forbidden changes; inputs and outputs; invariants and edge cases; ordered implementation steps; executable verification with expected results; completion evidence; stop conditions; and downstream handoff.

Split any task with multiple independently verifiable results, mixed lifecycle stages, producer-and-multiple-consumer changes, cross-module work without a prior contract task, no single deterministic verification result, or an unresolved product, architecture, privacy, or security choice. A production change and its focused test may remain one task when together they produce one result.

Before `TASK_PACKAGE` approval, run the read-only readiness validator and an isolated cold-start review. The reviewer receives only a sampled task, its declared read-only references, and repository read access, not the originating conversation. Any `NEEDS_CONTEXT`, `HIDDEN_DECISION`, `CONFLICT`, or `UNVERIFIABLE` result returns the package to `CHANGES_REQUESTED`. A readiness pass proves self-containment, not executor capability.

# Projects and brownfields

Before making a change, confirm the actual project root; read every applicable project-local rule, README, architecture document, test, dependency, and CI configuration; understand the actual brownfield system; and protect existing user work. When `.specify/` exists, restore the existing project state and do not routinely reinitialize it.

If the project already has the runtime-selected project context anchor, it is collaboratively maintained project rule content. The Spec Kit loader may be appended to or updated inside that file only through a reviewed manager plan; every byte outside the managed region must be preserved byte-for-byte. The manager may create only the exact anchor path supplied and evidence-validated by the current Agent runtime or user. It must never guess, replace, delete, reorder, normalize, or overwrite an anchor.

Before first-time Spec Kit initialization, ask the user for the BCP-47 language tag for new and substantially rewritten project documentation. Pass the explicit value to `plan-init`, store it in `PROJECT_CONFIG.json`, and render the corresponding rule in the selected context anchor. Never infer it from locale, Agent identity, existing documents, or a default; do not mass-translate existing documents.

# Agent-neutral operation and native integrations

The governance package does not enumerate Agent products in advance. The current Agent must have its runtime ID and exact integration key explicitly declared by the user, host, or Agent runtime; a display name cannot produce a mutation plan. Do not infer identity from PATH, directory names, a default integration, similar product names, or Rich catalog output.

When the current CLI provides a native integration for the current Agent, that native integration is mandatory. An unwritable Skills/Commands target or parent directory, insufficient permission, a sandbox block, managed-file repair failure, or CLI installation failure is `NATIVE_INSTALL_BLOCKED`. Do not downgrade to generic, use another key, or report completion because of convenience, permissions, paths, or conflicts. A binding may be `active` only after fresh-session verification confirms the runtime ID/key match, the context anchor is loaded, and managed files are healthy.

Generic is allowed only when the current CLI has no native integration, project configuration permits it, the current version has a human-reviewed native-absence attestation, the target Agent is compatible with the generic Markdown Commands contract, the project's installed integration set is empty, and the user approves the exact plan. Generic must be marked as non-native and limited support.

# Spec Kit state and lifecycle

New projects must use explicit `specify init --here --non-interactive --integration <approved-key>`. If a non-interactive init omits the key, the CLI may select a default product, so the manager must reject that command. In a non-empty brownfield, `--force` may appear only in a dedicated `plan-init`, with rehearsal, a scope snapshot, backup, exact authorization, and failure recovery; no other command may use `--force`.

When the current high-risk Feature selects the `governed-sdd` profile, it follows:

`discovery → review discovery → specify → clarify → review specification → plan → review plan bundle → checklist → tasks → readiness audit → cold-start review → review task package → analyze → remediation gate when needed → implement → validate → converge → completion review`

This governed sequence preserves the upstream core lifecycle:

`constitution → specify → clarify → plan → checklist → tasks → analyze → implement → validate → converge`

In adaptive mode, Clarify, checklist, and analyze are triggered by ambiguity and risk; validate and converge remain required before substantive completion. For a Feature that selects `governed-sdd`, all configured high-assurance gates are required. Missing optional companion capability does not block adaptive upstream work. Implementation must remain synchronized with the accepted specification, plan, tasks when present, project constraints, and tests.

At Spec Kit project entry, inspect the CLI, active integration, and official `assess` and `bug` extensions. If a required capability is missing, ask whether to install it. If the user declines, return `HANDOFF_TO_AGENT` and stop applying Reference governance to that capability.

# Upstream update maintenance

The upstream update check is independent of the central Reference. Whenever `.specify/` exists, run the installed CLI's read-only `specify self check` at most once before the first substantive action in each new Agent session, even when this project has no `docs/spec-kit/**` package or the computer has no central Reference. Ask the user before `specify self upgrade` only when a newer CLI is reported. Then use the current CLI's actual help/status/list contracts to refresh installed integration, extension, and workflow components automatically when supported. Do not install missing components, assume presets are covered, invent flags, or add `--force`; modified-file conflicts and other irreversible choices require user review.

# Default and integration coexistence

The project default integration uses a pinned strategy. Routine onboarding must not change the default. A default change may update configuration only after project configuration opens a one-time change window, an independent plan is generated, `specify integration use <key>` is run, and status verification succeeds; failure must restore the prior default. Extensions, presets, events, and shared infrastructure of non-default integrations must be verified separately; do not claim parity.

# Authority order

The policy authority order is: current user instructions, higher-priority runtime rules, safety rules, every applicable project-local rule, project `LOCAL_OVERRIDES.md`, project `POLICY.md`, personal global Bootstrap, project `REFERENCE.md`, personal central Reference, and upstream documentation.

The runtime-fact order is: current-project `.specify/`, installed integrations and manifests, the installed CLI, project `REFERENCE.md`, personal central Reference, and upstream documentation. When runtime facts conflict with the project snapshot, the runtime prevails and the discrepancy must be recorded.

# Validation, upgrades, and completion

Relevant tests, builds, linting, schemas, reproductions, validation, and convergence must be run; failures must not be concealed. The CLI, integrations, extensions, governance package, and Skills are separate layers, and upgrading one layer must not assume that the others upgrade automatically. Central upstream changes must be classified as `NONE`, `REFERENCE`, or `POLICY`; the checker is read-only, the baseline advances last after review, and upstream history must not be merged or Policy automatically deployed.

Completion requires agreement among user intent, accepted artifacts, implementation, project constraints, validation, convergence, the native integration, adapter verification, and capability-inventory conservation. Approval of a conversational proposal is not completion evidence. Do not report completion when a blocker, unmapped legacy capability, unplanned deletion, downgrade, invalid state, or default change exists; artifact drift is also unresolved work.

# Central Reference maintenance

When the global Policy is actually loaded and provides a readable `SPEC_KIT_GOVERNANCE_SOURCE`, an existing `.specify/` project with this committed governance package may perform one read-only central Reference check before the first substantive task in a new Agent session. If the global Policy, source locator, or source verification is absent, skip the check silently and never scan the computer for a Reference directory.

A verified Reference update is automatically synchronized through the exact hash-bound `auto-upgrade` operation. Project-owner approval is not required because only the Reference-owned governance package, manager, and managed context-anchor block are in scope. Never update `.specify/**`, `specs/**`, native Agent files, or business code as part of this sync.

After synchronization, inspect the current upstream Spec Kit artifacts and let the upstream workflow decide whether a specification, plan, task list, or other Spec artifact needs updating. A Reference update is not evidence that any such artifact is stale.
