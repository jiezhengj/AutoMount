# Tiny-model task contract

This preset composes around the upstream `speckit.tasks` command. It preserves upstream checkbox, task ID, story, phase, and exact-path conventions, while requiring a structured detail block under every implementation task.

The generated `tasks.md` remains upstream-owned. The preset affects future command generation through the supported CLI preset mechanism; it must never be used to manually rewrite an existing native `speckit-tasks` skill or historical task list.
