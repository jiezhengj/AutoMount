#!/usr/bin/env python3
"""Portable, Agent-neutral Spec Kit governance manager.

The manager deliberately keeps the first implementation small and explicit:
read-only discovery is available without a Spec Kit project, while every
filesystem or external CLI mutation is represented by a canonical plan and
must pass through ``apply-plan``.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import copy
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
GOVERNANCE_PACKAGE_VERSION = "2.0.0"
POLICY_VERSION = "2.0.0"
REFERENCE_VERSION = "2026.09.04"
MANAGER_VERSION = "2.0.0"
PLAN_TTL = timedelta(minutes=30)
RUNTIME_DIR = ".spec-kit-governance"
PROJECT_PACKAGE = "docs/spec-kit"
MANAGER_RELATIVE = "tools/spec-kit-governance/governance.py"
START_MARKER = "<!-- PROJECT-SPEC-KIT-GOVERNANCE:START -->"
END_MARKER = "<!-- PROJECT-SPEC-KIT-GOVERNANCE:END -->"
UPDATE_REMINDER_START_MARKER = "<!-- PROJECT-SPEC-KIT-UPDATE-REMINDER:START version=1 -->"
UPDATE_REMINDER_END_MARKER = "<!-- PROJECT-SPEC-KIT-UPDATE-REMINDER:END -->"
REFERENCE_UPDATE_START_MARKER = "<!-- PROJECT-SPEC-KIT-REFERENCE-UPDATE-CHECK:START version=1 -->"
REFERENCE_UPDATE_END_MARKER = "<!-- PROJECT-SPEC-KIT-REFERENCE-UPDATE-CHECK:END -->"
MANAGED_ANCHOR_ACTIONS = {
    "append-managed-loader",
    "append-managed-update-reminder",
    "append-managed-reference-update-check",
    "append-managed-bootstrap",
}
REFERENCE_UPDATE_SOURCE = Path("governance/project/REFERENCE_UPDATE_CHECK.md")
GOVERNANCE_LOADER_SOURCE = Path("governance/project/GOVERNANCE_LOADER.md")
SOURCE_METADATA_SOURCE = Path("governance/release/SOURCE_METADATA.json")
COMPANION_ROOT = Path("governance/spec-kit-native")
COMPANION_COMPONENTS = (
    ("extension", "governance-discovery", Path("extensions/discovery")),
    ("preset", "tiny-model-tasks", Path("presets/tiny-model-tasks")),
    ("workflow", "governed-sdd", Path("workflows/governed-sdd")),
)
CLI_VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:(\.dev|a|b|rc)(\d+))?$")
SAFE_RELATIVE = re.compile(r"^[^/\\].*$")
STATUSES = {
    "CLI_MISSING", "CLI_INCOMPATIBLE", "CLI_VERSION_UNTESTED", "CLI_VERSION_UNPARSEABLE",
    "CLI_CONTRACT_UNVERIFIED", "CAPABILITY_MISSING", "USER_DECLINED_CAPABILITY_INSTALL", "HANDOFF_TO_AGENT",
    "IDENTITY_UNKNOWN", "IDENTITY_CONFLICT", "KEY_REQUIRED", "PROJECT_NOT_INITIALIZED",
    "EXACT_NATIVE_INSTALLED", "NATIVE_CANDIDATE_NOT_INSTALLED", "NATIVE_CANDIDATE_INSTALLED_UNVERIFIED",
    "NATIVE_CANDIDATE_REJECTED", "NATIVE_INSTALL_BLOCKED", "AMBIGUOUS", "CATALOG_UNAVAILABLE",
    "CONTEXT_ANCHOR_UNKNOWN", "ANCHOR_FORMAT_UNSUPPORTED", "UNSUPPORTED_GENERIC_COMPATIBLE",
    "UNSUPPORTED_INCOMPATIBLE", "INTEGRATION_CONFLICT", "DEFAULT_CHANGE_FORBIDDEN",
    "CENTRAL_SOURCE_UNVERIFIED", "TARGET_NOT_BOOTSTRAPPED", "TARGET_BASELINE_UNKNOWN", "UP_TO_DATE", "UPDATE_AVAILABLE", "REVIEW_REQUIRED",
    "PROJECT_RULES_PROTECTED", "REFERENCE_OWNERSHIP_VIOLATION", "STATE_BROKEN", "RECOVERY_REQUIRED", "READY_WITH_LIMITATIONS", "READY",
    "MIGRATION_REQUIRED", "COMPANION_CAPABILITY_UNAVAILABLE", "COMPANION_NOT_INSTALLED",
    "REVIEW_REQUIRED", "CHANGES_REQUESTED", "APPROVED", "STALE", "TASK_PACKAGE_INVALID",
}

ARTIFACT_TYPES = {"DISCOVERY", "SPECIFICATION", "PLAN_BUNDLE", "TASK_PACKAGE", "REMEDIATION"}
REVIEW_DECISIONS = {"REVIEW_REQUESTED", "CHANGES_REQUESTED", "APPROVED", "SUPERSEDED"}
TASK_REQUIRED_FIELDS = {
    "id", "objective", "traceability", "context_summary", "preconditions", "allowed_files",
    "read_only_references", "forbidden_changes", "inputs_outputs", "invariants_and_edge_cases",
    "implementation_steps", "verification", "completion_evidence", "stop_conditions", "handoff",
}
REVIEW_LEDGER_RELATIVE = "docs/spec-kit/features/{feature_id}/REVIEW_LEDGER.json"
AGENT_REVIEWER_RE = re.compile(r"(?:^|[-_ ])(?:agent|assistant|codex|claude|antigravity|gemini|pi)(?:$|[-_ ])", re.IGNORECASE)


class GovernanceError(RuntimeError):
    def __init__(self, message: str, status: str | None = None) -> None:
        super().__init__(message)
        self.status = status


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def plan_hash(plan: dict[str, Any]) -> str:
    payload = dict(plan)
    payload.pop("plan_sha256", None)
    return sha256_bytes(canonical_json(payload))


def validate_plan_shape(plan: dict[str, Any]) -> None:
    required = {"schema_version", "plan_id", "operation_type", "created_at", "expires_at", "project_root_fingerprint", "git_status_porcelain_sha256", "manager_file_mutations", "external_cli_mutations", "capability_inventory_before", "plan_sha256"}
    missing = sorted(required - set(plan))
    if missing:
        raise GovernanceError(f"plan missing required fields: {', '.join(missing)}", "STATE_BROKEN")
    if plan.get("schema_version") != SCHEMA_VERSION or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(plan.get("plan_id"))):
        raise GovernanceError("unsupported or malformed plan identity", "STATE_BROKEN")
    if plan.get("operation_type") == "plan-init" and plan.get("claimed_integration_key") == "generic":
        raise GovernanceError("plan-init cannot use generic integration", "UNSUPPORTED_INCOMPATIBLE")
    if plan.get("operation_type") == "plan-init" and not isinstance(plan.get("rehearsal"), dict):
        raise GovernanceError("plan-init requires isolated init rehearsal evidence", "STATE_BROKEN")
    if plan.get("operation_type") == "plan-init" and not valid_language_tag(plan.get("documentation_language")):
        raise GovernanceError("plan-init requires an explicit documentation language", "DOCUMENTATION_LANGUAGE_REQUIRED")
    if plan.get("operation_type") == "plan-init" and not plan.get("current_agent", {}).get("runtime_id"):
        raise GovernanceError("plan-init requires an explicit runtime identity", "IDENTITY_UNKNOWN")
    if plan.get("operation_type") == "plan-init" and not plan.get("context_anchor"):
        raise GovernanceError("plan-init requires an explicit project context anchor", "CONTEXT_ANCHOR_UNKNOWN")
    if plan.get("operation_type") in {"plan-governance-bootstrap", "plan-onboard"} and not plan.get("context_anchor"):
        raise GovernanceError("an explicit project context anchor is required", "CONTEXT_ANCHOR_UNKNOWN")
    if plan.get("operation_type") == "plan-onboard" and plan.get("context_anchor") and not plan.get("anchor_compatibility_evidence"):
        raise GovernanceError("onboarding requires anchor compatibility evidence", "CONTEXT_ANCHOR_UNKNOWN")
    context_anchor = plan.get("context_anchor")
    if plan.get("operation_type") == "plan-record-artifact-review":
        mutations = plan.get("manager_file_mutations", [])
        if len(mutations) != 1 or plan.get("external_cli_mutations"):
            raise GovernanceError("artifact review plan must append exactly one project-local ledger event", "REFERENCE_OWNERSHIP_VIOLATION")
        if not re.fullmatch(r"docs/spec-kit/features/[A-Za-z0-9][A-Za-z0-9._-]*/REVIEW_LEDGER\.json", str(mutations[0].get("path"))):
            raise GovernanceError("artifact review plan targets a non-ledger path", "REFERENCE_OWNERSHIP_VIOLATION")
    if plan.get("operation_type") in {"plan-upgrade-governance-v2", "plan-install-governed-companion", "plan-remove-governed-companion"}:
        snapshot = plan.get("source_snapshot")
        if not isinstance(snapshot, dict) or not re.fullmatch(r"[0-9a-f]{40}", str(snapshot.get("source_revision"))) or not re.fullmatch(r"[0-9a-f]{64}", str(snapshot.get("tree_sha256"))):
            raise GovernanceError("strict operation plan has no valid source snapshot", "CENTRAL_SOURCE_UNVERIFIED")
    for item in plan.get("manager_file_mutations", []):
        if not isinstance(item.get("path"), str) or not reference_owned_mutation(item["path"], context_anchor):
            raise GovernanceError(
                "manager mutations may target only Reference-owned additions or the managed context-anchor loader",
                "REFERENCE_OWNERSHIP_VIOLATION",
            )
        if item.get("path") == "" or item.get("old_sha256") is not None and not re.fullmatch(r"[0-9a-f]{64}", item["old_sha256"]):
            raise GovernanceError("malformed manager mutation", "STATE_BROKEN")
        if item.get("expected_new_sha256") and not re.fullmatch(r"[0-9a-f]{64}", item["expected_new_sha256"]):
            raise GovernanceError("malformed manager mutation checksum", "STATE_BROKEN")
        try:
            decoded = base64.b64decode(item.get("content_b64", ""), validate=True)
        except (binascii.Error, ValueError, TypeError) as exc:
            raise GovernanceError("manager mutation content is not valid base64", "STATE_BROKEN") from exc
        if item.get("action") not in MANAGED_ANCHOR_ACTIONS and sha256_bytes(decoded) != item.get("expected_new_sha256"):
            raise GovernanceError("manager mutation content does not match its target checksum", "STATE_BROKEN")
        if item.get("protected_anchor") is True and item.get("path") != context_anchor:
            raise GovernanceError("protected anchor mutation does not match the declared context anchor", "STATE_BROKEN")
        if item.get("path") == context_anchor and (item.get("action") not in MANAGED_ANCHOR_ACTIONS or item.get("protected_anchor") is not True):
            raise GovernanceError("the declared project rules anchor accepts only approved managed-block appends", "PROJECT_RULES_PROTECTED")
    for item in plan.get("external_cli_mutations", []):
        argv = item.get("argv", [])
        if not argv or argv[0] != "specify":
            raise GovernanceError("external mutation executable is not allowlisted", "UNSUPPORTED_INCOMPATIBLE")
        if "--force" in argv and plan.get("operation_type") not in {"plan-init", "plan-remove-governed-companion"}:
            raise GovernanceError("--force is forbidden for this operation", "UNSUPPORTED_INCOMPATIBLE")


def project_root_from(path: Path | None = None) -> Path:
    candidate = (path or Path.cwd()).resolve()
    for item in (candidate, *candidate.parents):
        if (item / ".git").exists():
            return item
    return candidate


def safe_relative(root: Path, value: str) -> Path:
    if not value or "\x00" in value or Path(value).is_absolute() or not SAFE_RELATIVE.match(value):
        raise GovernanceError(f"unsafe project-relative path: {value!r}")
    rel = Path(value)
    if ".." in rel.parts:
        raise GovernanceError(f"path traversal is forbidden: {value!r}")
    target = (root / rel).resolve(strict=False)
    try:
        target.relative_to(root.resolve())
    except ValueError as exc:
        raise GovernanceError(f"path escapes project root: {value!r}") from exc
    return rel


def reference_owned_mutation(path: str, context_anchor: str | None) -> bool:
    """Return whether a manager mutation stays inside the Reference boundary."""
    normalized = Path(path).as_posix()
    if context_anchor and normalized == context_anchor:
        if normalized == ".specify" or normalized.startswith(".specify/") or normalized == "specs" or normalized.startswith("specs/"):
            return False
        return True
    return (
        normalized == MANAGER_RELATIVE
        or normalized == PROJECT_PACKAGE
        or normalized.startswith(PROJECT_PACKAGE + "/")
        or normalized == RUNTIME_DIR
        or normalized.startswith(RUNTIME_DIR + "/")
    )


def relative_existing(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise GovernanceError(f"invalid JSON: {path}: {exc}", "STATE_BROKEN") from exc
    if not isinstance(value, dict):
        raise GovernanceError(f"JSON object required: {path}", "STATE_BROKEN")
    return value


def git_value(root: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=root, text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    return result.stdout.strip() if result.returncode == 0 else ""


def git_succeeds(root: Path, *args: str) -> bool:
    result = subprocess.run(["git", *args], cwd=root, text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    return result.returncode == 0


def git_fingerprint(root: Path) -> dict[str, str]:
    raw_status = git_value(root, "status", "--porcelain=v1", "--untracked-files=all")
    # The manager's own plan, backup, and journal files are ephemeral runtime
    # state.  They must not invalidate the exact plan between plan creation and
    # apply; all durable project mutations remain covered by the file hashes in
    # the plan itself.
    status_lines = []
    for line in raw_status.splitlines():
        path_text = line[3:] if len(line) >= 3 else ""
        if path_text == RUNTIME_DIR or path_text.startswith(RUNTIME_DIR + "/"):
            continue
        status_lines.append(line)
    status = "\n".join(status_lines)
    head = git_value(root, "rev-parse", "HEAD") or "UNBORN"
    return {
        "git_head": head,
        "git_status_porcelain_sha256": sha256_bytes(status.encode("utf-8")),
        "project_root_fingerprint": sha256_bytes(str(root).encode("utf-8")),
    }


def cli_version() -> str | None:
    executable = shutil.which("specify")
    if not executable:
        return None
    result = subprocess.run([executable, "version"], text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    output = (result.stdout or result.stderr)
    # Current Specify renders a rich information panel rather than a plain
    # version line.  Accept the machine-readable --version form first, then
    # extract the labelled CLI Version field from the panel.
    simple = subprocess.run([executable, "--version"], text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    simple_text = (simple.stdout or simple.stderr).strip()
    match = re.search(r"\b(\d+\.\d+\.\d+(?:(?:\.dev|a|b|rc)\d+)?)\b", simple_text)
    if match:
        return match.group(1)
    match = re.search(r"CLI Version\s+([^\s│]+)", output)
    return match.group(1).strip() if result.returncode == 0 and match else None


def parse_cli_version(value: str) -> tuple[int, int, int, int, int]:
    match = CLI_VERSION_RE.fullmatch(value.strip())
    if not match:
        raise GovernanceError(f"unparseable specify version: {value}", "CLI_VERSION_UNPARSEABLE")
    major, minor, patch, stage, number = match.groups()
    ranks = {".dev": 0, "a": 1, "b": 2, "rc": 3, None: 4}
    return int(major), int(minor), int(patch), ranks[stage], int(number or 0)


def command_status(root: Path) -> dict[str, Any] | None:
    executable = shutil.which("specify")
    if not executable or not (root / ".specify").is_dir():
        return None
    result = subprocess.run([executable, "integration", "status", "--json"], cwd=root, text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise GovernanceError(result.stderr.strip() or "integration status failed", "STATE_BROKEN")
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise GovernanceError("integration status did not return JSON", "STATE_BROKEN") from exc
    if not isinstance(data, dict):
        raise GovernanceError("integration status JSON must be an object", "STATE_BROKEN")
    return data


def project_config(root: Path) -> dict[str, Any] | None:
    path = root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"
    return read_json(path) if path.is_file() else None


def adapters(root: Path) -> dict[str, Any]:
    path = root / PROJECT_PACKAGE / "ADAPTERS.json"
    return read_json(path) if path.is_file() else {"schema_version": 1, "anchors": [], "bindings": []}


def validate_project_package(root: Path) -> list[str]:
    errors: list[str] = []
    config_path = root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"
    adapter_path = root / PROJECT_PACKAGE / "ADAPTERS.json"
    manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
    if config_path.is_file():
        config = read_json(config_path)
        required = {"schema_version", "default_integration", "onboarding", "generic", "catalogs", "context", "documentation", "upgrade", "quality_gates"}
        errors.extend(f"PROJECT_CONFIG missing {name}" for name in sorted(required - set(config)))
        config_schema = config.get("schema_version")
        if config_schema not in {1, 2}:
            errors.append("PROJECT_CONFIG schema_version must be 1 or 2")
        if config.get("default_integration", {}).get("policy") != "pinned":
            errors.append("default integration policy must be pinned")
        if config.get("onboarding", {}).get("allow_unsafe_multi_install") is not False:
            errors.append("unsafe multi-install must remain disabled")
        language_tag = config.get("documentation", {}).get("language_tag")
        if language_tag is not None and not valid_language_tag(language_tag):
            errors.append("documentation language_tag must be null or a valid BCP 47 tag")
        if (root / ".specify").is_dir() and language_tag is None:
            errors.append("initialized Spec Kit projects require an explicit documentation language")
        if config_schema == 2:
            workflow = config.get("workflow_governance")
            if not isinstance(workflow, dict):
                errors.append("PROJECT_CONFIG v2 requires workflow_governance")
            else:
                if workflow.get("mode") not in {"upstream-adaptive", "governed-sdd"}:
                    errors.append("PROJECT_CONFIG v2 requires upstream-adaptive or governed-sdd mode")
                if workflow.get("discovery") not in {"risk-based", "required-for-high-risk", "required-for-substantive"}:
                    errors.append("workflow_governance discovery mode is invalid")
                if workflow.get("mode") == "governed-sdd":
                    expected_reviews = ARTIFACT_TYPES
                    configured_reviews = workflow.get("artifact_reviews")
                    if not isinstance(configured_reviews, list) or set(configured_reviews) != expected_reviews:
                        errors.append("governed-sdd artifact_reviews must contain every governed artifact type")
                    if workflow.get("approval_evidence") != "committed-project-local":
                        errors.append("governed-sdd approval_evidence must be committed-project-local")
                    if workflow.get("tiny_model_tasks") != "required":
                        errors.append("governed-sdd tiny_model_tasks must be required")
                    cold_start = workflow.get("cold_start_review")
                    if not isinstance(cold_start, dict) or cold_start.get("required") is not True or not isinstance(cold_start.get("minimum_samples"), int) or cold_start.get("minimum_samples") < 1:
                        errors.append("governed-sdd requires at least one cold-start sample")
            for gate in ("clarify", "checklist", "analyze", "validate", "converge"):
                if config.get("quality_gates", {}).get(gate) not in {"required", "risk-triggered", "recommended", "off"}:
                    errors.append(f"PROJECT_CONFIG v2 quality gate {gate} has an invalid policy")
    if adapter_path.is_file():
        registry = read_json(adapter_path)
        if registry.get("schema_version") != 1 or not isinstance(registry.get("anchors"), list) or not isinstance(registry.get("bindings"), list):
            errors.append("ADAPTERS schema is invalid")
        for binding in registry.get("bindings", []):
            if binding.get("integration_mode") == "native" and binding.get("verification", {}).get("status") == "active":
                if binding.get("verification", {}).get("method") not in {"fresh-session-loader", "fresh-session-materialized"}:
                    errors.append("active native binding must be fresh-session verified")
    if manifest_path.is_file():
        manifest = read_json(manifest_path)
        required = {"schema_version", "governance_package_version", "policy_version", "reference_version", "source", "specify_compatibility", "paths", "content_sha256", "project_owned_files"}
        errors.extend(f"MANIFEST missing {name}" for name in sorted(required - set(manifest)))
        if manifest.get("schema_version") not in {1, 2}:
            errors.append("MANIFEST schema_version must be 1 or 2")
        if manifest.get("schema_version") == 2:
            if manifest.get("project_owned_prefixes") != [f"{PROJECT_PACKAGE}/features/"]:
                errors.append("MANIFEST v2 must preserve the feature evidence prefix")
            companion = manifest.get("companion")
            expected_companion = {
                "version": "2.0.0", "extension": "governance-discovery", "preset": "tiny-model-tasks",
                "workflow": "governed-sdd", "installation_mode": "independent-native-components",
            }
            if companion != expected_companion:
                errors.append("MANIFEST v2 companion metadata is invalid")
    return errors


def governance_generation(root: Path) -> int | None:
    """Return the committed config generation without treating v1 as corrupt."""
    config = project_config(root)
    if config is None:
        return None
    value = config.get("schema_version")
    return value if value in {1, 2} else None


def require_governance_v2(root: Path) -> dict[str, Any]:
    config = project_config(root)
    if config is None:
        raise GovernanceError("project governance configuration is missing", "PROJECT_NOT_INITIALIZED")
    if config.get("schema_version") != 2:
        raise GovernanceError(
            "strict feature governance requires an approved v1-to-v2 migration plan",
            "MIGRATION_REQUIRED",
        )
    errors = validate_project_package(root)
    if errors:
        raise GovernanceError("project governance v2 configuration is invalid: " + "; ".join(errors), "STATE_BROKEN")
    return config


def feature_locations(root: Path, feature_dir: str) -> dict[str, Any]:
    """Resolve a feature without guessing outside the two governed roots."""
    rel = safe_relative(root, feature_dir).as_posix().rstrip("/")
    parts = Path(rel).parts
    if len(parts) == 2 and parts[0] == "specs":
        feature_id = parts[1]
        spec_rel = rel
        sidecar_rel = REVIEW_LEDGER_RELATIVE.format(feature_id=feature_id).rsplit("/", 1)[0]
    elif len(parts) == 4 and parts[:3] == ("docs", "spec-kit", "features"):
        feature_id = parts[3]
        sidecar_rel = rel
        spec_rel = f"specs/{feature_id}"
    else:
        raise GovernanceError(
            "feature directory must be specs/<feature-id> or docs/spec-kit/features/<feature-id>",
            "STATE_BROKEN",
        )
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", feature_id):
        raise GovernanceError("feature ID contains unsupported characters", "STATE_BROKEN")
    return {
        "feature_id": feature_id,
        "spec_rel": spec_rel,
        "spec_path": root / spec_rel,
        "sidecar_rel": sidecar_rel,
        "sidecar_path": root / sidecar_rel,
        "ledger_rel": f"{sidecar_rel}/REVIEW_LEDGER.json",
        "ledger_path": root / sidecar_rel / "REVIEW_LEDGER.json",
    }


def validate_review_ledger_object(ledger: dict[str, Any], feature_id: str) -> dict[str, Any]:
    if ledger.get("schema_version") != 1 or ledger.get("feature_id") != feature_id or not isinstance(ledger.get("events"), list):
        raise GovernanceError("feature review ledger header is invalid", "STATE_BROKEN")
    seen: set[str] = set()
    previous_states: dict[str, str] = {}
    for event in ledger["events"]:
        if not isinstance(event, dict):
            raise GovernanceError("feature review ledger contains a non-object event", "STATE_BROKEN")
        required = {
            "event_id", "artifact_type", "decision", "artifact_paths",
            "content_sha256", "review_summary", "open_risks", "recorded_by", "recorded_at", "evidence",
            "supersedes_event_id",
        }
        if required - set(event):
            raise GovernanceError("feature review ledger event is missing required fields", "STATE_BROKEN")
        event_id = event.get("event_id")
        artifact_type = event.get("artifact_type")
        decision = event.get("decision")
        if not isinstance(event_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", event_id) or event_id in seen:
            raise GovernanceError("feature review ledger event_id is invalid or duplicated", "STATE_BROKEN")
        if artifact_type not in ARTIFACT_TYPES or decision not in REVIEW_DECISIONS:
            raise GovernanceError("feature review ledger event enum is invalid", "STATE_BROKEN")
        paths = event.get("artifact_paths")
        hashes = event.get("content_sha256")
        if not isinstance(paths, list) or not paths or len(paths) != len(set(paths)) or not isinstance(hashes, dict) or set(paths) != set(hashes):
            raise GovernanceError("feature review ledger artifact paths and hashes do not match", "STATE_BROKEN")
        for rel in paths:
            if not isinstance(rel, str):
                raise GovernanceError("feature review ledger artifact path is invalid", "STATE_BROKEN")
            if not re.fullmatch(r"[0-9a-f]{64}", str(hashes.get(rel))):
                raise GovernanceError("feature review ledger artifact hash is invalid", "STATE_BROKEN")
        if not isinstance(event.get("recorded_by"), str) or not event["recorded_by"].strip() or not isinstance(event.get("recorded_at"), str):
            raise GovernanceError("feature review ledger recorder is invalid", "STATE_BROKEN")
        try:
            datetime.fromisoformat(event["recorded_at"].replace("Z", "+00:00"))
        except ValueError as exc:
            raise GovernanceError("feature review ledger recorded_at is invalid", "STATE_BROKEN") from exc
        if decision == "APPROVED":
            if not isinstance(event.get("approved_by"), str) or not event["approved_by"].strip() or not isinstance(event.get("approved_at"), str):
                raise GovernanceError("APPROVED review event requires approver identity and time", "STATE_BROKEN")
            try:
                datetime.fromisoformat(event["approved_at"].replace("Z", "+00:00"))
            except ValueError as exc:
                raise GovernanceError("feature review ledger approved_at is invalid", "STATE_BROKEN") from exc
        supersedes = event.get("supersedes_event_id")
        if supersedes is not None and supersedes not in seen:
            raise GovernanceError("review event supersedes an unknown or later event", "STATE_BROKEN")
        previous = previous_states.get(artifact_type, "DRAFT")
        allowed = {
            "DRAFT": {"REVIEW_REQUESTED"},
            "REVIEW_REQUESTED": {"APPROVED", "CHANGES_REQUESTED"},
            "CHANGES_REQUESTED": {"REVIEW_REQUESTED"},
            "APPROVED": {"SUPERSEDED", "REVIEW_REQUESTED"},
            "SUPERSEDED": {"REVIEW_REQUESTED"},
        }
        if decision not in allowed.get(previous, set()):
            raise GovernanceError(f"invalid review transition for {artifact_type}: {previous} -> {decision}", "STATE_BROKEN")
        previous_states[artifact_type] = decision
        seen.add(event_id)
    return ledger


def read_review_ledger(path: Path, feature_id: str, *, missing_ok: bool = True) -> dict[str, Any]:
    if not path.is_file():
        if missing_ok:
            return {"schema_version": 1, "feature_id": feature_id, "events": []}
        raise GovernanceError("feature review ledger is missing", "REVIEW_REQUIRED")
    return validate_review_ledger_object(read_json(path), feature_id)


def event_artifact_paths(root: Path, locations: dict[str, Any], artifact_type: str, explicit: list[str] | None = None) -> list[str]:
    if artifact_type not in ARTIFACT_TYPES:
        raise GovernanceError("unknown artifact type", "STATE_BROKEN")
    spec_rel = locations["spec_rel"]
    sidecar_rel = locations["sidecar_rel"]
    allowed_roots = (spec_rel + "/", sidecar_rel + "/")
    if explicit:
        paths = [safe_relative(root, value).as_posix() for value in explicit]
    elif artifact_type == "DISCOVERY":
        paths = [f"{sidecar_rel}/DISCOVERY.md"]
    elif artifact_type == "SPECIFICATION":
        paths = [f"{spec_rel}/spec.md"]
    elif artifact_type == "PLAN_BUNDLE":
        candidates = ["plan.md", "research.md", "data-model.md", "quickstart.md"]
        paths = [f"{spec_rel}/{name}" for name in candidates if (root / spec_rel / name).is_file()]
        contracts = root / spec_rel / "contracts"
        if contracts.is_dir():
            paths.extend(
                item.relative_to(root).as_posix()
                for item in sorted(contracts.rglob("*"))
                if item.is_file() and not item.is_symlink()
            )
    elif artifact_type == "TASK_PACKAGE":
        candidates = [
            f"{spec_rel}/tasks.md",
            f"{sidecar_rel}/TASK_READINESS.json",
            f"{sidecar_rel}/COLD_START_VALIDATION.json",
        ]
        paths = [value for value in candidates if (root / value).is_file()]
    else:
        candidates = [f"{sidecar_rel}/REMEDIATION.md", f"{sidecar_rel}/REMEDIATION.json"]
        paths = [value for value in candidates if (root / value).is_file()]
    if not paths:
        raise GovernanceError(f"no artifact files found for {artifact_type}", "REVIEW_REQUIRED")
    normalized: list[str] = []
    for rel in paths:
        rel = safe_relative(root, rel).as_posix()
        if not any(rel.startswith(prefix) for prefix in allowed_roots):
            raise GovernanceError("review evidence may bind only this feature's Spec Kit artifacts or sidecar", "REFERENCE_OWNERSHIP_VIOLATION")
        target = root / rel
        if not target.is_file() or target.is_symlink():
            raise GovernanceError(f"review artifact is missing or not a regular file: {rel}", "REVIEW_REQUIRED")
        normalized.append(rel)
    required_core = {
        "DISCOVERY": f"{sidecar_rel}/DISCOVERY.md",
        "SPECIFICATION": f"{spec_rel}/spec.md",
        "PLAN_BUNDLE": f"{spec_rel}/plan.md",
        "TASK_PACKAGE": f"{spec_rel}/tasks.md",
    }.get(artifact_type)
    if required_core and required_core not in normalized:
        raise GovernanceError(f"{artifact_type} review is missing its core artifact: {required_core}", "REVIEW_REQUIRED")
    return sorted(set(normalized))


def current_artifact_approval(root: Path, locations: dict[str, Any], artifact_type: str) -> dict[str, Any]:
    ledger = read_review_ledger(locations["ledger_path"], locations["feature_id"])
    matching = [event for event in ledger["events"] if event["artifact_type"] == artifact_type]
    if not matching:
        return {"artifact_type": artifact_type, "status": "REVIEW_REQUIRED", "reason": "no review event"}
    event = matching[-1]
    decision = event["decision"]
    stale_paths: list[str] = []
    for rel, expected in event["content_sha256"].items():
        safe_relative(root, rel)
        target = root / rel
        if not target.is_file() or target.is_symlink() or sha256_file(target) != expected:
            stale_paths.append(rel)
    if stale_paths:
        status = "STALE"
    elif decision == "APPROVED":
        status = "APPROVED"
    elif decision == "CHANGES_REQUESTED":
        status = "CHANGES_REQUESTED"
    else:
        status = "REVIEW_REQUIRED"
    return {
        "artifact_type": artifact_type,
        "status": status,
        "event_id": event["event_id"],
        "decision": decision,
        "artifact_paths": event["artifact_paths"],
        "stale_paths": stale_paths,
    }


def nonempty_contract_value(value: Any) -> bool:
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (list, dict)):
        return bool(value)
    return value is not None


def verify_task_package(root: Path, locations: dict[str, Any]) -> dict[str, Any]:
    tasks_path = locations["spec_path"] / "tasks.md"
    report_path = locations["sidecar_path"] / "TASK_READINESS.json"
    errors: list[str] = []
    if not tasks_path.is_file():
        errors.append(f"missing {locations['spec_rel']}/tasks.md")
    if not report_path.is_file():
        errors.append(f"missing {locations['sidecar_rel']}/TASK_READINESS.json")
        return {"status": "TASK_PACKAGE_INVALID", "errors": errors, "tasks": []}
    report = read_json(report_path)
    tasks = report.get("tasks")
    if (
        report.get("schema_version") != 1
        or report.get("feature_id") != locations["feature_id"]
        or report.get("result") != "READY"
        or not isinstance(report.get("generated_at"), str)
        or not isinstance(tasks, list)
        or not tasks
    ):
        errors.append("TASK_READINESS.json header or tasks collection is invalid")
        tasks = []
    report_paths = report.get("artifact_paths")
    report_hashes = report.get("content_sha256")
    if not isinstance(report_paths, list) or not isinstance(report_hashes, dict) or set(report_paths) != set(report_hashes):
        errors.append("TASK_READINESS.json artifact paths and hashes do not match")
    else:
        for rel in report_paths:
            try:
                safe_relative(root, rel)
            except GovernanceError as exc:
                errors.append(f"TASK_READINESS.json artifact path: {exc}")
                continue
            target = root / rel
            if not target.is_file() or target.is_symlink() or sha256_file(target) != report_hashes.get(rel):
                errors.append(f"TASK_READINESS.json artifact hash is stale: {rel}")
    markdown_ids: set[str] = set()
    if tasks_path.is_file():
        markdown_ids = set(re.findall(r"(?m)^\s*-\s*\[\s\]\s+(T\d+)\b", tasks_path.read_text(encoding="utf-8")))
    seen: set[str] = set()
    dependency_graph: dict[str, set[str]] = {}
    for index, task in enumerate(tasks):
        label = f"task[{index}]"
        if not isinstance(task, dict):
            errors.append(f"{label} is not an object")
            continue
        missing = sorted(field for field in TASK_REQUIRED_FIELDS if field not in task)
        if missing:
            errors.append(f"{label} missing fields: {', '.join(missing)}")
        for field in TASK_REQUIRED_FIELDS - {"read_only_references", "preconditions"}:
            if field in task and not nonempty_contract_value(task.get(field)):
                errors.append(f"{label} has empty field: {field}")
        task_id = task.get("id")
        if not isinstance(task_id, str) or not re.fullmatch(r"T\d+", task_id):
            errors.append(f"{label} has invalid id")
            continue
        if task_id in seen:
            errors.append(f"duplicate task id: {task_id}")
        seen.add(task_id)
        if task_id not in markdown_ids:
            errors.append(f"{task_id} is absent from tasks.md checkbox entries")
        for field in ("allowed_files", "read_only_references"):
            values = task.get(field)
            if not isinstance(values, list) or (field == "allowed_files" and not values):
                errors.append(f"{task_id} {field} must be a list" + (" with at least one path" if field == "allowed_files" else ""))
                continue
            for value in values:
                if not isinstance(value, str):
                    errors.append(f"{task_id} {field} contains a non-string path")
                    continue
                try:
                    safe_relative(root, value)
                except GovernanceError as exc:
                    errors.append(f"{task_id} {field}: {exc}")
        verification = task.get("verification")
        if not isinstance(verification, list) or not verification:
            errors.append(f"{task_id} verification must contain at least one check")
        else:
            for check in verification:
                if not isinstance(check, dict) or check.get("kind") not in {"command", "manual"} or not isinstance(check.get("expected_result"), str) or not check["expected_result"].strip():
                    errors.append(f"{task_id} has an invalid verification check")
                elif check.get("kind") == "command" and (not isinstance(check.get("command"), str) or not check["command"].strip()):
                    errors.append(f"{task_id} command verification is missing its command")
        dependencies = task.get("depends_on", [])
        if isinstance(task.get("preconditions"), dict):
            dependencies = task["preconditions"].get("dependency_task_ids", dependencies)
        if not isinstance(dependencies, list):
            errors.append(f"{task_id} dependencies must be a list")
            dependencies = []
        dependency_graph[task_id] = {value for value in dependencies if isinstance(value, str) and re.fullmatch(r"T\d+", value)}
    for task_id, dependencies in dependency_graph.items():
        unknown = sorted(dependencies - seen)
        if unknown:
            errors.append(f"{task_id} depends on unknown tasks: {', '.join(unknown)}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(task_id: str) -> None:
        if task_id in visiting:
            errors.append(f"dependency cycle includes {task_id}")
            return
        if task_id in visited:
            return
        visiting.add(task_id)
        for dependency in dependency_graph.get(task_id, set()):
            visit(dependency)
        visiting.remove(task_id)
        visited.add(task_id)

    for task_id in sorted(seen):
        visit(task_id)
    return {
        "status": "READY" if not errors else "TASK_PACKAGE_INVALID",
        "feature_id": locations["feature_id"],
        "task_count": len(tasks),
        "task_ids": sorted(seen),
        "errors": errors,
    }


def verify_cold_start(root: Path, locations: dict[str, Any], task_result: dict[str, Any], config: dict[str, Any]) -> dict[str, Any]:
    path = locations["sidecar_path"] / "COLD_START_VALIDATION.json"
    if not path.is_file():
        return {"status": "CHANGES_REQUESTED", "errors": ["cold-start validation is missing"]}
    report = read_json(path)
    samples = report.get("reviews", report.get("samples"))
    errors: list[str] = []
    if (
        report.get("schema_version") != 1
        or report.get("feature_id") != locations["feature_id"]
        or report.get("result") != "EXECUTABLE"
        or not isinstance(report.get("generated_at"), str)
        or not isinstance(samples, list)
    ):
        errors.append("cold-start validation header or reviews collection is invalid")
        samples = []
    isolation = report.get("isolation")
    if not isinstance(isolation, dict) or isolation.get("originating_conversation_provided") is not False or isolation.get("repository_access") != "read-only" or isolation.get("supplied_context") != "declared-task-and-references-only":
        errors.append("cold-start validation did not use the required isolation model")
    readiness_path = locations["sidecar_path"] / "TASK_READINESS.json"
    if readiness_path.is_file() and report.get("task_package_sha256") != sha256_file(readiness_path):
        errors.append("cold-start validation targets a stale task package")
    configured_minimum = config.get("workflow_governance", {}).get("cold_start_review", {}).get("minimum_samples", 3)
    required_samples = min(configured_minimum, max(task_result.get("task_count", 0), 1))
    if report.get("minimum_samples") is not None and (not isinstance(report.get("minimum_samples"), int) or report.get("minimum_samples") < required_samples):
        errors.append("cold-start report minimum_samples is below the governed requirement")
    if len(samples) < required_samples:
        errors.append(f"cold-start validation requires at least {required_samples} samples")
    task_ids = set(task_result.get("task_ids", []))
    sampled: set[str] = set()
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict):
            errors.append(f"cold-start sample[{index}] is not an object")
            continue
        task_id = sample.get("task_id")
        verdict = sample.get("classification", sample.get("verdict", sample.get("result")))
        if task_id not in task_ids:
            errors.append(f"cold-start sample[{index}] references an unknown task")
        if task_id in sampled:
            errors.append(f"cold-start task sampled more than once: {task_id}")
        if isinstance(task_id, str):
            sampled.add(task_id)
        if verdict != "EXECUTABLE":
            errors.append(f"cold-start sample {task_id or index} is {verdict or 'missing-verdict'}")
    return {"status": "READY" if not errors else "CHANGES_REQUESTED", "sample_count": len(samples), "required_samples": required_samples, "errors": errors}


def audit_feature_readiness(root: Path, feature_dir: str) -> dict[str, Any]:
    config = require_governance_v2(root)
    locations = feature_locations(root, feature_dir)
    ledger = read_review_ledger(locations["ledger_path"], locations["feature_id"])
    approvals = [current_artifact_approval(root, locations, artifact) for artifact in ("DISCOVERY", "SPECIFICATION", "PLAN_BUNDLE", "TASK_PACKAGE")]
    event_positions = {event["event_id"]: index for index, event in enumerate(ledger["events"])}
    prior_approval_position = -1
    for approval in approvals:
        position = event_positions.get(approval.get("event_id"), -1)
        if approval["status"] == "APPROVED" and position < prior_approval_position:
            approval["status"] = "STALE"
            approval["reason"] = "an upstream review object was approved more recently"
        if approval["status"] == "APPROVED":
            prior_approval_position = position
    remediation_present = any(
        event.get("artifact_type") == "REMEDIATION"
        for event in ledger["events"]
    ) or (locations["sidecar_path"] / "REMEDIATION.md").is_file() or (locations["sidecar_path"] / "REMEDIATION.json").is_file()
    if remediation_present:
        approvals.append(current_artifact_approval(root, locations, "REMEDIATION"))
    task_result = verify_task_package(root, locations)
    cold_start = verify_cold_start(root, locations, task_result, config)
    blocked = [item for item in approvals if item["status"] != "APPROVED"]
    if task_result["status"] != "READY" or cold_start["status"] != "READY":
        status = "CHANGES_REQUESTED"
    elif blocked:
        status = "REVIEW_REQUIRED"
    else:
        status = "READY"
    return {
        "schema_version": 1,
        "status": status,
        "feature_id": locations["feature_id"],
        "governance_generation": 2,
        "approvals": approvals,
        "task_package": task_result,
        "cold_start_validation": cold_start,
        "implement_allowed": status == "READY",
    }


def artifact_review_mutation(root: Path, args: argparse.Namespace) -> tuple[dict[str, Any], dict[str, Any]]:
    """Build exactly one append-only ledger event from explicit operator input."""
    require_governance_v2(root)
    locations = feature_locations(root, args.feature_dir)
    artifact_type = args.artifact_type
    decision = args.decision
    reviewer = args.reviewer.strip()
    if not reviewer or AGENT_REVIEWER_RE.search(reviewer):
        raise GovernanceError("reviewer must identify the human reviewer, not an Agent", "REVIEW_REQUIRED")
    if not args.evidence.strip() or not args.review_summary.strip():
        raise GovernanceError("review evidence and summary must be explicit and non-empty", "REVIEW_REQUIRED")
    ledger = read_review_ledger(locations["ledger_path"], locations["feature_id"])
    prior = [event for event in ledger["events"] if event["artifact_type"] == artifact_type]
    previous = prior[-1] if prior else None
    paths = event_artifact_paths(root, locations, artifact_type, args.artifact_path)
    hashes = {rel: sha256_file(root / rel) for rel in paths}
    if decision in {"APPROVED", "CHANGES_REQUESTED"}:
        if previous is None or previous["decision"] != "REVIEW_REQUESTED":
            raise GovernanceError(f"{decision} requires the immediately preceding REVIEW_REQUESTED event", "REVIEW_REQUIRED")
        if previous["artifact_paths"] != paths or previous["content_sha256"] != hashes:
            raise GovernanceError("reviewed artifact content changed after the review request", "STALE")
    if decision == "SUPERSEDED" and (previous is None or previous["decision"] != "APPROVED"):
        raise GovernanceError("SUPERSEDED requires the immediately preceding APPROVED event", "STATE_BROKEN")
    supersedes = args.supersedes_event_id
    if decision == "SUPERSEDED":
        supersedes = supersedes or previous["event_id"]
    elif supersedes is not None:
        raise GovernanceError("supersedes_event_id is valid only for SUPERSEDED", "STATE_BROKEN")
    recorded_at = iso(utc_now())
    event: dict[str, Any] = {
        "event_id": uuid.uuid4().hex,
        "artifact_type": artifact_type,
        "decision": decision,
        "artifact_paths": paths,
        "content_sha256": hashes,
        "review_summary": args.review_summary.strip(),
        "open_risks": list(args.open_risk or []),
        "recorded_by": reviewer,
        "recorded_at": recorded_at,
        "evidence": args.evidence.strip(),
        "supersedes_event_id": supersedes,
    }
    if decision == "APPROVED":
        event["approved_by"] = reviewer
        event["approved_at"] = recorded_at
    updated = {**ledger, "events": [*ledger["events"], event]}
    validate_review_ledger_object(updated, locations["feature_id"])
    mutation = file_mutation(root, locations["ledger_rel"], canonical_json(updated) + b"\n", "replace")
    return mutation, event


def validate_review_append_at_apply(root: Path, plan: dict[str, Any]) -> None:
    if plan.get("operation_type") != "plan-record-artifact-review":
        return
    mutations = plan.get("manager_file_mutations", [])
    if len(mutations) != 1 or plan.get("external_cli_mutations"):
        raise GovernanceError("artifact review plan must contain exactly one local ledger mutation", "REFERENCE_OWNERSHIP_VIOLATION")
    item = mutations[0]
    match = re.fullmatch(r"docs/spec-kit/features/([A-Za-z0-9][A-Za-z0-9._-]*)/REVIEW_LEDGER\.json", str(item.get("path")))
    if not match:
        raise GovernanceError("artifact review plan targets a non-ledger path", "REFERENCE_OWNERSHIP_VIOLATION")
    try:
        content = base64.b64decode(item["content_b64"], validate=True)
        updated = json.loads(content)
    except (KeyError, ValueError, json.JSONDecodeError) as exc:
        raise GovernanceError("artifact review plan contains an invalid ledger payload", "STATE_BROKEN") from exc
    if not isinstance(updated, dict):
        raise GovernanceError("artifact review ledger payload must be an object", "STATE_BROKEN")
    current = read_review_ledger(root / item["path"], match.group(1))
    validate_review_ledger_object(updated, match.group(1))
    if len(updated["events"]) != len(current["events"]) + 1 or updated["events"][:-1] != current["events"]:
        raise GovernanceError("artifact review plan may only append one event", "REFERENCE_OWNERSHIP_VIOLATION")


def cli_compatibility(root: Path) -> str:
    executable = shutil.which("specify")
    if not executable:
        return "CLI_MISSING"
    # The CLI version is diagnostic data only.  Compatibility is established
    # by probing the command and component contracts used by the requested
    # operation; a newer or otherwise unparseable version must not be rejected
    # merely because it is outside an old tested-version range.
    return "READY" if cli_version() else "CLI_CONTRACT_UNVERIFIED"


def adaptive_project_config(config: dict[str, Any]) -> dict[str, Any]:
    """Migrate the old mandatory companion defaults to the adaptive profile.

    The migration is intentionally idempotent and only changes Reference-owned
    configuration.  A project may still opt into ``governed-sdd`` explicitly,
    but the former ``governed-sdd-required`` default is never carried forward.
    """
    updated = copy.deepcopy(config)
    if updated.get("schema_version") == 2:
        upgrade = updated.setdefault("upgrade", {})
        if upgrade.get("review_mode") == "pull-request-required" or not upgrade.get("review_mode"):
            upgrade["review_mode"] = "automatic-reference-upgrade"
        workflow = updated.setdefault("workflow_governance", {})
        if workflow.get("mode") == "governed-sdd-required" or not workflow.get("mode"):
            workflow["mode"] = "upstream-adaptive"
            workflow["discovery"] = "risk-based"
            for key in ("artifact_reviews", "approval_evidence", "tiny_model_tasks", "cold_start_review"):
                workflow.pop(key, None)
        elif workflow.get("mode") == "governed-sdd":
            workflow.setdefault("discovery", "required-for-substantive")
        gates = updated.setdefault("quality_gates", {})
        for key in ("clarify", "checklist", "analyze"):
            if gates.get(key) == "required":
                gates[key] = "risk-triggered"
    return updated


def cli_contract_metadata(reviewed_upstream: str | None, observed_version: str | None = None) -> dict[str, Any]:
    """Return version-neutral compatibility metadata for a project manifest."""
    return {
        "required_capabilities": [
            "specify",
            "integration.status",
            "extension.list",
            "extension.add",
        ],
        "optional_capabilities": [
            "workflow.list",
            "preset.list",
            "workflow.add",
            "preset.add",
        ],
        "contract_schema": 1,
        "observed_version": observed_version,
        "contract_fingerprint": None,
        "approved_install_ref": reviewed_upstream or "0" * 40,
    }


def governance_files(root: Path) -> list[str]:
    return [
        f"{PROJECT_PACKAGE}/START_HERE.md", f"{PROJECT_PACKAGE}/POLICY.md", f"{PROJECT_PACKAGE}/REFERENCE.md",
        f"{PROJECT_PACKAGE}/OPERATING_PROTOCOL.md", f"{PROJECT_PACKAGE}/AGENT_ONBOARDING.md",
        f"{PROJECT_PACKAGE}/LOCAL_OVERRIDES.md", f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json",
        f"{PROJECT_PACKAGE}/MANIFEST.json", f"{PROJECT_PACKAGE}/ADAPTERS.json", MANAGER_RELATIVE,
    ]


def source_root(value: str | None) -> Path:
    root = Path(value).resolve() if value else Path(__file__).resolve().parents[2]
    required = [root / "governance/project", root / "governance/schemas"]
    if not all(item.is_dir() for item in required):
        raise GovernanceError(f"invalid governance source: {root}")
    return root


def valid_language_tag(value: Any) -> bool:
    """Accept a structurally valid BCP 47 language tag without a product-specific list."""
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*", value) is not None


def governance_loader(source: Path | None = None) -> str:
    """Read the reviewed Loader block from a source tree without importing it."""
    source_root_path = source or Path(__file__).resolve().parents[2]
    source_file = source_root_path / GOVERNANCE_LOADER_SOURCE
    if source_file.is_file():
        return source_file.read_text(encoding="utf-8")
    return (
        f"{START_MARKER}\n\n"
        "# Spec Kit Governance\n\n"
        "This repository uses the committed project-local Spec Kit governance package.\n\n"
        "Read `docs/spec-kit/START_HERE.md` before substantive engineering work.\n\n"
        "A conversational approval such as `the plan is acceptable` advances a direction into the upstream Spec Kit workflow; "
        "it does not authorize direct application-code edits before the current Spec Kit artifacts are aligned.\n\n"
        "The governance package does not edit `.specify/**`, `specs/**`, or native Agent-generated integration files.\n\n"
        "Do not replace the project baseline with personal global rules or a local Reference.\n\n"
        f"{END_MARKER}\n"
    )


def marker_loader(documentation_language: str | None = None, source: Path | None = None) -> str:
    if documentation_language is not None:
        if not valid_language_tag(documentation_language):
            raise GovernanceError("documentation language must be a valid BCP 47 tag", "DOCUMENTATION_LANGUAGE_INVALID")
        language_rule = (
            f"Project documentation language: `{documentation_language}`.\n\n"
            "Write new and substantively rewritten project documentation, including Spec Kit artifacts, "
            "in this language unless an explicit user or more specific project instruction overrides it. "
            "Do not translate existing documentation solely because this setting was selected."
        )
    loader = governance_loader(source)
    if documentation_language is None:
        return loader
    end_marker_at = loader.find(END_MARKER)
    if end_marker_at < 0:
        raise GovernanceError("governance Loader source has a malformed end marker", "STATE_BROKEN")
    return loader[:end_marker_at].rstrip("\r\n") + "\n\n" + language_rule + "\n\n" + loader[end_marker_at:]


def update_reminder_loader() -> str:
    return (
        f"{UPDATE_REMINDER_START_MARKER}\n\n"
        "# Spec Kit upstream update check\n\n"
        "This is a project-local update protocol. It is independent of the central Reference, "
        "`GLOBAL_POLICY.md`, and `docs/spec-kit/**`; it activates whenever `.specify/` exists.\n\n"
        "Run at most once in each new Agent session, before the first substantive engineering action or mutation; "
        "use the currently installed CLI to run the read-only command `specify self check`. Do not assume an exact "
        "CLI version or a fixed install source. If the CLI is missing, ask the user whether to install the official "
        "CLI and otherwise hand control back to the current Agent. If the check is offline or times out, report that "
        "it was unavailable and continue normal work.\n\n"
        "If a newer CLI is reported, show the available version and ask the user for explicit approval before running "
        "`specify self upgrade`. A refusal or no-update result ends the CLI-upgrade branch; do not ask again in the "
        "same session.\n\n"
        "Regardless of whether the CLI upgrade was approved, declined, or not needed, use the currently active CLI "
        "and project state to inspect the active integration and installed extensions "
        "and workflows with the CLI's current `--help`, `status`, and `list` contracts. If an installed integration, "
        "extension, or workflow is refreshable, run the current CLI's supported `specify integration upgrade "
        "<active-key>`, `specify extension update`, or `specify workflow update` command automatically, without a "
        "second user approval. If the CLI exposes no freshness field, the supported no-force update command may be "
        "run for an installed component and its no-update result is sufficient. Normal confirmation prompts belonging "
        "to these refresh commands are pre-authorized by "
        "this protocol. Do not install missing components as part of refresh, do not assume presets are covered, and "
        "do not invent flags or pin a version.\n\n"
        "Never add `--force` to an automatic refresh. If the CLI refuses because managed files were modified, asks "
        "for `--force`, reports an unsafe scope, or otherwise requires an irreversible choice, stop and ask the user "
        "before proceeding. Preserve the project state and report the exact command and affected paths.\n\n"
        "This protocol does not replace the upstream Spec Kit lifecycle and does not authorize the manager to edit "
        "`.specify/**` or `specs/**`; supported upstream CLI commands remain the owner of their generated project "
        "artifacts.\n\n"
        f"{UPDATE_REMINDER_END_MARKER}\n"
    )


def reference_update_loader(source: Path | None = None) -> str:
    """Return the session-gated central Reference update check block.

    The source copy is packaged with the manager so a staged release can
    update the block without executing or importing code from the source
    repository.  The fallback keeps older staging layouts readable.
    """
    source_root_path = source or Path(__file__).resolve().parents[2]
    source_file = source_root_path / REFERENCE_UPDATE_SOURCE
    if source_file.is_file():
        return source_file.read_text(encoding="utf-8")
    return (
        f"{REFERENCE_UPDATE_START_MARKER}\n\n"
        "# Spec Kit Reference update check\n\n"
        "This check is active only when the current Agent has loaded the global Spec Kit Policy "
        "and that Policy provides a readable `SPEC_KIT_GOVERNANCE_SOURCE` absolute path.\n\n"
        "When `.specify/` and the committed project governance package are present, run the local "
        "governance manager's read-only `check-update --source <central-reference-path>` once before "
        "the first substantive task in a new Agent session. If the Policy or source locator is absent, "
        "skip this check silently; do not scan the computer for a Reference directory.\n\n"
        "If a verified Reference update is available, run the exact hash-bound `auto-upgrade` operation "
        "without waiting for project-owner approval. The sync may update only Reference-owned governance files "
        "and this managed block; it must never edit `.specify/**`, `specs/**`, native Agent files, or "
        "business code. After the governance sync, let the upstream Spec Kit workflow decide whether any "
        "specification, plan, or task artifacts need updating.\n\n"
        "A missing source, unclean source, invalid verification, offline check, or timeout is non-blocking in "
        "normal project work and must not be presented as an available update.\n\n"
        f"{REFERENCE_UPDATE_END_MARKER}\n"
    )


def append_managed_block(existing: bytes, loader: bytes, start_marker: str, end_marker: str, label: str) -> bytes:
    """Upsert one managed block while preserving every byte outside its markers."""
    start = start_marker.encode("utf-8")
    end = end_marker.encode("utf-8")
    start_count = existing.count(start)
    end_count = existing.count(end)
    if start_count != end_count or start_count > 1:
        raise GovernanceError(f"project context anchor has malformed or duplicate {label} markers", "STATE_BROKEN")
    if start_count == 1:
        start_at = existing.index(start)
        end_at = existing.index(end, start_at) + len(end)
        current_block = existing[start_at:end_at]
        if current_block == loader.rstrip(b"\n"):
            return existing
        if existing[end_at:end_at + 2] == b"\r\n":
            end_at += 2
        elif existing[end_at:end_at + 1] == b"\n":
            end_at += 1
        return existing[:start_at] + loader + existing[end_at:]
    if not existing.strip():
        return loader
    if existing.endswith(b"\n\n") or existing.endswith(b"\r\n\r\n"):
        separator = b""
    elif existing.endswith(b"\r\n"):
        separator = b"\r\n"
    elif existing.endswith(b"\n"):
        separator = b"\n"
    else:
        separator = b"\n\n"
    return existing + separator + loader


def append_loader(existing: bytes, loader: bytes) -> bytes:
    """Upsert the full governance Loader while preserving every byte outside its markers."""
    return append_managed_block(existing, loader, START_MARKER, END_MARKER, "governance")


def append_update_reminder(existing: bytes, loader: bytes) -> bytes:
    """Upsert the optional update reminder while preserving every other anchor byte."""
    return append_managed_block(existing, loader, UPDATE_REMINDER_START_MARKER, UPDATE_REMINDER_END_MARKER, "update reminder")


def append_reference_update_check(existing: bytes, loader: bytes) -> bytes:
    """Upsert the central Reference check while preserving every other anchor byte."""
    return append_managed_block(existing, loader, REFERENCE_UPDATE_START_MARKER, REFERENCE_UPDATE_END_MARKER, "Reference update check")


def extract_managed_block(content: bytes, start_marker: str, end_marker: str) -> bytes:
    start = start_marker.encode("utf-8")
    end = end_marker.encode("utf-8")
    if content.count(start) != 1 or content.count(end) != 1:
        raise GovernanceError("managed bootstrap content has malformed markers", "STATE_BROKEN")
    start_at = content.index(start)
    end_at = content.index(end, start_at) + len(end)
    return content[start_at:end_at] + b"\n"


def append_bootstrap_blocks(existing: bytes, content: bytes) -> bytes:
    """Upsert both bootstrap blocks as one atomic anchor mutation."""
    governance = extract_managed_block(content, START_MARKER, END_MARKER)
    reference = extract_managed_block(content, REFERENCE_UPDATE_START_MARKER, REFERENCE_UPDATE_END_MARKER)
    result = append_loader(existing, governance)
    return append_reference_update_check(result, reference)


def source_version(source: Path, constant: str, fallback: Any) -> Any:
    """Read release metadata from source text without importing source code."""
    manager_path = source / "governance/manager/speckit_governance.py"
    if manager_path.is_file():
        match = re.search(rf"^{re.escape(constant)}\s*=\s*\"([^\"]+)\"\s*$", manager_path.read_text(encoding="utf-8"), re.MULTILINE)
        if match:
            return match.group(1)
    return fallback


def source_metadata(source: Path) -> dict[str, Any]:
    """Read release provenance from a staged artifact without importing code."""
    path = source / SOURCE_METADATA_SOURCE
    if not path.is_file():
        return {}
    try:
        metadata = read_json(path)
    except (OSError, json.JSONDecodeError) as exc:
        raise GovernanceError("governance source metadata is invalid", "CENTRAL_SOURCE_UNVERIFIED") from exc
    if not isinstance(metadata, dict):
        raise GovernanceError("governance source metadata must be an object", "CENTRAL_SOURCE_UNVERIFIED")
    for field in ("revision", "reviewed_upstream_revision"):
        value = metadata.get(field)
        if value is not None and not re.fullmatch(r"[0-9a-f]{40}", str(value)):
            raise GovernanceError(f"governance source metadata has an invalid {field}", "CENTRAL_SOURCE_UNVERIFIED")
    return metadata


def source_revision(source: Path) -> str | None:
    revision = git_value(source, "rev-parse", "HEAD")
    if re.fullmatch(r"[0-9a-f]{40}", revision):
        return revision
    metadata_revision = source_metadata(source).get("revision")
    return str(metadata_revision) if re.fullmatch(r"[0-9a-f]{40}", str(metadata_revision)) else None


def reviewed_upstream_revision(source: Path) -> str | None:
    baseline_path = source / "UPSTREAM_BASELINE"
    if baseline_path.is_file():
        baseline = baseline_path.read_text(encoding="utf-8").strip()
        if re.fullmatch(r"[0-9a-f]{40}", baseline):
            return baseline
    metadata_baseline = source_metadata(source).get("reviewed_upstream_revision")
    return str(metadata_baseline) if re.fullmatch(r"[0-9a-f]{40}", str(metadata_baseline)) else None


def strict_source_snapshot(source_value: str | None) -> dict[str, Any]:
    """Verify a clean v2 source and bind every migration/companion input byte."""
    if not source_value or not Path(source_value).is_absolute():
        raise GovernanceError("strict governance operations require an absolute --source", "CENTRAL_SOURCE_UNVERIFIED")
    source = source_root(source_value)
    revision = source_revision(source)
    if revision is None:
        raise GovernanceError("strict governance source has no verifiable revision", "CENTRAL_SOURCE_UNVERIFIED")
    if (source / ".git").exists() and git_value(source, "status", "--porcelain=v1", "--untracked-files=all"):
        raise GovernanceError("strict governance source worktree is not clean", "CENTRAL_SOURCE_UNVERIFIED")
    default_config_path = source / "governance/project/PROJECT_CONFIG.default.json"
    if not default_config_path.is_file() or read_json(default_config_path).get("schema_version") != 2:
        raise GovernanceError("strict governance source does not contain PROJECT_CONFIG v2", "CENTRAL_SOURCE_UNVERIFIED")
    if source_version(source, "GOVERNANCE_PACKAGE_VERSION", None) != "2.0.0" or source_version(source, "MANAGER_VERSION", None) != "2.0.0":
        raise GovernanceError("strict governance source is not the reviewed 2.0.0 generation", "CENTRAL_SOURCE_UNVERIFIED")
    required = [
        Path("governance/project/PROJECT_CONFIG.default.json"),
        Path("governance/manager/speckit_governance.py"),
        COMPANION_ROOT / "extensions/discovery/extension.yml",
        COMPANION_ROOT / "presets/tiny-model-tasks/preset.yml",
        COMPANION_ROOT / "workflows/governed-sdd/workflow.yml",
    ]
    for relative in required:
        if not (source / relative).is_file():
            raise GovernanceError(f"strict governance source is missing {relative.as_posix()}", "CENTRAL_SOURCE_UNVERIFIED")
    files = {
        path.relative_to(source).as_posix(): sha256_file(path)
        for path in sorted((source / "governance").rglob("*"))
        if path.is_file() and not path.is_symlink()
    }
    return {
        "source_root": str(source),
        "source_revision": revision,
        "tree_sha256": sha256_bytes(canonical_json(files)),
        "files": files,
    }


def validate_strict_source_snapshot(snapshot: dict[str, Any] | None) -> None:
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("source_root"), str) or not Path(snapshot["source_root"]).is_absolute():
        raise GovernanceError("strict source snapshot is missing", "CENTRAL_SOURCE_UNVERIFIED")
    current = strict_source_snapshot(snapshot["source_root"])
    if current != snapshot:
        raise GovernanceError("strict governance source changed after plan creation", "CENTRAL_SOURCE_UNVERIFIED")


def migration_binding_payload(plan_fields: dict[str, Any], record: dict[str, Any]) -> dict[str, Any]:
    """Canonical non-circular binding between a migration record and its plan."""
    return {
        "algorithm": "sha256-canonical-json-v1",
        "operation_type": plan_fields["operation_type"],
        "plan_id": plan_fields["plan_id"],
        "project_root_fingerprint": plan_fields["project_root_fingerprint"],
        "git_head": plan_fields["git_head"],
        "git_status_porcelain_sha256": plan_fields["git_status_porcelain_sha256"],
        "source_revision": record["source_revision"],
        "config_sha256_before": record["config_sha256_before"],
        "config_sha256_after": record["config_sha256_after"],
        "backup_inventory": record["backup_inventory"],
        "preserved_subtrees": record["preserved_subtrees"],
    }


def migration_binding_sha256(plan_fields: dict[str, Any], record: dict[str, Any]) -> str:
    return sha256_bytes(canonical_json(migration_binding_payload(plan_fields, record)))


def preflight_writable(root: Path, rel: str) -> dict[str, Any]:
    safe_relative(root, rel)
    target = root / rel
    parent = target.parent
    if target.exists() and not target.is_file():
        raise GovernanceError(f"native anchor is not a regular file: {rel}", "NATIVE_INSTALL_BLOCKED")
    if parent.exists() and not os.access(parent, os.W_OK):
        raise GovernanceError(f"native anchor parent is not writable: {rel}", "NATIVE_INSTALL_BLOCKED")
    if target.exists() and not os.access(target, os.W_OK):
        raise GovernanceError(f"native anchor is not writable: {rel}", "NATIVE_INSTALL_BLOCKED")
    return {"path": rel, "writable": True, "evidence": "os.access(parent,target,W_OK)"}


def file_mutation(root: Path, rel: str, content: bytes, action: str = "create", *, protected_anchor: bool = False) -> dict[str, Any]:
    safe_relative(root, rel)
    if protected_anchor and action not in MANAGED_ANCHOR_ACTIONS:
        raise GovernanceError("the project-owned context anchor accepts only approved managed-block appends", "PROJECT_RULES_PROTECTED")
    target = root / rel
    actual_action = action if action in MANAGED_ANCHOR_ACTIONS or target.exists() else "create"
    expected_content = content
    if actual_action in MANAGED_ANCHOR_ACTIONS and target.is_file():
        if actual_action == "append-managed-loader":
            expected_content = append_loader(target.read_bytes(), content)
        elif actual_action == "append-managed-update-reminder":
            expected_content = append_update_reminder(target.read_bytes(), content)
        elif actual_action == "append-managed-reference-update-check":
            expected_content = append_reference_update_check(target.read_bytes(), content)
        elif actual_action == "append-managed-bootstrap":
            expected_content = append_bootstrap_blocks(target.read_bytes(), content)
    mutation = {
        "action": actual_action,
        "path": rel,
        "old_sha256": sha256_file(target) if target.is_file() else None,
        "expected_new_sha256": sha256_bytes(expected_content),
        "mode": stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644,
        "content_b64": base64.b64encode(content).decode("ascii"),
    }
    if protected_anchor:
        mutation["protected_anchor"] = True
    return mutation


def onboarding_mutations(root: Path, runtime_id: str, display_name: str, key: str, anchor_path: str, evidence_rel: str, *, integration_mode: str = "native", attestation_hash: str | None = None, attestation_rel: str | None = None, commands_dir: str | None = None, delivery_mode: str = "loader") -> tuple[list[dict[str, Any]], dict[str, Any], str]:
    preflight_writable(root, anchor_path)
    config = project_config(root) or {}
    doc_lang = config.get("documentation", {}).get("language_tag")
    anchor_mutation = file_mutation(
        root, anchor_path, marker_loader(doc_lang).encode("utf-8"),
        "append-managed-loader", protected_anchor=True,
    )
    evidence = {
        "schema_version": 1,
        "runtime_id": runtime_id,
        "display_name": display_name,
        "integration_key": key,
        "integration_mode": integration_mode,
        "anchor_path": anchor_path,
        "result": "native-install-provisional",
        "verified": False,
        "created_at": iso(utc_now()),
    }
    evidence_bytes = canonical_json(evidence) + b"\n"
    evidence_mutation = file_mutation(root, evidence_rel, evidence_bytes)
    evidence_hash = evidence_mutation["expected_new_sha256"]
    anchor_id = "anchor-" + sha256_bytes(anchor_path.encode("utf-8"))[:16]
    adapters_path = root / PROJECT_PACKAGE / "ADAPTERS.json"
    registry = adapters(root)
    anchors = [item for item in registry.get("anchors", []) if item.get("id") != anchor_id]
    anchors.append({
        "id": anchor_id, "path": anchor_path, "format": "markdown", "delivery_mode": delivery_mode,
        "marker_start": START_MARKER, "marker_end": END_MARKER,
        "managed_content_sha256": anchor_mutation["expected_new_sha256"], "status": "rendered", "managed": True,
    })
    bindings = [item for item in registry.get("bindings", []) if item.get("runtime_id") != runtime_id]
    bindings.append({
        "runtime_id": runtime_id, "display_name": display_name or runtime_id, "integration_key": key,
        "integration_mode": integration_mode, "status_evidence_sha256": evidence_hash,
        "default_integration_changed": False, "anchor_ids": [anchor_id],
        "capabilities": {"core_workflow": "not-verified", "extensions": "not-verified", "presets": "not-verified", "events": "not-verified"},
        "verification": {"status": "provisional", "specify_version": cli_version() or "unknown", "product_version": runtime_id, "verified_at": iso(utc_now()), "method": "fresh-session-materialized" if delivery_mode == "materialized" else "fresh-session-loader", "evidence": evidence_rel},
    })
    if integration_mode == "explicit-generic-transition":
        bindings[-1]["generic_transition"] = {
            "native_absence_attestation_sha256": attestation_hash or "0" * 64,
            "native_absence_evidence": attestation_rel or evidence_rel,
            "attested_specify_version": cli_version() or "unknown",
            "native_integration_available_at_approval": False,
            "limitations_acknowledged": True,
            "commands_dir": commands_dir or "",
            "format": "markdown",
            "compatibility_verified": True,
        }
    registry = {"schema_version": 1, "anchors": anchors, "bindings": bindings}
    adapters_mutation = file_mutation(root, f"{PROJECT_PACKAGE}/ADAPTERS.json", canonical_json(registry) + b"\n", "replace")
    mutations = [anchor_mutation, evidence_mutation, adapters_mutation]
    manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
    if manifest_path.is_file():
        manifest = read_json(manifest_path)
        manifest.setdefault("content_sha256", {})[f"{PROJECT_PACKAGE}/ADAPTERS.json"] = adapters_mutation["expected_new_sha256"]
        mutations.append(file_mutation(root, f"{PROJECT_PACKAGE}/MANIFEST.json", canonical_json(manifest) + b"\n", "replace"))
    return mutations, {"path": anchor_path, "writable": True, "evidence": "preflight_writable"}, anchor_id


def governance_update_mutations(root: Path, source: Path, context_anchor: str | None = None) -> list[dict[str, Any]]:
    mapping = {
        "START_HERE.md": source / "governance/project/START_HERE.md",
        "POLICY.md": source / "governance/project/POLICY.md",
        "REFERENCE.md": source / "governance/project/REFERENCE.md",
        "OPERATING_PROTOCOL.md": source / "governance/project/OPERATING_PROTOCOL.md",
        "AGENT_ONBOARDING.md": source / "governance/project/AGENT_ONBOARDING.md",
    }
    mutations = [file_mutation(root, f"{PROJECT_PACKAGE}/{name}", path.read_bytes(), "replace") for name, path in mapping.items()]
    config_path = root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"
    if config_path.is_file():
        config = adaptive_project_config(read_json(config_path))
        mutations.append(file_mutation(root, f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json", canonical_json(config) + b"\n", "replace"))
    manager_source = source / "governance/manager/speckit_governance.py"
    if not manager_source.is_file():
        raise GovernanceError("governance manager is missing from update source", "CENTRAL_SOURCE_UNVERIFIED")
    mutations.append(file_mutation(root, MANAGER_RELATIVE, manager_source.read_bytes(), "replace"))
    manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
    if manifest_path.is_file():
        manifest = read_json(manifest_path)
        for item in mutations:
            manifest.setdefault("content_sha256", {})[item["path"]] = item["expected_new_sha256"]
        manifest["governance_package_version"] = source_version(source, "GOVERNANCE_PACKAGE_VERSION", manifest.get("governance_package_version"))
        manifest["policy_version"] = source_version(source, "POLICY_VERSION", manifest.get("policy_version"))
        manifest["reference_version"] = source_version(source, "REFERENCE_VERSION", manifest.get("reference_version"))
        manifest["manager_version"] = source_version(source, "MANAGER_VERSION", manifest.get("manager_version"))
        manifest["specify_compatibility"] = cli_contract_metadata(
            manifest.get("source", {}).get("reviewed_upstream_revision") or reviewed_upstream_revision(source),
            cli_version(),
        )
        manifest["source"] = manifest.get("source", {})
        source_revision_value = source_revision(source)
        if source_revision_value is None:
            raise GovernanceError("governance update source has no verifiable revision", "CENTRAL_SOURCE_UNVERIFIED")
        manifest["source"]["revision"] = source_revision_value
        manifest["source"]["release"] = f"v{manifest['governance_package_version']}"
        mutations.append(file_mutation(root, f"{PROJECT_PACKAGE}/MANIFEST.json", canonical_json(manifest) + b"\n", "replace"))
    if context_anchor:
        anchor_path = root / context_anchor
        if not anchor_path.is_file():
            raise GovernanceError("Reference update requires the existing context anchor", "CONTEXT_ANCHOR_UNKNOWN")
        config = project_config(root) or {}
        documentation_language = config.get("documentation", {}).get("language_tag")
        mutations.append(file_mutation(
            root,
            context_anchor,
            marker_loader(documentation_language, source=source).encode("utf-8")
            + reference_update_loader(source).encode("utf-8"),
            "append-managed-bootstrap",
            protected_anchor=True,
        ))
    return mutations


def governance_v2_upgrade_mutations(root: Path, source_snapshot: dict[str, Any], plan_id: str) -> tuple[list[dict[str, Any]], str]:
    current_config = project_config(root)
    if current_config is None or current_config.get("schema_version") != 1:
        raise GovernanceError("v2 migration requires an existing PROJECT_CONFIG v1", "MIGRATION_REQUIRED")
    current_manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
    if not current_manifest_path.is_file():
        raise GovernanceError("v2 migration requires the reviewed 1.3.0 bridge manifest", "MIGRATION_REQUIRED")
    current_manifest = read_json(current_manifest_path)
    if current_manifest.get("governance_package_version") != "1.3.0" or current_manifest.get("manager_version") != "1.3.0":
        raise GovernanceError("v2 migration is allowed only from the verified 1.3.0 bridge", "MIGRATION_REQUIRED")
    source = Path(source_snapshot["source_root"])
    strict_defaults = read_json(source / "governance/project/PROJECT_CONFIG.default.json")
    migrated_config = copy.deepcopy(current_config)
    migrated_config["schema_version"] = 2
    migrated_config["quality_gates"] = copy.deepcopy(strict_defaults["quality_gates"])
    migrated_config["workflow_governance"] = copy.deepcopy(strict_defaults["workflow_governance"])
    config_bytes = canonical_json(migrated_config) + b"\n"
    config_mutation = file_mutation(root, f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json", config_bytes, "replace")

    baseline_mutations = governance_update_mutations(root, source, None)
    baseline_mutations = [item for item in baseline_mutations if item["path"] != f"{PROJECT_PACKAGE}/MANIFEST.json"]
    mutations = [*baseline_mutations, config_mutation]
    original_paths: dict[str, str] = {}
    for item in mutations:
        if item.get("old_sha256") is not None:
            original_paths[item["path"]] = item["old_sha256"]
    manifest_path = current_manifest_path
    if not manifest_path.is_file():
        raise GovernanceError("v2 migration requires an existing governance manifest", "PROJECT_NOT_INITIALIZED")
    original_paths[f"{PROJECT_PACKAGE}/MANIFEST.json"] = sha256_file(manifest_path)
    backup_inventory = [{"path": path, "sha256": digest} for path, digest in sorted(original_paths.items())]
    migration_id = "migration-" + uuid.uuid4().hex
    migration_rel = f"{PROJECT_PACKAGE}/evidence/{migration_id}.json"
    fingerprint = git_fingerprint(root)
    record: dict[str, Any] = {
        "schema_version": 1,
        "migration_id": migration_id,
        "from_project_config_version": 1,
        "to_project_config_version": 2,
        "created_at": iso(utc_now()),
        "plan_id": plan_id,
        "plan_binding_sha256": "",
        "source_revision": source_snapshot["source_revision"],
        "config_sha256_before": sha256_file(root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"),
        "config_sha256_after": config_mutation["expected_new_sha256"],
        "backup_inventory": backup_inventory,
        "preserved_subtrees": [".specify", "docs/spec-kit/features", "specs"],
        "rollback_journal": [
            {"sequence": index, "action": "RESTORE", "path": item["path"], "expected_sha256": item["sha256"]}
            for index, item in enumerate(backup_inventory, 1)
        ] + [{"sequence": len(backup_inventory) + 1, "action": "VERIFY_PRESERVED", "path": "docs/spec-kit/features", "expected_sha256": tree_digest(root, "docs/spec-kit/features")}],
        "status": "APPLIED",
    }
    binding_fields = {"operation_type": "plan-upgrade-governance-v2", "plan_id": plan_id, **fingerprint}
    record["plan_binding_sha256"] = migration_binding_sha256(binding_fields, record)
    record_mutation = file_mutation(root, migration_rel, canonical_json(record) + b"\n")
    mutations.append(record_mutation)

    manifest = read_json(manifest_path)
    manifest["schema_version"] = 2
    manifest["governance_package_version"] = "2.0.0"
    manifest["policy_version"] = source_version(source, "POLICY_VERSION", "2.0.0")
    manifest["reference_version"] = source_version(source, "REFERENCE_VERSION", REFERENCE_VERSION)
    manifest["manager_version"] = "2.0.0"
    manifest["specify_compatibility"] = cli_contract_metadata(
        manifest.get("source", {}).get("reviewed_upstream_revision") or reviewed_upstream_revision(source),
        cli_version(),
    )
    manifest.setdefault("source", {})["revision"] = source_snapshot["source_revision"]
    manifest["source"]["release"] = "v2.0.0"
    manifest["project_owned_prefixes"] = [f"{PROJECT_PACKAGE}/features/"]
    manifest["companion"] = {
        "version": "2.0.0",
        "extension": "governance-discovery",
        "preset": "tiny-model-tasks",
        "workflow": "governed-sdd",
        "installation_mode": "independent-native-components",
    }
    for item in mutations:
        manifest.setdefault("content_sha256", {})[item["path"]] = item["expected_new_sha256"]
    manifest_mutation = file_mutation(root, f"{PROJECT_PACKAGE}/MANIFEST.json", canonical_json(manifest) + b"\n", "replace")
    mutations.append(manifest_mutation)
    return mutations, migration_rel


def verified_migration_record(root: Path, record_rel: str) -> tuple[dict[str, Any], dict[str, Any]]:
    rel = safe_relative(root, record_rel).as_posix()
    if not re.fullmatch(r"docs/spec-kit/evidence/migration-[a-f0-9]+\.json", rel):
        raise GovernanceError("migration record path is outside the governed evidence directory", "REFERENCE_OWNERSHIP_VIOLATION")
    record = read_json(root / rel)
    original_plan_path = root / RUNTIME_DIR / "plans" / f"{record.get('plan_id')}.json"
    original_plan = load_plan(root, original_plan_path)
    if original_plan.get("operation_type") != "plan-upgrade-governance-v2":
        raise GovernanceError("migration record does not reference a v2 upgrade plan", "STATE_BROKEN")
    if record.get("source_revision") != (original_plan.get("source_snapshot") or {}).get("source_revision"):
        raise GovernanceError("migration record source revision does not match its plan", "STATE_BROKEN")
    if migration_binding_sha256(original_plan, record) != record.get("plan_binding_sha256"):
        raise GovernanceError("migration record plan binding is invalid", "STATE_BROKEN")
    return record, original_plan


def governance_v2_rollback_mutations(root: Path, record_rel: str) -> list[dict[str, Any]]:
    record, original_plan = verified_migration_record(root, record_rel)
    if record.get("status") != "APPLIED" or governance_generation(root) != 2:
        raise GovernanceError("v2 rollback requires an applied migration and active PROJECT_CONFIG v2", "STATE_BROKEN")
    config_path = root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"
    if not config_path.is_file() or sha256_file(config_path) != record.get("config_sha256_after"):
        raise GovernanceError("PROJECT_CONFIG changed after migration; rollback requires review", "RECOVERY_REQUIRED")
    allowed_restore = {
        f"{PROJECT_PACKAGE}/START_HERE.md", f"{PROJECT_PACKAGE}/POLICY.md", f"{PROJECT_PACKAGE}/REFERENCE.md",
        f"{PROJECT_PACKAGE}/OPERATING_PROTOCOL.md", f"{PROJECT_PACKAGE}/AGENT_ONBOARDING.md",
        f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json", f"{PROJECT_PACKAGE}/MANIFEST.json", MANAGER_RELATIVE,
    }
    backup_dir = root / RUNTIME_DIR / "backups" / original_plan["plan_id"]
    mutations: list[dict[str, Any]] = []
    inventory = {item["path"]: item["sha256"] for item in record.get("backup_inventory", []) if isinstance(item, dict)}
    for entry in record.get("rollback_journal", []):
        if entry.get("action") != "RESTORE":
            continue
        rel = entry.get("path")
        if rel not in allowed_restore or inventory.get(rel) != entry.get("expected_sha256"):
            raise GovernanceError("migration rollback journal attempts to restore an unowned path", "REFERENCE_OWNERSHIP_VIOLATION")
        backup = backup_dir / (rel.replace("/", "__") + ".bak")
        if not backup.is_file() or sha256_file(backup) != entry["expected_sha256"]:
            raise GovernanceError(f"verified migration backup is missing or changed: {rel}", "RECOVERY_REQUIRED")
        mutations.append(file_mutation(root, rel, backup.read_bytes(), "replace"))
    if set(inventory) != {item["path"] for item in mutations}:
        raise GovernanceError("migration backup inventory and rollback mutations differ", "STATE_BROKEN")
    rolled_back = {**record, "status": "ROLLED_BACK"}
    mutations.append(file_mutation(root, safe_relative(root, record_rel).as_posix(), canonical_json(rolled_back) + b"\n", "replace"))
    return mutations


def activate_binding_mutations(root: Path, runtime_id: str, key: str, evidence_rel: str, delivery_mode: str) -> list[dict[str, Any]]:
    evidence_path = root / safe_relative(root, evidence_rel)
    if not evidence_path.is_file():
        raise GovernanceError("fresh-session verification evidence is missing", "CONTEXT_ANCHOR_UNKNOWN")
    evidence = read_json(evidence_path)
    if evidence.get("runtime_id") != runtime_id or evidence.get("integration_key") != key or evidence.get("fresh_session") is not True or evidence.get("loader_loaded") is not True or evidence.get("managed_files_verified") is not True:
        raise GovernanceError("fresh-session evidence does not prove runtime-to-key loading", "STATE_BROKEN")
    if delivery_mode == "materialized" and evidence.get("loader_failure") is not True:
        raise GovernanceError("materialized delivery requires a recorded Loader failure", "CONTEXT_ANCHOR_UNKNOWN")
    if key != "generic":
        status = command_status(root) or {}
        installed = status.get("installed_integrations", [])
        installed_keys = {item.get("key") if isinstance(item, dict) else item for item in installed}
        if key not in installed_keys:
            raise GovernanceError("fresh-session evidence cannot activate an integration that is not installed", "NATIVE_CANDIDATE_NOT_INSTALLED")
    path = root / PROJECT_PACKAGE / "ADAPTERS.json"
    registry = adapters(root)
    binding = next((item for item in registry.get("bindings", []) if item.get("runtime_id") == runtime_id and item.get("integration_key") == key), None)
    if binding is None:
        raise GovernanceError("no provisional binding matches runtime and integration key", "STATE_BROKEN")
    binding["verification"]["status"] = "active"
    binding["verification"]["method"] = "fresh-session-materialized" if delivery_mode == "materialized" else "fresh-session-loader"
    binding["verification"]["evidence"] = evidence_rel
    binding["verification"]["verified_at"] = iso(utc_now())
    binding["capabilities"] = {"core_workflow": "verified", "extensions": "not-verified", "presets": "not-verified", "events": "not-verified"}
    registry_bytes = canonical_json(registry) + b"\n"
    mutation = file_mutation(root, f"{PROJECT_PACKAGE}/ADAPTERS.json", registry_bytes, "replace")
    mutations = [mutation]
    manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
    if manifest_path.is_file():
        manifest = read_json(manifest_path)
        manifest.setdefault("content_sha256", {})[f"{PROJECT_PACKAGE}/ADAPTERS.json"] = mutation["expected_new_sha256"]
        mutations.append(file_mutation(root, f"{PROJECT_PACKAGE}/MANIFEST.json", canonical_json(manifest) + b"\n", "replace"))
    return mutations


def make_plan(root: Path, operation: str, mutations: list[dict[str, Any]], *, external: list[dict[str, Any]] | None = None, identity: dict[str, Any] | None = None, claimed_key: str | None = None, context_anchor: str | None = None, write_preflight: list[dict[str, Any]] | None = None, anchor_compatibility_evidence: list[dict[str, Any]] | None = None, rehearsal: dict[str, Any] | None = None, documentation_language: str | None = None, plan_id: str | None = None, source_snapshot: dict[str, Any] | None = None) -> dict[str, Any]:
    now = utc_now()
    config_path = root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"
    manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
    adapter_path = root / PROJECT_PACKAGE / "ADAPTERS.json"
    overrides_path = root / PROJECT_PACKAGE / "LOCAL_OVERRIDES.md"
    status = command_status(root)
    plan: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "plan_id": plan_id or uuid.uuid4().hex,
        "operation_type": operation,
        "created_at": iso(now),
        "expires_at": iso(now + PLAN_TTL),
        **git_fingerprint(root),
        "manifest_sha256": sha256_file(manifest_path) if manifest_path.is_file() else None,
        "project_config_sha256": sha256_file(config_path) if config_path.is_file() else None,
        "adapters_sha256": sha256_file(adapter_path) if adapter_path.is_file() else None,
        "local_overrides_sha256": sha256_file(overrides_path) if overrides_path.is_file() else None,
        "integration_status_sha256": sha256_bytes(canonical_json(status)) if status is not None else None,
        "specify_version": cli_version(),
        "inputs": [{"path": m["path"], "sha256": m["old_sha256"]} for m in mutations if m["old_sha256"]],
        "input_files": [{"path": m["path"], "sha256": m["old_sha256"]} for m in mutations if m["old_sha256"]],
        "identity": identity or {},
        "current_agent": {"runtime_id": (identity or {}).get("runtime_id", "agent-neutral-bootstrap"), "declaration_source": "user-declared" if identity else "runtime-declared"},
        "claimed_integration_key": claimed_key,
        "required_native_key": claimed_key,
        "native_fallback_prohibited": bool(claimed_key and claimed_key != "generic"),
        "native_target_paths": [],
        "write_preflight": write_preflight or [],
        "on_native_write_failure": "NATIVE_INSTALL_BLOCKED",
        "anchor": context_anchor,
        "context_anchor": context_anchor,
        "anchor_compatibility_evidence": anchor_compatibility_evidence or [],
        "documentation_language": documentation_language,
        "rehearsal": rehearsal,
        "source_snapshot": source_snapshot,
        "capability_inventory_before": runtime_capability_inventory(root),
        "manager_file_mutations": mutations,
        "external_cli_mutations": external or [],
        "changes_default_integration": False,
        "default_integration_change": False,
        "previous_default_integration": None,
        "requires_network": bool(external),
        "network_required": bool(external),
        "risk_assessment": {
            "ambiguity_open": False, "cross_cutting_component_count": 1, "public_contract_change": False,
            "data_migration": False, "security_impact": False, "compliance_impact": False,
            "irreversible_operation": False, "artifact_conflict": False, "unknown_bug_cause": False,
            "evidence": [context_anchor or ("docs/spec-kit/START_HERE.md" if (root / PROJECT_PACKAGE / "START_HERE.md").is_file() else "GLOBAL_POLICY.md")],
        },
        "required_user_authorization": f"Approve exact plan {operation}",
        "risks_and_recovery": ["Revalidate all snapshots before apply", "Restore backups on failure"],
        "recovery_steps": ["Inspect the changed-file inventory", "Restore the plan backup", "Re-run status before retrying"],
        "plan_sha256": None,
    }
    plan["plan_sha256"] = plan_hash(plan)
    return plan


def save_plan(root: Path, plan: dict[str, Any]) -> Path:
    validate_plan_shape(plan)
    directory = root / RUNTIME_DIR / "plans"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{plan['plan_id']}.json"
    path.write_bytes(canonical_json(plan) + b"\n")
    return path


def bootstrap_mutations(root: Path, source: Path, context_anchor: str) -> list[dict[str, Any]]:
    preflight_writable(root, context_anchor)
    mapping = {
        "START_HERE.md": source / "governance/project/START_HERE.md",
        "POLICY.md": source / "governance/project/POLICY.md",
        "REFERENCE.md": source / "governance/project/REFERENCE.md",
        "OPERATING_PROTOCOL.md": source / "governance/project/OPERATING_PROTOCOL.md",
        "AGENT_ONBOARDING.md": source / "governance/project/AGENT_ONBOARDING.md",
        "LOCAL_OVERRIDES.md": source / "governance/project/LOCAL_OVERRIDES.template.md",
        "PROJECT_CONFIG.json": source / "governance/project/PROJECT_CONFIG.default.json",
        "ADAPTERS.json": source / "governance/project/ADAPTERS.template.json",
    }
    mutations = [file_mutation(root, f"{PROJECT_PACKAGE}/{name}", path.read_bytes()) for name, path in mapping.items()]
    manager_bytes = Path(__file__).read_bytes()
    mutations += [file_mutation(root, MANAGER_RELATIVE, manager_bytes)]
    # MANIFEST is generated from the exact bytes planned above.  This makes a
    # freshly bootstrapped project self-describing without requiring a second
    # mutable implementation or a post-apply hand edit.
    source_revision_value = source_revision(source)
    if source_revision_value is None:
        raise GovernanceError("governance bootstrap source has no verifiable revision", "CENTRAL_SOURCE_UNVERIFIED")
    reviewed_upstream = reviewed_upstream_revision(source)
    if reviewed_upstream is None:
        raise GovernanceError("governance bootstrap source has no reviewed upstream baseline", "CENTRAL_SOURCE_UNVERIFIED")
    tested_cli = cli_version() or "0.0.0"
    manifest_content = {
        "schema_version": 2,
        "governance_package_version": source_version(source, "GOVERNANCE_PACKAGE_VERSION", GOVERNANCE_PACKAGE_VERSION),
        "policy_version": source_version(source, "POLICY_VERSION", POLICY_VERSION),
        "reference_version": source_version(source, "REFERENCE_VERSION", REFERENCE_VERSION),
        "manager_version": source_version(source, "MANAGER_VERSION", MANAGER_VERSION),
        "source": {"repository": "https://github.com/jiezhengj/Spec-Kit-Reference", "revision": source_revision_value, "release": f"v{source_version(source, 'GOVERNANCE_PACKAGE_VERSION', GOVERNANCE_PACKAGE_VERSION)}", "reviewed_upstream_revision": reviewed_upstream},
        "specify_compatibility": cli_contract_metadata(reviewed_upstream, tested_cli),
        "paths": {
            "start_here": f"{PROJECT_PACKAGE}/START_HERE.md", "policy": f"{PROJECT_PACKAGE}/POLICY.md",
            "reference": f"{PROJECT_PACKAGE}/REFERENCE.md", "operating_protocol": f"{PROJECT_PACKAGE}/OPERATING_PROTOCOL.md",
            "onboarding": f"{PROJECT_PACKAGE}/AGENT_ONBOARDING.md", "local_overrides": f"{PROJECT_PACKAGE}/LOCAL_OVERRIDES.md",
            "project_config": f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json", "adapters": f"{PROJECT_PACKAGE}/ADAPTERS.json", "manager": MANAGER_RELATIVE,
        },
        "content_sha256": {},
        "project_owned_files": [f"{PROJECT_PACKAGE}/LOCAL_OVERRIDES.md", f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json", f"{PROJECT_PACKAGE}/ADAPTERS.json"],
        "project_owned_prefixes": [f"{PROJECT_PACKAGE}/features/"],
        "companion": {
            "version": "2.0.0",
            "extension": "governance-discovery",
            "preset": "tiny-model-tasks",
            "workflow": "governed-sdd",
            "installation_mode": "independent-native-components",
        },
        "portable_anchor": {"path": context_anchor, "marker_start": START_MARKER, "marker_end": END_MARKER},
    }
    for item in mutations:
        manifest_content["content_sha256"][item["path"]] = item["expected_new_sha256"]
    manifest_bytes = canonical_json(manifest_content) + b"\n"
    mutations.append(file_mutation(root, f"{PROJECT_PACKAGE}/MANIFEST.json", manifest_bytes))
    mutations += [file_mutation(
        root,
        context_anchor,
        marker_loader(source=source).encode("utf-8") + reference_update_loader(source).encode("utf-8"),
        "append-managed-bootstrap",
        protected_anchor=True,
    )]
    return mutations


def cmd_doctor(root: Path) -> dict[str, Any]:
    version = cli_version()
    result: dict[str, Any] = {
        "schema_version": 1, "project_root": str(root), "git": git_fingerprint(root),
        "specify_version": version, "specify_present": version is not None, "specify_project": (root / ".specify").is_dir(),
        "governance_package": (root / PROJECT_PACKAGE).is_dir(), "runtime_directory": (root / RUNTIME_DIR).is_dir(),
        "status": "READY" if (root / PROJECT_PACKAGE).is_dir() else "PROJECT_NOT_INITIALIZED",
    }
    package_errors = validate_project_package(root) if (root / PROJECT_PACKAGE).is_dir() else []
    if package_errors:
        result["status"] = "STATE_BROKEN"
        result["package_errors"] = package_errors
    compatibility = cli_compatibility(root)
    result["cli_compatibility"] = compatibility
    if compatibility not in {"READY", "CLI_MISSING", "CLI_CONTRACT_UNVERIFIED"}:
        result["status"] = compatibility
    if version is None:
        result["status"] = "CLI_MISSING"
        result["install_suggestion"] = "uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
    if (root / PROJECT_PACKAGE / "PROJECT_CONFIG.json").is_file():
        result["project_config"] = project_config(root)
        result["governance_generation"] = governance_generation(root)
        config = result["project_config"]
        result["workflow_profile"] = config.get("workflow_governance", {}).get("mode", "upstream-adaptive")
        result["strict_feature_governance"] = "OPT_IN" if result["workflow_profile"] == "governed-sdd" else "DISABLED_BY_DEFAULT"
        result["integration_status"] = integration_capability_status(root)
        result["constitution"] = constitution_status(root) if (root / ".specify").is_dir() else None
        if (root / ".specify").is_dir() and version is not None:
            companion = companion_status(root)
            result["companion"] = companion
            if result["workflow_profile"] == "governed-sdd" and companion.get("status") != "READY":
                result["status"] = companion.get("status", "COMPANION_CAPABILITY_UNAVAILABLE")
            elif companion.get("status") not in {"READY", "MIGRATION_REQUIRED"}:
                result.setdefault("warnings", []).append(
                    f"optional governed-sdd companion status: {companion.get('status')}"
                )
        result["official_extensions"] = official_extension_status(root)
    return result


def official_extension_status(root: Path) -> dict[str, Any]:
    """Inspect official optional extensions without making any mutation."""
    executable = shutil.which("specify")
    expected = ("assess", "bug")
    if not executable:
        return {"status": "CLI_MISSING", "missing": list(expected), "extensions": {}}
    help_result = subprocess.run(
        [executable, "extension", "--help"], cwd=root, text=True, encoding="utf-8", errors="replace",
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if help_result.returncode != 0:
        return {"status": "CAPABILITY_MISSING", "missing": list(expected), "extensions": {}, "error": "extension command unavailable"}
    list_result = subprocess.run(
        [executable, "extension", "list", "--json"], cwd=root, text=True, encoding="utf-8", errors="replace",
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if list_result.returncode != 0:
        list_result = subprocess.run(
            [executable, "extension", "list"], cwd=root, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
    output = list_result.stdout + list_result.stderr
    extensions = {
        item: bool(list_result.returncode == 0 and re.search(rf"(?<![A-Za-z0-9._-]){re.escape(item)}(?![A-Za-z0-9._-])", output))
        for item in expected
    }
    missing = [item for item, installed in extensions.items() if not installed]
    return {
        "status": "READY" if not missing else "CAPABILITY_MISSING",
        "missing": missing,
        "extensions": extensions,
        "inventory_sha256": sha256_bytes(output.encode("utf-8")),
    }


def integration_capability_status(root: Path) -> dict[str, Any]:
    """Report the active native integration without changing project state."""
    if not (root / ".specify").is_dir():
        return {"status": "PROJECT_NOT_INITIALIZED", "active_integration": None}
    try:
        data = command_status(root)
    except GovernanceError as exc:
        return {"status": exc.status or "STATE_BROKEN", "active_integration": None, "error": str(exc)}
    if not isinstance(data, dict):
        return {"status": "CLI_CONTRACT_UNVERIFIED", "active_integration": None}
    active = data.get("active_integration") or data.get("default_integration") or data.get("default")
    if isinstance(active, dict):
        active_key = active.get("key") or active.get("id") or active.get("name")
    else:
        active_key = active if isinstance(active, str) else None
    installed = data.get("installed_integrations")
    if not isinstance(installed, list):
        installed = []
    return {
        "status": "READY" if active_key else "CAPABILITY_MISSING",
        "active_integration": active_key,
        "installed_integrations": installed,
        "inventory_sha256": sha256_bytes(canonical_json(data)),
    }


def constitution_status(root: Path) -> dict[str, Any]:
    """Detect whether Feature work has a usable project Constitution."""
    path = root / ".specify/memory/constitution.md"
    if not path.is_file():
        return {"status": "MISSING", "path": ".specify/memory/constitution.md"}
    text = path.read_text(encoding="utf-8", errors="replace")
    lower = text.lower()
    placeholder_tokens = ("[project_name]", "[principle_", "[section_", "[project principle")
    placeholder = any(token in lower for token in placeholder_tokens)
    return {
        "status": "PLACEHOLDER" if placeholder else "READY",
        "path": ".specify/memory/constitution.md",
        "content_sha256": sha256_file(path),
        "feature_action": "RUN_SPECKIT_CONSTITUTION" if placeholder else None,
    }


def companion_status(root: Path) -> dict[str, Any]:
    generation = governance_generation(root)
    if generation != 2:
        return {"status": "MIGRATION_REQUIRED", "governance_generation": generation}
    executable = shutil.which("specify")
    if not executable:
        return {"status": "CLI_MISSING", "governance_generation": generation}
    capabilities: dict[str, Any] = {}
    expected = {"workflow": "governed-sdd", "preset": "tiny-model-tasks", "extension": "governance-discovery"}
    unavailable: list[str] = []
    missing: list[str] = []
    for capability, artifact_id in expected.items():
        help_result = subprocess.run(
            [executable, capability, "--help"], cwd=root, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if help_result.returncode != 0 or "list" not in (help_result.stdout + help_result.stderr):
            capabilities[capability] = {"available": False, "installed": False}
            unavailable.append(capability)
            continue
        list_result = subprocess.run(
            [executable, capability, "list", "--json"], cwd=root, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if list_result.returncode != 0:
            list_result = subprocess.run(
                [executable, capability, "list"], cwd=root, text=True, encoding="utf-8", errors="replace",
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
        output = list_result.stdout + list_result.stderr
        installed = list_result.returncode == 0 and re.search(rf"(?<![A-Za-z0-9._-]){re.escape(artifact_id)}(?![A-Za-z0-9._-])", output) is not None
        capabilities[capability] = {
            "available": list_result.returncode == 0,
            "installed": installed,
            "expected_id": artifact_id,
            "inventory_sha256": sha256_bytes(output.encode("utf-8")),
        }
        if list_result.returncode != 0:
            unavailable.append(capability)
        elif not installed:
            missing.append(capability)
    if unavailable:
        status = "COMPANION_CAPABILITY_UNAVAILABLE"
    elif missing:
        status = "COMPANION_NOT_INSTALLED"
    else:
        status = "READY"
    return {"status": status, "governance_generation": generation, "capabilities": capabilities, "missing": missing, "unavailable": unavailable}


def require_companion_cli_contract(root: Path) -> None:
    executable = shutil.which("specify")
    if not executable:
        raise GovernanceError("companion plans require an installed Specify CLI", "CLI_MISSING")
    expectations = {
        ("extension", "add"): ("--dev",),
        ("extension", "remove"): ("--force",),
        ("preset", "add"): ("--dev", "--priority"),
        ("preset", "remove"): ("preset_id",),
        ("workflow", "add"): ("--dev",),
        ("workflow", "remove"): ("workflow_id",),
    }
    for command, required_tokens in expectations.items():
        result = subprocess.run(
            [executable, *command, "--help"], cwd=root, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        output = result.stdout + result.stderr
        if result.returncode != 0 or any(token not in output for token in required_tokens):
            raise GovernanceError(
                f"installed Specify CLI lacks the required {' '.join(command)} contract",
                "COMPANION_CAPABILITY_UNAVAILABLE",
            )


def companion_allowed_prefixes(root: Path, additional: list[str] | None = None) -> list[str]:
    status = command_status(root)
    if status is None:
        raise GovernanceError("companion installation requires an initialized Spec Kit project", "PROJECT_NOT_INITIALIZED")
    prefixes = {".specify/", *runtime_reported_prefixes(status)}
    for value in additional or []:
        prefixes.add(safe_relative(root, value).as_posix().rstrip("/") + "/")
    return sorted(prefixes)


def companion_external_mutations(root: Path, snapshot: dict[str, Any], install: bool, additional_prefixes: list[str] | None = None) -> list[dict[str, Any]]:
    require_companion_cli_contract(root)
    prefixes = companion_allowed_prefixes(root, additional_prefixes)
    source = Path(snapshot["source_root"]) / COMPANION_ROOT
    components = list(COMPANION_COMPONENTS if install else reversed(COMPANION_COMPONENTS))
    result: list[dict[str, Any]] = []
    for kind, component_id, relative in components:
        component_source = str((source / relative).resolve())
        if install:
            if kind == "extension":
                argv = ["specify", "extension", "add", component_source, "--dev"]
                rollback = ["specify", "extension", "remove", component_id, "--force"]
            elif kind == "preset":
                argv = ["specify", "preset", "add", "--dev", component_source, "--priority", "5"]
                rollback = ["specify", "preset", "remove", component_id]
            else:
                argv = ["specify", "workflow", "add", component_source, "--dev"]
                rollback = ["specify", "workflow", "remove", component_id]
        else:
            if kind == "extension":
                argv = ["specify", "extension", "remove", component_id, "--force"]
                rollback = ["specify", "extension", "add", component_source, "--dev"]
            elif kind == "preset":
                argv = ["specify", "preset", "remove", component_id]
                rollback = ["specify", "preset", "add", "--dev", component_source, "--priority", "5"]
            else:
                argv = ["specify", "workflow", "remove", component_id]
                rollback = ["specify", "workflow", "add", component_source, "--dev"]
        result.append({
            "argv": argv,
            "working_directory": ".",
            "allowed_path_prefixes": prefixes,
            "rollback_argv": rollback,
            "pre_apply_snapshot": [],
            "postconditions": [],
            "changed_file_inventory": f"{RUNTIME_DIR}/plans/<plan-id>.changed.json",
        })
    return result


def resolution(root: Path, runtime_id: str, display_name: str | None, key: str | None) -> dict[str, Any]:
    env_runtime = os.environ.get("SPEC_KIT_CURRENT_AGENT_ID")
    env_key = os.environ.get("SPEC_KIT_CURRENT_INTEGRATION_KEY")
    if runtime_id and env_runtime and runtime_id != env_runtime:
        raise GovernanceError("runtime identity declarations conflict", "IDENTITY_CONFLICT")
    if key and env_key and key != env_key:
        raise GovernanceError("integration key declarations conflict", "IDENTITY_CONFLICT")
    runtime_id = runtime_id or env_runtime or ""
    key = key or env_key
    generic_attestation: dict[str, Any] | None = None
    generic_attestation_rel: str | None = None
    if not runtime_id:
        raise GovernanceError("runtime ID is required", "IDENTITY_UNKNOWN")
    if cli_version() is None:
        status = "CLI_MISSING"
    elif not key:
        status = "KEY_REQUIRED"
    elif key == "generic" and not (root / ".specify").is_dir():
        status = "UNSUPPORTED_INCOMPATIBLE"
    elif not (root / ".specify").is_dir():
        status = "PROJECT_NOT_INITIALIZED"
    else:
        current = command_status(root)
        installed = current.get("installed_integrations", []) if current else []
        keys = {item.get("key") if isinstance(item, dict) else item for item in installed}
        registry = adapters(root)
        active = next((item for item in registry.get("bindings", []) if item.get("runtime_id") == runtime_id and item.get("verification", {}).get("status") == "active"), None)
        if active and active.get("integration_key") == key:
            status = "READY_WITH_LIMITATIONS" if key == "generic" else "EXACT_NATIVE_INSTALLED"
        elif active and active.get("integration_key") != key:
            status = "NATIVE_CANDIDATE_REJECTED"
        elif key == "generic":
            status = "UNSUPPORTED_INCOMPATIBLE"
        else:
            status = "NATIVE_CANDIDATE_INSTALLED_UNVERIFIED" if key in keys else "NATIVE_CANDIDATE_NOT_INSTALLED"
    current = command_status(root) if (root / ".specify").is_dir() and cli_version() is not None else None
    installed = current.get("installed_integrations", []) if current else []
    registry = adapters(root) if (root / PROJECT_PACKAGE / "ADAPTERS.json").is_file() else {"bindings": [], "anchors": []}
    active = next((item for item in registry.get("bindings", []) if item.get("runtime_id") == runtime_id and item.get("verification", {}).get("status") == "active"), None)
    active_anchor = None
    if active:
        anchor_ids = set(active.get("anchor_ids", []))
        anchor = next((item for item in registry.get("anchors", []) if item.get("id") in anchor_ids), None)
        active_anchor = anchor.get("path") if anchor else None
    default_key = current.get("default_integration") if isinstance(current, dict) else None
    if isinstance(default_key, dict):
        default_key = default_key.get("key")
    installed_keys = {item.get("key") if isinstance(item, dict) else item for item in installed}
    response = {
        "schema_version": 1, "status": status, "project_root": str(root),
        "identity": {"runtime_id": runtime_id, "display_name": display_name, "source": "environment" if env_runtime and not display_name else "explicit-input"},
        "integration": {"key": key, "mode": ("explicit-generic-transition" if key == "generic" and status == "READY_WITH_LIMITATIONS" else ("native" if key and key != "generic" and status == "EXACT_NATIVE_INSTALLED" else None)), "installed": key in installed_keys, "default": key == default_key, "multi_install_safe": None},
        "context": {"anchor": active_anchor, "anchor_source": "active-binding" if active_anchor else None},
        "required_action": "provide-exact-key" if status == "KEY_REQUIRED" else ("reuse-active-binding" if status in {"EXACT_NATIVE_INSTALLED", "READY_WITH_LIMITATIONS"} else "review-and-plan"),
        "warnings": [], "next_safe_step": "Run plan-onboard only after reviewing this result",
    }
    if status == "CLI_MISSING":
        response["required_action"] = "install-with-user-approval"
        response["install_suggestion"] = "uv tool install specify-cli --from git+https://github.com/github/spec-kit.git"
    return response


def load_plan(root: Path, path: Path) -> dict[str, Any]:
    path = path.resolve()
    expected_dir = (root / RUNTIME_DIR / "plans").resolve()
    try:
        path.relative_to(expected_dir)
    except ValueError as exc:
        raise GovernanceError("plan is outside the runtime plan directory") from exc
    plan = read_json(path)
    if plan.get("plan_sha256") != plan_hash(plan):
        raise GovernanceError("plan_sha256 mismatch")
    if plan.get("schema_version") != SCHEMA_VERSION:
        raise GovernanceError("unsupported plan schema")
    validate_plan_shape(plan)
    return plan


def validate_apply(root: Path, plan: dict[str, Any], approved_id: str, approved_hash: str) -> None:
    if plan.get("plan_id") != approved_id or plan.get("plan_sha256") != approved_hash:
        raise GovernanceError("approval does not match exact plan")
    expires = datetime.fromisoformat(str(plan["expires_at"]).replace("Z", "+00:00"))
    if utc_now() > expires:
        raise GovernanceError("plan expired")
    current = git_fingerprint(root)
    for key in ("project_root_fingerprint", "git_head", "git_status_porcelain_sha256"):
        if plan.get(key) != current.get(key):
            raise GovernanceError(f"plan input changed: {key}")
    snapshot_paths = {
        "manifest_sha256": root / f"{PROJECT_PACKAGE}/MANIFEST.json",
        "project_config_sha256": root / f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json",
        "adapters_sha256": root / f"{PROJECT_PACKAGE}/ADAPTERS.json",
        "local_overrides_sha256": root / f"{PROJECT_PACKAGE}/LOCAL_OVERRIDES.md",
    }
    for field, target in snapshot_paths.items():
        expected = plan.get(field)
        actual = sha256_file(target) if target.is_file() else None
        if expected != actual:
            raise GovernanceError(f"plan input changed: {field}")
    planned_status_hash = plan.get("integration_status_sha256")
    current_status = command_status(root)
    current_status_hash = sha256_bytes(canonical_json(current_status)) if current_status is not None else None
    if planned_status_hash != current_status_hash:
        raise GovernanceError("plan input changed: integration_status_sha256")
    planned_cli_version = plan.get("specify_version")
    if planned_cli_version != cli_version():
        raise GovernanceError("plan input changed: specify_version")
    if plan.get("capability_inventory_before") != runtime_capability_inventory(root):
        raise GovernanceError("plan input changed: capability_inventory_before")
    if plan.get("source_snapshot") is not None:
        validate_strict_source_snapshot(plan["source_snapshot"])
    for item in plan.get("inputs", []):
        target = root / safe_relative(root, item["path"])
        if not target.is_file() or sha256_file(target) != item["sha256"]:
            raise GovernanceError(f"plan input changed: {item['path']}")
    validate_review_append_at_apply(root, plan)
    if plan.get("operation_type") == "plan-upgrade-governance-v2":
        record_items = [item for item in plan.get("manager_file_mutations", []) if re.fullmatch(r"docs/spec-kit/evidence/migration-[a-f0-9]+\.json", item.get("path", ""))]
        if len(record_items) != 1:
            raise GovernanceError("v2 upgrade plan must contain exactly one migration record", "STATE_BROKEN")
        try:
            record = json.loads(base64.b64decode(record_items[0]["content_b64"], validate=True))
        except (binascii.Error, ValueError, TypeError, json.JSONDecodeError) as exc:
            raise GovernanceError("v2 migration record payload is invalid", "STATE_BROKEN") from exc
        if migration_binding_sha256(plan, record) != record.get("plan_binding_sha256"):
            raise GovernanceError("v2 migration plan binding changed", "STATE_BROKEN")


def project_inventory(root: Path) -> dict[str, str]:
    """Hash durable files for external CLI scope verification."""
    result: dict[str, str] = {}
    for path in root.rglob("*"):
        if not path.is_file() or RUNTIME_DIR in path.relative_to(root).parts or ".git" in path.relative_to(root).parts:
            continue
        rel = path.relative_to(root).as_posix()
        result[rel] = sha256_file(path)
    return result


def tree_digest(root: Path, relative: str) -> str | None:
    target = root / relative
    if not target.exists():
        return None
    if target.is_file():
        return sha256_file(target)
    entries: list[bytes] = []
    for path in sorted((item for item in target.rglob("*") if item.is_file()), key=lambda item: item.relative_to(root).as_posix()):
        rel = path.relative_to(root).as_posix()
        entries.append(rel.encode("utf-8") + b"\0" + sha256_file(path).encode("ascii") + b"\n")
    return sha256_bytes(b"".join(entries))


def runtime_reported_prefixes(status: dict[str, Any] | None) -> set[str]:
    """Extract only path-like values explicitly reported by the installed runtime."""
    prefixes: set[str] = set()
    path_key = re.compile(r"(?:path|file|directory|dir|skill|command|managed)", re.IGNORECASE)

    def visit(value: Any, key: str = "") -> None:
        if isinstance(value, dict):
            for child_key, child in value.items():
                visit(child, str(child_key))
        elif isinstance(value, list):
            for child in value:
                visit(child, key)
        elif isinstance(value, str) and path_key.search(key):
            candidate = Path(value)
            if not candidate.is_absolute() and ".." not in candidate.parts and value not in {".", ""}:
                prefixes.add(candidate.as_posix().rstrip("/") + "/")

    visit(status)
    return prefixes


def runtime_capability_inventory(root: Path) -> dict[str, Any]:
    """Return a deterministic, path-relative inventory for upgrade gates.

    The installed CLI remains authoritative for runtime facts.  This function
    records only stable hashes and JSON status, never absolute paths, tokens,
    or environment variables.
    """
    status = command_status(root)
    status_copy = status if isinstance(status, dict) else None
    registry = adapters(root)
    anchor_paths = {
        item.get("path") for item in registry.get("anchors", [])
        if isinstance(item, dict) and isinstance(item.get("path"), str)
    }
    agent_artifacts = {
        rel: digest for rel, digest in project_inventory(root).items()
        if rel in anchor_paths or any(rel.startswith(prefix) for prefix in runtime_reported_prefixes(status_copy))
    }
    return {
        "schema_version": 1,
        "specify_project": (root / ".specify").is_dir(),
        "integration_status": status_copy,
        "integration_status_sha256": sha256_bytes(canonical_json(status_copy)) if status_copy is not None else None,
        "paths": {
            ".specify": tree_digest(root, ".specify"),
            "constitution": tree_digest(root, ".specify/memory/constitution.md"),
            "specs": tree_digest(root, "specs"),
            "agent_skills_or_commands": sha256_bytes(canonical_json(agent_artifacts)) if agent_artifacts else None,
            "project_governance": sha256_bytes(canonical_json({rel: digest for rel, digest in project_inventory(root).items() if rel.startswith("docs/spec-kit/") or rel == MANAGER_RELATIVE})) or None,
        },
        "default_integration": (status_copy or {}).get("default_integration") if status_copy else None,
        "installed_integrations": (status_copy or {}).get("installed_integrations", []) if status_copy else [],
    }


def init_rehearsal(root: Path, key: str, force: bool) -> dict[str, Any]:
    """Run the exact init argv in an isolated temporary directory.

    Rehearsal is plan-generation evidence only.  It never writes the real
    project and does not infer Agent identity from generated directories.
    """
    if key == "generic":
        raise GovernanceError("plan-init requires a concrete integration key", "UNSUPPORTED_INCOMPATIBLE")
    executable = shutil.which("specify")
    if not executable:
        raise GovernanceError("specify CLI is missing", "CLI_MISSING")
    argv = ["specify", "init", "--here"]
    if force:
        argv.append("--force")
    argv.extend(["--ignore-agent-tools", "--non-interactive", "--integration", key])
    with tempfile.TemporaryDirectory(prefix="spec-kit-rehearsal-") as directory:
        rehearsal_root = Path(directory)
        before = project_inventory(rehearsal_root)
        result = subprocess.run([executable, *argv[1:]], cwd=rehearsal_root, text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        after = project_inventory(rehearsal_root)
        if result.returncode != 0:
            raise GovernanceError("Spec Kit init rehearsal failed; inspect CLI output before retrying", "NATIVE_INSTALL_BLOCKED")
        changed = sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))
        if not changed:
            raise GovernanceError("Spec Kit init rehearsal produced no observable project artifacts", "STATE_BROKEN")
        return {
            "argv": argv,
            "cli_version": cli_version(),
            "force": force,
            "changed_files": changed,
            "changed_sha256": {path: after[path] for path in changed if path in after},
            "allowed_path_prefixes": sorted({path.split("/", 1)[0] + "/" for path in changed}),
            "stdout_sha256": sha256_bytes(result.stdout.encode("utf-8")),
            "stderr_sha256": sha256_bytes(result.stderr.encode("utf-8")),
        }


def has_durable_project_files(root: Path) -> bool:
    return bool(project_inventory(root))


def run_external_mutations(root: Path, plan: dict[str, Any]) -> list[str]:
    def rollback_external(item: dict[str, Any]) -> tuple[int | None, list[str]]:
        rollback_argv = item.get("rollback_argv")
        if not isinstance(rollback_argv, list) or not rollback_argv:
            return None, []
        if rollback_argv[0] != "specify" or any(not isinstance(value, str) or not value for value in rollback_argv):
            return None, []
        before_rollback = project_inventory(root)
        rollback_exec = shutil.which(rollback_argv[0]) or rollback_argv[0]
        result = subprocess.run([rollback_exec, *rollback_argv[1:]], cwd=root, text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        after_rollback = project_inventory(root)
        return result.returncode, sorted(path for path in set(before_rollback) | set(after_rollback) if before_rollback.get(path) != after_rollback.get(path))

    changed: list[str] = []
    completed: list[dict[str, Any]] = []
    transaction_before = project_inventory(root)
    for item in plan.get("external_cli_mutations", []):
        argv = item.get("argv")
        if not isinstance(argv, list) or not argv or any(not isinstance(value, str) or not value for value in argv):
            raise GovernanceError("external mutation argv must be a non-empty string list", "STATE_BROKEN")
        if argv[0] != "specify":
            raise GovernanceError("external mutation executable is not allowlisted", "UNSUPPORTED_INCOMPATIBLE")
        if "--force" in argv and plan.get("operation_type") not in {"plan-init", "plan-remove-governed-companion"}:
            raise GovernanceError("--force is forbidden for this operation", "UNSUPPORTED_INCOMPATIBLE")
        before = project_inventory(root)
        for snapshot in item.get("pre_execution_snapshot", []):
            rel = snapshot.get("path")
            if not isinstance(rel, str) or not safe_relative(root, rel).as_posix() == rel:
                raise GovernanceError("external pre-execution snapshot contains an unsafe path", "STATE_BROKEN")
            target = root / rel
            if not target.is_file() or sha256_file(target) != snapshot.get("sha256"):
                raise GovernanceError(f"external mutation input changed: {rel}", "RECOVERY_REQUIRED")
        exec_path = shutil.which(argv[0]) or argv[0]
        result = subprocess.run([exec_path, *argv[1:]], cwd=root, text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        after = project_inventory(root)
        delta = sorted(set(before) | set(after))
        changed_now = [path for path in delta if before.get(path) != after.get(path)]
        changed.extend(changed_now)
        if result.returncode != 0:
            rollback_argv = item.get("rollback_argv")
            rollback_results = [rollback_external(candidate) for candidate in [item, *reversed(completed)]]
            rollback_returncode = rollback_results[0][0] if rollback_results else None
            rollback_changed = [path for _code, paths in rollback_results for path in paths]
            report = root / RUNTIME_DIR / "plans" / f"{plan['plan_id']}.external-failure.json"
            report.parent.mkdir(parents=True, exist_ok=True)
            restored = project_inventory(root) == transaction_before
            report.write_bytes(canonical_json({"argv": argv, "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr, "changed": changed_now, "rollback_argv": rollback_argv, "rollback_returncode": rollback_returncode, "rollback_changed": rollback_changed, "restored": restored}) + b"\n")
            status = "NATIVE_INSTALL_BLOCKED" if restored and plan.get("required_native_key") and plan.get("required_native_key") != "generic" else "RECOVERY_REQUIRED"
            raise GovernanceError(f"external CLI failed; recovery review required: {' '.join(argv)}", status)
        allowed = item.get("allowed_path_prefixes", [])
        def within_allowed(path: str, prefix: str) -> bool:
            normalized = prefix.rstrip("/")
            return path == normalized or path.startswith(normalized + "/")

        unexpected = [path for path in changed_now if allowed and not any(within_allowed(path, prefix) for prefix in allowed)]
        if unexpected:
            rollback_argv = item.get("rollback_argv")
            rollback_results = [rollback_external(candidate) for candidate in [item, *reversed(completed)]]
            rollback_returncode = rollback_results[0][0] if rollback_results else None
            rollback_changed = [path for _code, paths in rollback_results for path in paths]
            restored = project_inventory(root) == transaction_before
            report = root / RUNTIME_DIR / "plans" / f"{plan['plan_id']}.external-scope-failure.json"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_bytes(canonical_json({"argv": argv, "unexpected": unexpected, "changed": changed_now, "rollback_argv": rollback_argv, "rollback_returncode": rollback_returncode, "rollback_changed": rollback_changed, "restored": restored}) + b"\n")
            raise GovernanceError(f"external CLI changed files outside approved scope: {unexpected}", "STATE_BROKEN" if restored else "RECOVERY_REQUIRED")
        inventory_path = root / RUNTIME_DIR / "plans" / f"{plan['plan_id']}.changed.json"
        inventory_path.parent.mkdir(parents=True, exist_ok=True)
        inventory_path.write_bytes(canonical_json({"argv": argv, "changed": {path: after.get(path) for path in changed_now}}) + b"\n")
        completed.append(item)
    if plan.get("operation_type") in {"plan-install-governed-companion", "plan-remove-governed-companion"}:
        observed = companion_status(root)
        expected = "READY" if plan["operation_type"] == "plan-install-governed-companion" else "COMPANION_NOT_INSTALLED"
        removed_cleanly = expected != "COMPANION_NOT_INSTALLED" or (
            observed.get("status") == "COMPANION_NOT_INSTALLED"
            and not observed.get("unavailable")
            and set(observed.get("missing", [])) == {"extension", "preset", "workflow"}
        )
        if observed.get("status") != expected or not removed_cleanly:
            rollback_results = [rollback_external(candidate) for candidate in reversed(completed)]
            restored = project_inventory(root) == transaction_before
            report = root / RUNTIME_DIR / "plans" / f"{plan['plan_id']}.companion-postcondition-failure.json"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_bytes(canonical_json({"expected": expected, "observed": observed, "rollback_results": rollback_results, "restored": restored}) + b"\n")
            raise GovernanceError("governed companion postcondition failed", "STATE_BROKEN" if restored else "RECOVERY_REQUIRED")
    return changed


def apply_manager_mutations(root: Path, plan: dict[str, Any]) -> list[str]:
    backup_dir = root / RUNTIME_DIR / "backups" / plan["plan_id"]
    backup_dir.mkdir(parents=True, exist_ok=True)
    changed: list[str] = []
    originals: dict[str, bytes | None] = {}
    try:
        for item in plan.get("manager_file_mutations", []):
            rel = item["path"]
            safe_relative(root, rel)
            target = root / rel
            context_anchor = plan.get("context_anchor")
            if not reference_owned_mutation(rel, context_anchor):
                raise GovernanceError(
                    "manager mutations may target only Reference-owned additions or the managed context-anchor loader",
                    "REFERENCE_OWNERSHIP_VIOLATION",
                )
            if item.get("protected_anchor") is True and rel != context_anchor:
                raise GovernanceError("protected anchor mutation does not match the declared context anchor", "STATE_BROKEN")
            if rel == context_anchor and (item.get("action") not in MANAGED_ANCHOR_ACTIONS or item.get("protected_anchor") is not True):
                raise GovernanceError("the declared project rules anchor accepts only approved managed-block appends", "PROJECT_RULES_PROTECTED")
            if target.is_symlink():
                raise GovernanceError(f"refusing to mutate symlink: {rel}", "STATE_BROKEN")
            old = target.read_bytes() if target.is_file() else None
            originals[rel] = old
            if old is not None:
                backup = backup_dir / (rel.replace("/", "__") + ".bak")
                backup.write_bytes(old)
            try:
                content = base64.b64decode(item["content_b64"], validate=True)
            except (binascii.Error, ValueError, TypeError) as exc:
                raise GovernanceError(f"manager mutation has invalid content: {rel}", "STATE_BROKEN") from exc
            target.parent.mkdir(parents=True, exist_ok=True)
            if item.get("action") in MANAGED_ANCHOR_ACTIONS and target.exists():
                action = item.get("action")
                if action == "append-managed-loader":
                    content = append_loader(target.read_bytes(), content)
                elif action == "append-managed-update-reminder":
                    content = append_update_reminder(target.read_bytes(), content)
                elif action == "append-managed-reference-update-check":
                    content = append_reference_update_check(target.read_bytes(), content)
                else:
                    content = append_bootstrap_blocks(target.read_bytes(), content)
            if sha256_bytes(content) != item.get("expected_new_sha256"):
                raise GovernanceError(f"manager mutation target checksum mismatch: {rel}", "STATE_BROKEN")
            temp = target.with_name(f".{target.name}.{plan['plan_id']}.tmp")
            temp.write_bytes(content)
            with temp.open("r+b") as handle:
                try:
                    os.fsync(handle.fileno())
                except OSError:
                    pass
            os.replace(temp, target)
            os.chmod(target, item.get("mode", 0o644))
            try:
                directory_fd = os.open(str(target.parent), os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            except OSError:
                pass
            changed.append(rel)
    except GovernanceError:
        for rel, old in originals.items():
            target = root / rel
            try:
                if old is None:
                    if target.exists() and target.is_file():
                        target.unlink()
                else:
                    target.write_bytes(old)
            except OSError as recovery_error:
                raise GovernanceError(f"manager mutation failed and recovery failed: {rel}", "RECOVERY_REQUIRED") from recovery_error
        raise
    except Exception as exc:
        for rel, old in originals.items():
            target = root / rel
            try:
                if old is None:
                    if target.exists() and target.is_file():
                        target.unlink()
                else:
                    target.write_bytes(old)
            except OSError:
                raise GovernanceError(f"manager mutation failed and recovery failed: {rel}", "RECOVERY_REQUIRED") from exc
        raise GovernanceError(f"manager mutation failed and was restored: {exc}", "RECOVERY_REQUIRED") from exc
    return changed


def cmd_apply(root: Path, args: argparse.Namespace) -> dict[str, Any]:
    plan = load_plan(root, Path(args.plan))
    validate_apply(root, plan, args.approve_plan_id, args.approve_plan_sha256)
    # External Spec Kit mutations run before the project-owned configuration
    # commit.  If the CLI fails, no governance config is advanced; if the
    # subsequent local commit fails, the result is explicitly recovery-needed.
    changed = run_external_mutations(root, plan)
    try:
        changed.extend(apply_manager_mutations(root, plan))
    except Exception as exc:
        raise GovernanceError(f"external mutation succeeded but governance commit failed: {exc}", "RECOVERY_REQUIRED") from exc
    after_path = root / RUNTIME_DIR / "plans" / f"{plan['plan_id']}.capability-after.json"
    after_path.parent.mkdir(parents=True, exist_ok=True)
    after_path.write_bytes(canonical_json(runtime_capability_inventory(root)) + b"\n")
    return {"status": "applied", "plan_id": plan["plan_id"], "changed": changed}


def cmd_auto_upgrade(root: Path, args: argparse.Namespace) -> dict[str, Any]:
    """Synchronize the Reference package without a project-owner approval gate.

    The operation still creates the same hash-bound plan and runs the same
    validation/recovery path.  Automatic means that the current Agent may
    authorize the exact generated plan as part of session bootstrap; it does
    not mean that arbitrary project files or upstream Spec artifacts are
    overwritten.
    """
    planned = create_plan_command(root, "plan-upgrade", args)
    apply_args = argparse.Namespace(
        plan=planned["path"],
        approve_plan_id=planned["plan_id"],
        approve_plan_sha256=planned["plan_sha256"],
    )
    applied = cmd_apply(root, apply_args)
    return {
        "status": "AUTO_UPGRADED",
        "plan_id": applied["plan_id"],
        "changed": applied["changed"],
        "owner_approval_required": False,
    }


def cmd_install_official_extension(root: Path, args: argparse.Namespace) -> dict[str, Any]:
    """Install one official extension after the Agent has obtained consent."""
    extension_id = getattr(args, "extension_id", None)
    if extension_id not in {"assess", "bug"}:
        raise GovernanceError("only the official assess and bug extensions are supported", "CAPABILITY_MISSING")
    before = official_extension_status(root)
    if before.get("status") == "CLI_MISSING":
        return {"status": "CLI_MISSING", "required_extension": extension_id, "next_safe_step": "ask the user to install specify"}
    if before.get("extensions", {}).get(extension_id) is True:
        return {"status": "READY", "extension": extension_id, "changed": []}
    planned = create_plan_command(root, "plan-extension-install", args)
    applied = cmd_apply(root, argparse.Namespace(
        plan=planned["path"], approve_plan_id=planned["plan_id"], approve_plan_sha256=planned["plan_sha256"],
    ))
    after = official_extension_status(root)
    if after.get("extensions", {}).get(extension_id) is not True:
        raise GovernanceError(f"official extension was not visible after installation: {extension_id}", "CAPABILITY_MISSING")
    return {"status": "INSTALLED", "extension": extension_id, "plan_id": applied["plan_id"], "changed": applied["changed"]}


def create_plan_command(root: Path, operation: str, args: argparse.Namespace) -> dict[str, Any]:
    if operation != "plan-governance-bootstrap" and operation not in {"plan-upgrade", "plan-rollback", "plan-activate-binding", "plan-record-artifact-review", "plan-upgrade-governance-v2", "plan-rollback-governance-v2"}:
        compatibility = cli_compatibility(root)
        if compatibility not in {"READY", "CLI_CONTRACT_UNVERIFIED"}:
            raise GovernanceError(f"Spec Kit CLI is not eligible for mutation: {compatibility}", compatibility)
    env_runtime = os.environ.get("SPEC_KIT_CURRENT_AGENT_ID")
    if getattr(args, "runtime_id", None) and env_runtime and args.runtime_id != env_runtime:
        raise GovernanceError("runtime identity declarations conflict", "IDENTITY_CONFLICT")
    runtime_id = getattr(args, "runtime_id", None) or env_runtime
    identity = {"runtime_id": runtime_id, "display_name": getattr(args, "display_name", None), "source": "environment" if env_runtime and not getattr(args, "runtime_id", None) else "explicit-input"} if runtime_id else {}
    key = getattr(args, "integration_key", None)
    env_key = os.environ.get("SPEC_KIT_CURRENT_INTEGRATION_KEY")
    if key and env_key and key != env_key:
        raise GovernanceError("integration key declarations conflict", "IDENTITY_CONFLICT")
    key = key or env_key
    requested_anchor = getattr(args, "context_anchor", None)
    env_anchor = os.environ.get("SPEC_KIT_CONTEXT_ANCHOR")
    if requested_anchor and env_anchor and requested_anchor != env_anchor:
        raise GovernanceError("context anchor declarations conflict", "IDENTITY_CONFLICT")
    context_anchor = requested_anchor or env_anchor
    if context_anchor:
        context_anchor = safe_relative(root, context_anchor).as_posix()
    delivery_mode = getattr(args, "delivery_mode", "loader")
    anchor_evidence: list[dict[str, Any]] = []
    generic_attestation: dict[str, Any] | None = None
    generic_attestation_rel: str | None = None
    strict_snapshot: dict[str, Any] | None = None
    fixed_plan_id: str | None = None
    companion_external: list[dict[str, Any]] | None = None
    if operation == "plan-onboard":
        if not runtime_id:
            raise GovernanceError("runtime ID is required for onboarding", "IDENTITY_UNKNOWN")
        if not context_anchor:
            raise GovernanceError("context anchor is required for onboarding", "CONTEXT_ANCHOR_UNKNOWN")
        if not (root / ".specify").is_dir():
            raise GovernanceError("onboarding requires an existing .specify project; run plan-init first", "PROJECT_NOT_INITIALIZED")
        if not (root / PROJECT_PACKAGE / "PROJECT_CONFIG.json").is_file():
            raise GovernanceError("project governance package is missing; run plan-governance-bootstrap first", "PROJECT_NOT_INITIALIZED")
        if not getattr(args, "anchor_evidence", None):
            raise GovernanceError("onboarding requires anchor compatibility evidence", "CONTEXT_ANCHOR_UNKNOWN")
        anchor_evidence_path = root / safe_relative(root, args.anchor_evidence)
        if not anchor_evidence_path.is_file():
            raise GovernanceError("anchor compatibility evidence is missing", "CONTEXT_ANCHOR_UNKNOWN")
        anchor_record = read_json(anchor_evidence_path)
        evidence_hash = sha256_file(anchor_evidence_path)
        if anchor_record.get("anchor_path") not in {None, context_anchor}:
            raise GovernanceError("anchor compatibility evidence targets a different path", "CONTEXT_ANCHOR_UNKNOWN")
        if anchor_record.get("format") not in {None, "markdown", "text"}:
            raise GovernanceError("anchor format is unsupported", "ANCHOR_FORMAT_UNSUPPORTED")
        anchor_evidence = [{"source": args.anchor_evidence, "content_sha256": evidence_hash, "review_conclusion": str(anchor_record.get("review_conclusion", "reviewed"))}]
        if delivery_mode not in {"loader", "materialized"}:
            raise GovernanceError("unsupported delivery mode", "UNSUPPORTED_INCOMPATIBLE")
        if delivery_mode == "materialized":
            failure_rel = getattr(args, "loader_failure_evidence", None)
            if not failure_rel:
                raise GovernanceError("materialized delivery requires Loader failure evidence", "CONTEXT_ANCHOR_UNKNOWN")
            failure_path = root / safe_relative(root, failure_rel)
            if not failure_path.is_file():
                raise GovernanceError("Loader failure evidence is missing", "CONTEXT_ANCHOR_UNKNOWN")
            failure_record = read_json(failure_path)
            if failure_record.get("runtime_id") != runtime_id or failure_record.get("integration_key") != key or failure_record.get("fresh_session") is not True or failure_record.get("loader_failure") is not True:
                raise GovernanceError("Loader failure evidence does not match runtime and key", "CONTEXT_ANCHOR_UNKNOWN")
        elif getattr(args, "loader_failure_evidence", None):
            raise GovernanceError("Loader failure evidence is only valid for materialized delivery", "UNSUPPORTED_INCOMPATIBLE")
    if operation == "plan-activate-binding":
        if not runtime_id:
            raise GovernanceError("runtime ID is required to activate a binding", "IDENTITY_UNKNOWN")
        if not key:
            raise GovernanceError("integration key is required to activate a binding", "KEY_REQUIRED")
        if not getattr(args, "verification_evidence", None):
            raise GovernanceError("fresh-session verification evidence is required", "CONTEXT_ANCHOR_UNKNOWN")
    if key == "generic" and operation == "plan-onboard":
        # Generic is never a permission fallback.  It is an explicit,
        # separately attested transition and therefore cannot be planned from
        # the ordinary native onboarding path.
        config = project_config(root) or {}
        if config.get("generic", {}).get("policy") != "explicit-approval-required":
            raise GovernanceError("generic transition is disabled by project configuration", "UNSUPPORTED_INCOMPATIBLE")
        attestation = getattr(args, "attestation", None)
        if not attestation:
            raise GovernanceError("generic transition requires an explicit native-absence attestation", "UNSUPPORTED_INCOMPATIBLE")
        evidence = root / safe_relative(root, attestation)
        if not evidence.is_file():
            raise GovernanceError("native-absence attestation does not exist", "UNSUPPORTED_INCOMPATIBLE")
        record = read_json(evidence)
        if record.get("runtime_id") != runtime_id or record.get("conclusion") != "no-native-integration-found-for-runtime" or record.get("reviewed_by_current_operator") is not True:
            raise GovernanceError("native-absence attestation does not match runtime identity", "UNSUPPORTED_INCOMPATIBLE")
        observed_version = cli_version()
        if not observed_version or record.get("specify_version") != observed_version:
            raise GovernanceError("native-absence attestation does not match the installed CLI version", "UNSUPPORTED_INCOMPATIBLE")
        catalog_rel = record.get("catalog_evidence")
        catalog_hash = record.get("catalog_evidence_sha256")
        if not isinstance(catalog_rel, str) or not isinstance(catalog_hash, str):
            raise GovernanceError("generic transition requires immutable catalog evidence", "UNSUPPORTED_INCOMPATIBLE")
        catalog_path = root / safe_relative(root, catalog_rel)
        if not catalog_path.is_file() or sha256_file(catalog_path) != catalog_hash:
            raise GovernanceError("generic catalog evidence hash is invalid", "UNSUPPORTED_INCOMPATIBLE")
        current = command_status(root) or {}
        installed = current.get("installed_integrations", [])
        if installed:
            raise GovernanceError("generic transition requires an empty installed integration set", "INTEGRATION_CONFLICT")
        generic_attestation = record
        generic_attestation_rel = attestation
        if operation != "plan-onboard" or not getattr(args, "commands_dir", None):
            raise GovernanceError("generic transition requires plan-onboard and an explicit commands directory", "UNSUPPORTED_INCOMPATIBLE")
        safe_relative(root, args.commands_dir)
    review_event: dict[str, Any] | None = None
    if operation == "plan-record-artifact-review":
        mutation, review_event = artifact_review_mutation(root, args)
        mutations = [mutation]
    elif operation == "plan-governance-bootstrap":
        if not context_anchor:
            raise GovernanceError(
                "bootstrap requires the current Agent runtime or user to provide the project context anchor",
                "CONTEXT_ANCHOR_UNKNOWN",
            )
        mutations = bootstrap_mutations(root, source_root(getattr(args, "source", None)), context_anchor)
    elif operation == "plan-install-update-reminder":
        if not (root / ".specify").is_dir():
            raise GovernanceError("update reminder requires an existing .specify project", "PROJECT_NOT_INITIALIZED")
        if not context_anchor:
            raise GovernanceError("update reminder requires the exact runtime-selected context anchor", "CONTEXT_ANCHOR_UNKNOWN")
        anchor_path = root / context_anchor
        if not anchor_path.is_file():
            raise GovernanceError("update reminder requires an existing context anchor; the supplied path is not a file", "CONTEXT_ANCHOR_UNKNOWN")
        preflight_writable(root, context_anchor)
        mutations = [file_mutation(
            root, context_anchor, update_reminder_loader().encode("utf-8"),
            "append-managed-update-reminder", protected_anchor=True,
        )]
    elif operation == "plan-upgrade-governance-v2":
        strict_snapshot = strict_source_snapshot(getattr(args, "source", None))
        fixed_plan_id = uuid.uuid4().hex
        mutations, _migration_rel = governance_v2_upgrade_mutations(root, strict_snapshot, fixed_plan_id)
    elif operation == "plan-rollback-governance-v2":
        mutations = governance_v2_rollback_mutations(root, args.migration_record)
    elif operation in {"plan-install-governed-companion", "plan-remove-governed-companion"}:
        require_governance_v2(root)
        strict_snapshot = strict_source_snapshot(getattr(args, "source", None))
        status = companion_status(root)
        if operation == "plan-install-governed-companion" and status.get("status") == "READY":
            raise GovernanceError("governed companion is already installed", "STATE_BROKEN")
        if operation == "plan-install-governed-companion" and status.get("status") == "COMPANION_CAPABILITY_UNAVAILABLE":
            raise GovernanceError("installed CLI cannot install the governed companion", "COMPANION_CAPABILITY_UNAVAILABLE")
        if operation == "plan-remove-governed-companion" and status.get("status") != "READY":
            raise GovernanceError("governed companion is not fully installed", "COMPANION_NOT_INSTALLED")
        companion_external = companion_external_mutations(
            root,
            strict_snapshot,
            operation == "plan-install-governed-companion",
            getattr(args, "allowed_path_prefix", None),
        )
        mutations = []
    else:
        mutations = []
    rehearsal = None
    if operation == "plan-init":
        if not key:
            raise GovernanceError("integration key is required", "KEY_REQUIRED")
        if not runtime_id:
            raise GovernanceError("ask the user for the current Agent runtime identity before initialization", "IDENTITY_UNKNOWN")
        if not context_anchor:
            raise GovernanceError("the current Agent runtime must provide its project context anchor", "CONTEXT_ANCHOR_UNKNOWN")
        documentation_language = getattr(args, "documentation_language", None)
        if not documentation_language:
            raise GovernanceError(
                "ask the user which language future project documentation should use, then pass --documentation-language",
                "DOCUMENTATION_LANGUAGE_REQUIRED",
            )
        if not valid_language_tag(documentation_language):
            raise GovernanceError("documentation language must be a valid BCP 47 tag", "DOCUMENTATION_LANGUAGE_INVALID")
        config_path = root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"
        manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
        if not config_path.is_file() or not manifest_path.is_file():
            raise GovernanceError("plan-init requires the project governance bootstrap package", "PROJECT_NOT_INITIALIZED")
        manifest_anchor = read_json(manifest_path).get("portable_anchor", {}).get("path")
        if manifest_anchor != context_anchor:
            raise GovernanceError("plan-init context anchor does not match the bootstrapped runtime anchor", "CONTEXT_ANCHOR_UNKNOWN")
        preflight_writable(root, context_anchor)
        rehearsal = init_rehearsal(root, key, bool(args.force))
    if operation in {"plan-upgrade", "plan-rollback"} and not key:
        if not args.source:
            raise GovernanceError("an explicit staged governance source is required", "CENTRAL_SOURCE_UNVERIFIED")
        package_manifest = root / PROJECT_PACKAGE / "MANIFEST.json"
        if not package_manifest.is_file():
            raise GovernanceError("governance upgrade requires an existing project governance package", "PROJECT_NOT_INITIALIZED")
        manifest_anchor = read_json(package_manifest).get("portable_anchor", {}).get("path")
        if context_anchor and manifest_anchor and context_anchor != manifest_anchor:
            raise GovernanceError("context anchor does not match the bootstrapped project manifest", "CONTEXT_ANCHOR_UNKNOWN")
        context_anchor = context_anchor or manifest_anchor
        if not isinstance(context_anchor, str) or not context_anchor:
            raise GovernanceError("governance upgrade requires the manifest's exact context anchor", "CONTEXT_ANCHOR_UNKNOWN")
        if not (root / context_anchor).is_file():
            raise GovernanceError("governance upgrade requires the existing context anchor", "CONTEXT_ANCHOR_UNKNOWN")
        mutations.extend(governance_update_mutations(root, source_root(args.source), context_anchor))
    if operation == "plan-activate-binding":
        mutations.extend(activate_binding_mutations(root, runtime_id, key, args.verification_evidence, args.delivery_mode))
    if operation == "plan-onboard" and key:
        evidence_rel = f"{PROJECT_PACKAGE}/evidence/onboard-{uuid.uuid4().hex}.json"
        onboarding, preflight, _anchor_id = onboarding_mutations(
            root, runtime_id, args.display_name or runtime_id, key, context_anchor, evidence_rel,
            integration_mode="explicit-generic-transition" if key == "generic" else "native",
            attestation_hash=sha256_file(root / safe_relative(root, args.attestation)) if key == "generic" and args.attestation else None,
            attestation_rel=generic_attestation_rel,
            commands_dir=args.commands_dir if key == "generic" else None,
            delivery_mode=delivery_mode,
        )
        mutations.extend(onboarding)
    if operation == "plan-init" and key and key != "generic":
        if has_durable_project_files(root) and not args.force:
            raise GovernanceError("non-empty brownfield init requires the dedicated --force rehearsal plan", "NATIVE_INSTALL_BLOCKED")
        if args.force and not has_durable_project_files(root):
            raise GovernanceError("--force is reserved for non-empty brownfield init", "UNSUPPORTED_INCOMPATIBLE")
        config_path = root / PROJECT_PACKAGE / "PROJECT_CONFIG.json"
        if config_path.is_file():
            config = project_config(root) or {}
            config.setdefault("default_integration", {})["key"] = key
            config["documentation"] = {
                "language_tag": documentation_language,
                "selection_source": "explicit-user-selection",
                "scope": "new-and-substantively-rewritten-project-documentation",
            }
            config_bytes = canonical_json(config) + b"\n"
            config_mutation = file_mutation(root, f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json", config_bytes, "replace")
            mutations.append(config_mutation)
            manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
            if manifest_path.is_file():
                manifest = read_json(manifest_path)
                manifest.setdefault("content_sha256", {})[f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json"] = config_mutation["expected_new_sha256"]
                mutations.append(file_mutation(root, f"{PROJECT_PACKAGE}/MANIFEST.json", canonical_json(manifest) + b"\n", "replace"))
            mutations.append(file_mutation(
                root, context_anchor, marker_loader(documentation_language).encode("utf-8"),
                "append-managed-loader", protected_anchor=True,
            ))
    if companion_external is not None:
        external = companion_external
    elif operation in {"plan-onboard", "plan-init", "plan-extension-install", "plan-default-change", "plan-upgrade", "plan-rollback"} and operation != "plan-governance-bootstrap":
        if operation == "plan-onboard" and not key:
            raise GovernanceError("integration key is required", "KEY_REQUIRED")
        argv: list[str] = []
        if operation == "plan-init":
            if not key:
                raise GovernanceError("integration key is required", "KEY_REQUIRED")
            argv = ["specify", "init", "--here", "--ignore-agent-tools", "--non-interactive", "--integration", key]
            if args.force:
                argv.insert(3, "--force")
        elif operation == "plan-onboard":
            argv = ["specify", "integration", "install", key] if key else []
            if key == "generic":
                argv.append(f"--integration-options=--commands-dir {args.commands_dir}")
        elif operation == "plan-extension-install":
            extension_id = getattr(args, "extension_id", None)
            argv = ["specify", "extension", "add", extension_id or args.extension_directory]
        elif operation == "plan-default-change":
            if not (root / ".specify").is_dir():
                raise GovernanceError("default change requires an existing .specify project", "PROJECT_NOT_INITIALIZED")
            config = project_config(root) or {}
            if config.get("default_integration", {}).get("allow_change") is not True:
                raise GovernanceError("default change is not enabled", "DEFAULT_CHANGE_FORBIDDEN")
            argv = ["specify", "integration", "use", key]
            if not key:
                raise GovernanceError("default change requires an exact integration key", "KEY_REQUIRED")
            config["default_integration"]["key"] = key
            config["default_integration"]["allow_change"] = False
            config_mutation = file_mutation(root, f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json", canonical_json(config) + b"\n", "replace")
            mutations.append(config_mutation)
            manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
            if manifest_path.is_file():
                manifest = read_json(manifest_path)
                manifest.setdefault("content_sha256", {})[f"{PROJECT_PACKAGE}/PROJECT_CONFIG.json"] = config_mutation["expected_new_sha256"]
                mutations.append(file_mutation(root, f"{PROJECT_PACKAGE}/MANIFEST.json", canonical_json(manifest) + b"\n", "replace"))
        elif operation == "plan-upgrade":
            argv = ["specify", "integration", "upgrade", key] if key else []
        elif operation == "plan-rollback":
            argv = []
        rollback_argv: list[str] = []
        if operation == "plan-default-change":
            current = command_status(root) or {}
            previous = current.get("default_integration") or current.get("default")
            if isinstance(previous, dict):
                previous = previous.get("key")
            if isinstance(previous, str) and previous:
                rollback_argv = ["specify", "integration", "use", previous]
        allowed_prefixes = [".specify/"]
        if operation == "plan-extension-install":
            allowed_prefixes.extend(sorted(runtime_reported_prefixes(command_status(root))))
        for prefix in getattr(args, "allowed_path_prefix", []) or []:
            allowed_prefixes.append(safe_relative(root, prefix).as_posix().rstrip("/") + "/")
        if operation == "plan-init" and rehearsal:
            allowed_prefixes = list(rehearsal.get("allowed_path_prefixes", allowed_prefixes))
        if operation == "plan-onboard" and key == "generic":
            allowed_prefixes.append(args.commands_dir.rstrip("/") + "/")
        external = [] if not argv else [{"argv": argv, "working_directory": ".", "allowed_path_prefixes": allowed_prefixes, "rollback_argv": rollback_argv, "pre_apply_snapshot": [], "postconditions": [], "changed_file_inventory": f"{RUNTIME_DIR}/plans/<plan-id>.changed.json"}]
    else:
        external = []
    if external:
        inventory = project_inventory(root)
        for index, item in enumerate(external):
            prefixes = item.get("allowed_path_prefixes", [])
            snapshot = [
                {"path": rel, "sha256": digest}
                for rel, digest in sorted(inventory.items())
                if any(rel == prefix.rstrip("/") or rel.startswith(prefix.rstrip("/") + "/") for prefix in prefixes)
            ]
            item["cli_version"] = cli_version()
            item["pre_execution_snapshot"] = snapshot if index == 0 else []
            item["expected_status_postconditions"] = ["integration status remains JSON-readable when .specify exists"]
            item["expected_managed_file_postconditions"] = []
            item["failure_recovery_protocol"] = "Preserve runtime evidence; run rollback_argv when supplied; return RECOVERY_REQUIRED if inventory is not restored."
            item["changed_file_inventory_path"] = f"{RUNTIME_DIR}/plans/<plan-id>.changed.json"
    plan = make_plan(
        root, operation, mutations, external=external, identity=identity, claimed_key=key,
        context_anchor=context_anchor,
        write_preflight=[{"path": context_anchor, "writable": True, "evidence": "preflight_writable"}] if context_anchor else [],
        anchor_compatibility_evidence=anchor_evidence,
        rehearsal=rehearsal,
        documentation_language=getattr(args, "documentation_language", None) if operation == "plan-init" else None,
        plan_id=fixed_plan_id,
        source_snapshot=strict_snapshot,
    )
    path = save_plan(root, plan)
    response = {"status": "plan-created", "plan_id": plan["plan_id"], "plan_sha256": plan["plan_sha256"], "path": str(path), "operation_type": operation}
    if review_event is not None:
        response["review_event"] = review_event
    return response


def dispatch(root: Path, args: argparse.Namespace) -> dict[str, Any]:
    command = args.command
    if command == "doctor":
        return cmd_doctor(root)
    if command == "resolve-agent":
        return resolution(root, args.runtime_id, args.display_name, args.integration_key)
    if command == "apply-plan":
        return cmd_apply(root, args)
    if command == "check-companion-status":
        return companion_status(root)
    if command == "check-capabilities":
        cli_status = cli_compatibility(root)
        integration = integration_capability_status(root) if cli_status in {"READY", "CLI_CONTRACT_UNVERIFIED"} else {"status": cli_status, "active_integration": None}
        extensions = official_extension_status(root)
        missing = extensions.get("missing", []) if isinstance(extensions, dict) else []
        constitution = constitution_status(root)
        workflow_actions: list[str] = []
        if cli_status == "CLI_MISSING":
            required_action = "ASK_USER_TO_INSTALL_SPECIFY"
            workflow_actions.append(required_action)
        elif integration.get("status") not in {"READY", "PROJECT_NOT_INITIALIZED"}:
            required_action = "ASK_USER_TO_CONFIGURE_ACTIVE_INTEGRATION"
            workflow_actions.append(required_action)
        elif missing:
            required_action = "ASK_USER_TO_INSTALL_MISSING_OFFICIAL_EXTENSIONS"
            workflow_actions.append(required_action)
        elif constitution.get("status") in {"MISSING", "PLACEHOLDER"}:
            required_action = "ESTABLISH_CONSTITUTION_BEFORE_FEATURE"
            workflow_actions.append(required_action)
        else:
            required_action = "READY"
        if constitution.get("status") in {"MISSING", "PLACEHOLDER"}:
            workflow_actions.append("ESTABLISH_CONSTITUTION_BEFORE_FEATURE")
        return {
            "status": "READY" if cli_status == "READY" and integration.get("status") in {"READY", "PROJECT_NOT_INITIALIZED"} and not missing else (cli_status if cli_status != "READY" else "CAPABILITY_MISSING"),
            "cli_status": cli_status,
            "specify_version": cli_version(),
            "integration": integration,
            "official_extensions": extensions,
            "constitution": constitution,
            "workflow_actions": list(dict.fromkeys(workflow_actions)),
            "required_action": required_action,
            "companion": companion_status(root) if (root / ".specify").is_dir() and (root / PROJECT_PACKAGE).is_dir() else None,
        }
    if command == "auto-upgrade":
        return cmd_auto_upgrade(root, args)
    if command == "install-official-extension":
        return cmd_install_official_extension(root, args)
    if command == "check-artifact-approval":
        require_governance_v2(root)
        locations = feature_locations(root, args.feature_dir)
        return current_artifact_approval(root, locations, args.artifact_type)
    if command == "verify-task-package":
        require_governance_v2(root)
        return verify_task_package(root, feature_locations(root, args.feature_dir))
    if command == "audit-feature-readiness":
        return audit_feature_readiness(root, args.feature_dir)
    if command in {
        "plan-governance-bootstrap", "plan-install-update-reminder", "plan-init", "plan-onboard",
        "plan-extension-install", "plan-default-change", "plan-upgrade", "plan-rollback",
        "plan-activate-binding", "plan-record-artifact-review", "plan-upgrade-governance-v2",
        "plan-rollback-governance-v2", "plan-install-governed-companion", "plan-remove-governed-companion",
    }:
        return create_plan_command(root, command, args)
    if command in {"render", "verify"}:
        package = root / PROJECT_PACKAGE
        missing = [path for path in governance_files(root) if not (root / path).is_file()]
        mismatched: list[str] = []
        package_errors = validate_project_package(root) if not missing else []
        manifest_path = package / "MANIFEST.json"
        if not missing and manifest_path.is_file():
            manifest = read_json(manifest_path)
            for rel, expected in manifest.get("content_sha256", {}).items():
                target = root / safe_relative(root, rel)
                if not target.is_file() or sha256_file(target) != expected:
                    mismatched.append(rel)
        status = "READY" if not missing and not mismatched and not package_errors else "STATE_BROKEN"
        return {"status": status, "missing": missing, "mismatched": mismatched, "package_errors": package_errors, "project_root": str(root)}
    if command == "check-update":
        if not args.source or not Path(args.source).is_absolute():
            return {"status": "CENTRAL_SOURCE_UNVERIFIED", "reason": "explicit absolute --source is required"}
        source_root_path = Path(args.source).resolve()
        if not (source_root_path / ".git").exists():
            return {"status": "CENTRAL_SOURCE_UNVERIFIED", "reason": "source is not a Git checkout"}
        source_head = git_value(source_root_path, "rev-parse", "HEAD")
        source_status = git_value(source_root_path, "status", "--porcelain=v1", "--untracked-files=all")
        if source_status:
            return {"status": "CENTRAL_SOURCE_UNVERIFIED", "reason": "source worktree is not clean"}
        required_source_files = ("GLOBAL_POLICY.md", "SPEC_KIT_REFERENCE.md", "UPSTREAM_BASELINE")
        missing = [item for item in required_source_files if not (source_root_path / item).is_file()]
        if missing:
            return {"status": "CENTRAL_SOURCE_UNVERIFIED", "reason": f"source files missing: {', '.join(missing)}"}
        manifest_path = root / PROJECT_PACKAGE / "MANIFEST.json"
        if not manifest_path.is_file():
            return {"status": "TARGET_NOT_BOOTSTRAPPED", "reason": "target project governance manifest is missing"}
        target_manifest = read_json(manifest_path)
        target_revision = target_manifest.get("source", {}).get("revision")
        if not re.fullmatch(r"[0-9a-f]{40}", str(target_revision)):
            return {"status": "TARGET_BASELINE_UNKNOWN", "reason": "target governance manifest has no valid source revision"}
        if source_head == target_revision:
            return {
                "status": "UP_TO_DATE",
                "source_revision": source_head,
                "target_revision": target_revision,
                "target_package_version": target_manifest.get("governance_package_version"),
            }
        if not git_succeeds(source_root_path, "merge-base", "--is-ancestor", target_revision, source_head):
            return {
                "status": "REVIEW_REQUIRED",
                "reason": "target Reference baseline is not an ancestor of the central source",
                "source_revision": source_head,
                "target_revision": target_revision,
                "changed_paths": [],
            }
        changed_paths = [
            item for item in git_value(source_root_path, "diff", "--name-only", target_revision, source_head).splitlines()
            if item
        ]
        policy_paths = {"GLOBAL_POLICY.md", "governance/project/POLICY.md"}
        status = "UPDATE_AVAILABLE"
        return {
            "status": status,
            "source_revision": source_head,
            "target_revision": target_revision,
            "target_package_version": target_manifest.get("governance_package_version"),
            "changed_paths": changed_paths,
            "policy_change": bool(policy_paths.intersection(changed_paths)),
        }
    raise GovernanceError(f"unknown command: {command}")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--project-root", default=None)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("doctor")
    resolve = sub.add_parser("resolve-agent"); resolve.add_argument("--runtime-id", required=True); resolve.add_argument("--display-name"); resolve.add_argument("--integration-key"); resolve.add_argument("--json", action="store_true")
    for name in ("plan-governance-bootstrap", "plan-install-update-reminder", "plan-init", "plan-onboard", "plan-extension-install", "plan-default-change", "plan-upgrade", "plan-rollback", "plan-activate-binding"):
        item = sub.add_parser(name)
        item.add_argument("--runtime-id")
        item.add_argument("--display-name")
        item.add_argument("--integration-key")
        item.add_argument("--source")
        item.add_argument("--force", action="store_true")
        item.add_argument("--extension-directory", default="__STAGED_EXTENSION_DIRECTORY__")
        item.add_argument("--extension-id", choices=["assess", "bug"])
        item.add_argument("--version", default="VERSION_REQUIRED")
        item.add_argument("--attestation")
        item.add_argument("--commands-dir")
        item.add_argument("--allowed-path-prefix", action="append", default=[])
        item.add_argument("--context-anchor")
        item.add_argument("--documentation-language")
        item.add_argument("--anchor-evidence")
        item.add_argument("--loader-failure-evidence")
        item.add_argument("--verification-evidence")
        item.add_argument("--delivery-mode", choices=["loader", "materialized"], default="loader")
    review = sub.add_parser("plan-record-artifact-review")
    review.add_argument("--feature-dir", required=True)
    review.add_argument("--artifact-type", choices=sorted(ARTIFACT_TYPES), required=True)
    review.add_argument("--decision", choices=sorted(REVIEW_DECISIONS), required=True)
    review.add_argument("--artifact-path", action="append", default=[])
    review.add_argument("--review-summary", required=True)
    review.add_argument("--open-risk", action="append", default=[])
    review.add_argument("--reviewer", required=True)
    review.add_argument("--evidence", required=True)
    review.add_argument("--supersedes-event-id")
    migration = sub.add_parser("plan-upgrade-governance-v2")
    migration.add_argument("--source", required=True)
    rollback_v2 = sub.add_parser("plan-rollback-governance-v2")
    rollback_v2.add_argument("--migration-record", required=True)
    for name in ("plan-install-governed-companion", "plan-remove-governed-companion"):
        item = sub.add_parser(name)
        item.add_argument("--source", required=True)
        item.add_argument("--allowed-path-prefix", action="append", default=[])
    apply = sub.add_parser("apply-plan"); apply.add_argument("--plan", required=True); apply.add_argument("--approve-plan-id", required=True); apply.add_argument("--approve-plan-sha256", required=True)
    sub.add_parser("render"); sub.add_parser("verify")
    sub.add_parser("check-companion-status")
    sub.add_parser("check-capabilities")
    for name in ("check-artifact-approval", "verify-task-package", "audit-feature-readiness"):
        item = sub.add_parser(name)
        item.add_argument("--feature-dir", required=True)
        if name == "check-artifact-approval":
            item.add_argument("--artifact-type", choices=sorted(ARTIFACT_TYPES), required=True)
    update = sub.add_parser("check-update"); update.add_argument("--source")
    auto = sub.add_parser("auto-upgrade")
    auto.add_argument("--source", required=True)
    auto.add_argument("--context-anchor")
    install = sub.add_parser("install-official-extension")
    install.add_argument("--extension-id", choices=["assess", "bug"], required=True)
    install.add_argument("--runtime-id")
    install.add_argument("--integration-key")
    install.add_argument("--extension-directory", default="__STAGED_EXTENSION_DIRECTORY__")
    install.add_argument("--allowed-path-prefix", action="append", default=[])
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    root = project_root_from(Path(args.project_root) if args.project_root else None)
    try:
        result = dispatch(root, args)
    except GovernanceError as exc:
        result = {"status": exc.status or "ERROR", "error": str(exc)}
        print(json.dumps(result, ensure_ascii=False), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
