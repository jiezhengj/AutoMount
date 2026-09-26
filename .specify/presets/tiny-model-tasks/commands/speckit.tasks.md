---
description: "Generate upstream-compatible implementation tasks that a cold-start tiny model can execute"
strategy: wrap
---

# Tiny-model task requirements

{CORE_TEMPLATE}

After following the upstream task-generation instructions, strengthen every implementation task in the generated `tasks.md` with a structured detail block. Preserve the upstream checkbox line, task ID, optional `[P]`, story tag, phase, and exact path. Do not replace that line with a custom table or opaque prose.

Each task must have exactly one observable, independently verifiable outcome. A task that contains two independently verifiable outcomes, a hidden architecture or product decision, a producer plus multiple consumers, or two or more of design, implementation, migration, deletion, and release must be split before finalizing the task list.

Immediately below every implementation checkbox, use this exact ordered structure:

```markdown
  - **Objective**: <one observable result>
  - **Traceability**: <US/FR/AC/contract/defect IDs>
  - **Context summary**: <minimum business and technical context>
  - **Preconditions**: <completed task IDs, existing symbols, versions, state>
  - **Allowed files**: `<exact/project-relative/path>` <and exact symbol when applicable>
  - **Read-only references**: `<approved artifacts that may be read but not changed>`
  - **Forbidden changes**: <interfaces, modules, dependencies, or behavior not in scope>
  - **Inputs and outputs**: <precise API, data, state, file, or UI contract>
  - **Invariants and edge cases**: <required preservation and failure boundaries>
  - **Implementation steps**:
    1. <deterministic action with no hidden design choice>
    2. <deterministic action>
  - **Verification**: `<command or manual procedure>`
  - **Expected result**: <specific observable pass condition>
  - **Completion evidence**: <test output, diff, artifact, or record required at handoff>
  - **Stop conditions**: <conditions that require reporting rather than scope expansion>
  - **Handoff**: <specific artifact, symbol, or verified state the next task may rely on>
```

Use `N/A — <reason>` only when a field genuinely cannot apply. Never leave a field blank. `Allowed files` must name exact files, not only a directory; a new file must state its exact destination. `Verification` and `Expected result` must be independently meaningful and must not say only “works”, “tests pass”, or “as planned”.

Do not make tests optional by default. Include the smallest relevant automated or manual validation for every task unless the approved specification records a test exemption and its rationale. Mark tasks that require a human authority, secret, production access, advanced architectural judgment, or external coordination as non-tiny-model-routable in their stop conditions.

Before reporting completion, scan for repeated “and”, “also”, “including”, or “simultaneously” clauses that conceal multiple outcomes. Split them or explain in the task's context why they are inseparable parts of one verification result.
