# Entering a project

Before any substantive work:

1. Confirm the actual project root.
2. Read `docs/spec-kit/PROJECT_CONFIG.json`, `LOCAL_OVERRIDES.md`, `POLICY.md`, and `MANIFEST.json`.
3. Check `.specify/`. If it exists, recover its existing state and do not initialize again.
4. Classify the request as read-only/explanatory, extremely small and low-risk, governance maintenance, or substantive engineering.
5. When work involves the CLI, an integration, an extension, init, upgrade, rollback, or recovery, also read `REFERENCE.md` and `OPERATING_PROTOCOL.md`.
6. If the loaded global Policy provides `SPEC_KIT_GOVERNANCE_SOURCE`, run the local manager's read-only central Reference check once in the new session; on `UPDATE_AVAILABLE`, run `auto-upgrade` immediately. If it does not, skip silently and do not search for one.

# Substantive task entry

Natural-language requests such as “按 Spec 制定方案”, “use Spec Kit”, “start a Feature”, or equivalent substantive design, plan, or implementation intent are classified before execution: undecided ideas use Assessment, known defects use Bug Fix, low-risk Features use the short path, and high-risk Features use the full upstream path with a task-scoped choice between the adaptive full route and `governed-sdd`.

For every substantive Feature, first ensure the project Constitution exists. If the project has no usable Constitution, invoke the upstream `/speckit-constitution` skill once and review the result before starting the Feature path. A known defect uses Bug Fix and an undecided idea uses Assessment; those extensions are independent entry paths and do not require manufacturing a Feature specification first.

Before creating or updating high-risk Feature artifacts, ask the user to choose one route for the current Feature:

1. `governed-sdd`: enable the companion's high-assurance workflow for this Feature only;
2. adaptive full path: use the complete upstream Spec Kit lifecycle with only the risk-triggered gates that apply.

This choice must not modify `docs/spec-kit/PROJECT_CONFIG.json` or the project's default `workflow_governance.mode`. Both routes use upstream Spec Kit. If `governed-sdd` is selected and its companion is missing, ask whether to install it through the native CLI; a refusal returns `HANDOFF_TO_AGENT`.

When the task-scoped route selects `governed-sdd`, the high-assurance lifecycle is:

`constitution → discovery → review discovery → specify → clarify → review specification → plan → review plan bundle → checklist → tasks → readiness audit → cold-start review → review task package → analyze → remediation when needed → implement → validate → converge → completion review`

The following rules are mandatory:

1. Before specification or application-code changes, inspect the brownfield system. Create or resume a Discovery ledger for high-risk work, Assessment for undecided ideas, and Bug Fix for known defects.
2. A conversation, design note, or user message is not a substitute for a Spec Kit artifact.
3. Stop for explicit user review of high-assurance `DISCOVERY`, `SPECIFICATION`, `PLAN_BUNDLE`, `TASK_PACKAGE`, and required `REMEDIATION`; adaptive short-path work follows the upstream Agent workflow.
4. User approval such as “the plan is acceptable” applies only to the named review object. This approval does not authorize direct code edits or approve a later artifact.
5. If the approved direction is missing from or inconsistent with the current spec, plan, or tasks, use the upstream Spec Kit workflow to update the artifact before implementing it. Do not have this governance package edit `.specify/**` or `specs/**`.
6. If the user is only discussing options and has not expressed implementation intent, remain in discussion and do not modify application files.
7. Before high-assurance implementation, require the task readiness report, isolated cold-start report, and current `TASK_PACKAGE` approval. Adaptive short-path work uses the upstream task contract without manufacturing high-assurance sidecars.
8. Once artifacts and review evidence are current, implement only approved tasks. If scope, assumptions, risks, or affected components change, pause, mark dependent approval stale, and return to the appropriate artifact.
9. Do not report substantive work as complete until the selected route's validation and convergence have finished and all failures or unresolved items are disclosed.

The governance package does not replace the upstream Spec Kit executor. Its rules guide when the Agent must enter and remain in that workflow.

## Reference update handoff

A central Reference update automatically changes only the governance and Agent-context layer through an exact hash-bound plan. It does not directly change `.specify/**`, `specs/**`, specifications, plans, or tasks. After the governance layer is synchronized, inspect the current upstream artifacts and use the upstream Spec Kit workflow if they require alignment.

# Governance operations

For changes to this governance package itself, generate an operation plan before every mutation. Reference synchronization automatically authorizes and applies the exact generated plan; project-owner approval is not required because only Reference-owned files are in scope.

If a native-integration target is unwritable, permission is insufficient, a sandbox blocks the work, managed-file repair fails, or installation fails, stop and return `NATIVE_INSTALL_BLOCKED`; do not switch to generic or another key.

For an existing Spec Kit project without `docs/spec-kit/**`, use the separate `plan-install-update-reminder` plan with the exact existing context anchor when a project-local reminder is needed. The managed block is independent of the central Reference: it runs `specify self check` at most once per new session, asks before `specify self upgrade`, and automatically refreshes supported installed integration, extension, and workflow components without `--force`. It does not create a governance package or directly modify upstream-owned artifacts; those refreshes remain supported upstream CLI operations.

If the project already has the runtime-selected project context anchor, it is a project-owned rules file. The governance loader may only be appended or updated inside its managed region; all other bytes must remain byte-identical. A loader file may be created only at the exact anchor path supplied and evidence-validated in an approved plan.

Before `plan-init`, ask the user which BCP-47 language tag should govern new or substantially rewritten project documentation. Pass the explicit selection as `--documentation-language <tag>` so it is stored in project configuration and written into the selected context anchor. Do not infer or mass-translate.

The project governance package is a shared team baseline and does not depend on personal global rules or a central Reference directory. Its context anchor contains separately managed governance-loader and Reference-update-check blocks. The central Reference may be used only for explicit update review.
