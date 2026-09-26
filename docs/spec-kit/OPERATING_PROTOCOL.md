# Read-only preflight

Confirm the project root, read every governance file in this directory, and inspect the Git state, `.specify/`, manifest, configuration, adapter, CLI version, and integration status. Read-only commands must not create `.specify/`, a plan, a backup, or a binding.

If the target project already has the runtime-selected project context anchor, first treat it as project-owned user rules. Bootstrap or onboarding may inject or update the governance loader only through `append-managed-loader`; every byte outside the managed region and its byte order must be preserved. Overwriting, deleting, reordering, normalizing, or whole-file formatting is prohibited. A missing anchor may be created only at the exact path supplied and evidence-validated in an approved plan.

Before `plan-init`, the current Agent must ask the user for the BCP-47 language tag for new or substantially rewritten project documentation. Supply it as `--documentation-language <tag>`; the manager must reject a missing or invalid value. Persist the explicit selection in project configuration and the selected context-anchor loader. Do not infer a language or translate existing documents automatically.

# Governance package bootstrap

Extract the portable artifact to `.spec-kit-governance/staging/<plan-id>/`, validate the manifest and SHA-256, and generate `plan-governance-bootstrap` from the staging manager. Bootstrap writes only the committed governance package, manager, manifest, and configuration, plus the Loader at the exact runtime-selected context-anchor path. It does not install the current Agent integration. Apply only after the user authorizes the exact plan ID/hash, then verify with the project manager. This plan/apply protocol governs Reference-owned files; it does not replace the upstream Spec Kit feature workflow.

# Optional CLI update reminder

For an existing `.specify/` project that intentionally does not carry `docs/spec-kit/**`, `plan-install-update-reminder` may append the independent upstream update protocol to the exact existing context anchor. It requires the installed `specify` CLI, an existing anchor path supplied by the current Agent runtime or user, and an approved plan. It does not create the governance package, copy the manager, or directly edit `.specify/**`, `specs/**`, or native Agent integration files. The protocol runs `specify self check` at most once per new session, asks before `specify self upgrade`, and automatically refreshes supported installed integration, extension, and workflow components without `--force`. A modified-file conflict or any request for `--force` requires user review.

# Daily adaptive Feature workflow

For Feature work, classify intent and risk, then select the shortest suitable upstream route:

`assessment → decide`, `assess → fix → test`, `specify → plan → tasks → implement → converge`, or the full upstream sequence when risk requires it.

Before creating or updating artifacts for a high-risk Feature, ask one explicit task-scoped question: “Should this Feature use the `governed-sdd` high-assurance profile, or should it remain on the adaptive full upstream path?” A `governed-sdd` answer enables the companion only for the current Feature. An adaptive answer keeps the project on its existing default and uses the upstream full path with applicable risk-triggered gates.

The task-scoped answer must not modify `docs/spec-kit/PROJECT_CONFIG.json`, change `workflow_governance.mode`, or silently alter the project's future defaults. Both routes use upstream Spec Kit. A project-default change is a separate user request and reviewed configuration operation.

At each review gate, show the object type, artifact paths, hashes, concise changes, open risks, and permitted next stage. Record `REVIEW_REQUESTED`, `APPROVED`, `CHANGES_REQUESTED`, and `SUPERSEDED` as append-only events. Derive `STALE` whenever a live artifact hash differs from the approved hash or an upstream review object has been superseded. Never rewrite history to change a decision.

Approval phrases such as “the plan is acceptable” authorize only the review object explicitly named in the request. This approval does not authorize direct application-code edits or approve future objects. If the direction is already represented by current approved artifacts, continue from the corresponding handoff; otherwise revise and request review again.

If the user is only discussing alternatives, do not edit application files. If implementation changes the scope or assumptions, pause and update the upstream artifacts before continuing. The Reference package must not edit `.specify/**`, `specs/**`, or native Agent integration files.

## Pause, resume, and fail-closed rules

- `DRAFT` cannot become `APPROVED` without an intervening `REVIEW_REQUESTED` event.
- `CHANGES_REQUESTED` resumes at the producing stage after revision, not at implementation.
- A stale specification invalidates dependent plan and task approvals; a stale plan invalidates task approval.
- A readiness or cold-start failure returns the task package to revision.
- High-severity analyze findings require a `REMEDIATION` review before artifact or implementation changes continue.
- A non-interactive run pauses at every human gate. It must not synthesize approval.
- Missing optional companion capability, unsupported exact CLI version, or missing official extension does not block adaptive work. Ask before installing the missing CLI/extension; a refusal returns `HANDOFF_TO_AGENT`. Invalid ledger, unsafe path, or hash mismatch still blocks the operation that depends on it.

