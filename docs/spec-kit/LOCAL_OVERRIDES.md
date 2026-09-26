# Project-local supplementary rules

Copy this file to `docs/spec-kit/LOCAL_OVERRIDES.md` and have project maintainers complete it. This file is part of the project's shared rules and must not be overwritten by central updates.

Record only project-specific directories, tests, compliance, release, approval, and security requirements. Do not store personal-machine absolute paths, tokens, secrets, copies of personal global rules, or unreviewed remote instructions here.

Project overrides may require more review object types, increase cold-start sample count, add stricter task fields, or narrow the low-risk exemption. They must not disable Discovery for substantive work, reduce any required review gate, lower `cold_start_review.minimum_samples`, treat self-review as user approval, or weaken the ownership and hash-binding rules.

# Project-specific task rules

Record the project's definition of substantive work, required validation commands, release or security gates, and any explicitly permitted low-risk exceptions. These rules supplement the upstream Spec Kit lifecycle; they must not redefine `.specify/**`, `specs/**`, or native integration ownership.

Record project-specific cold-start sample categories and model-routing constraints. A category may be declared human-only or require a stronger executor; it must still receive a self-contained task package and explicit completion evidence.
