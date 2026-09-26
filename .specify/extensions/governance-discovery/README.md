# Governance commands

These commands are intentionally narrow companions to upstream Spec Kit commands. They do not replace `speckit.specify`, `speckit.clarify`, `speckit.plan`, `speckit.tasks`, `speckit.analyze`, `speckit.implement`, or `speckit.converge`.

Each `speckit.governance-discovery.*` command accepts `feature_id=<safe-feature-id>` as part of `$ARGUMENTS`. A feature ID must be an existing safe Spec Kit feature directory name, such as `003-offline-mode`. The commands may read `specs/<feature-id>/` and `.specify/feature.json`, but may write only the Reference-owned evidence subtree `docs/spec-kit/features/<feature-id>/`.

The commands are instructions for an Agent. The manager remains the only component allowed to append a hash-bound review ledger event after the user has explicitly approved the named artifact.