## Tiny-model task-package handoff

Generate each task as one observable result with all detail fields required by `task-readiness-report.schema.json`. Run only deterministic, read-only checks during audit. Sample at least the configured number of representative tasks for cold-start review, including the highest-risk migration, security, or failure-handling work when present. Any sample other than `EXECUTABLE` makes the package ineligible for approval.

Do not equate `EXECUTABLE` with model routing. If a task still demands advanced reasoning, cross-system authority, or human evidence, keep the self-contained package but route it to a capable executor or human owner.

# Completion semantics

`verify` from `tools/spec-kit-governance/governance.py` verifies only the Reference-owned governance package. It does not prove that a business feature is implemented. Feature completion requires the upstream Spec Kit artifacts to agree with the implementation and requires `analyze`, `validate`, and `converge` evidence.

# New projects

When `.specify/` does not exist, first obtain a clear approved key, rehearse with the same CLI/key in a temporary directory, and generate an external mutation scope. A non-empty brownfield may use `specify init --here --force --non-interactive --integration <key>` only through a dedicated `plan-init`; upstream `--force` may replace conflicting managed paths, so protect a reviewable baseline and inspect the resulting diff. An empty project uses the command without force. After the actual change, compare the scope inventory, status, and managed files; an escape or incomplete recovery returns `RECOVERY_REQUIRED`.

# Existing projects

Run `specify integration status --json`. A missing, modified, invalid, or blocking finding returns `STATE_BROKEN`; an unwritable native repair for the current runtime returns `NATIVE_INSTALL_BLOCKED`. Do not rerun init to create duplicate specifications.

# Native onboarding

Installation health for a candidate key yields only `NATIVE_CANDIDATE_INSTALLED_UNVERIFIED`. Write the user-provided anchor and supply `--anchor-evidence <project-relative-json>` in `plan-onboard`; then perform fresh-session Loader validation and confirm that the runtime ID and key match. Before validation, it must not be active, `READY`, or represented as complete.

Fresh-session evidence must be project-relative JSON that proves at least the runtime ID, integration key, fresh session, Loader loading, and managed-file verification. The binding may become `active` only after `plan-activate-binding` is applied with the exact approval hash.

Materialized delivery is allowed only when Loader fresh-session validation explicitly fails and the user actively chooses it; `plan-onboard` must also provide `--delivery-mode materialized --loader-failure-evidence <project-relative-json>`. Do not use Materialized as a fallback when native writes fail.

# Generic

`generic` must not enter the native branch. V1 permits it only when project configuration allows it, the current-version native-absence attestation is valid, the installed integration set is empty, Markdown Commands compatibility has been verified, and the user approves it. Return `INTEGRATION_CONFLICT` when the project already has any integration; V1 does not implement migration to generic.

# Native blocker

When the native init target, integration target, managed-file repair, anchor, or parent directory is unwritable; permission is denied; a sandbox blocks the work; or an installation partially fails: preserve and inventory the existing state, return `NATIVE_INSTALL_BLOCKED`, request a writable checkout or permission, and regenerate the plan with the same claimed key after remediation. Do not fall back to generic, switch to another key, or delete existing artifacts.

# Central Reference update check

The central check is session-gated and source-gated: it runs only when the current Agent has loaded the global Policy, the Policy exposes `SPEC_KIT_GOVERNANCE_SOURCE`, and the target carries the committed governance package. Missing Policy, missing source, unavailable source, dirty source, or failed verification is silent and non-blocking during normal project work; no arbitrary directory scan is allowed.

When the check reports `UPDATE_AVAILABLE`, run the exact hash-bound `auto-upgrade` operation immediately. Project-owner approval is not required because the operation is limited to Reference-owned files and managed context-anchor blocks. `REVIEW_REQUIRED` remains a divergent-baseline condition and requires human review before any synchronization.

# Upgrade and rollback

Read the clean central Reference checkout in read-only mode and compare its Git revision with the target manifest. First generate `plan-upgrade --source <central-or-staged-source>`, review Policy, Reference, manager, anchor, adapter, manifest, and capability inventory, then apply it. The inventory before and after the upgrade must be equivalent unless every change has an approved `REPLACE`. Rollback must not uninstall integrations or delete user work; incomplete failure recovery returns `RECOVERY_REQUIRED`. Reference synchronization must not modify `.specify/**`, `specs/**`, or native Agent-generated files.
