#!/usr/bin/env python3
"""Build the runtime legal-deadline registry from the four Docs inventories.

The Markdown inventories are the source of truth.  Each one contains exactly
one fenced JSON application; this script deliberately does not maintain a
second hand-written list of rules.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


EXPECTED_RULE_COUNTS = {"GPK": 22, "KAS": 20, "KOAP": 10, "UPK": 14}
SOURCE_FILES = {
    "GPK": "gpk-appeal-deadlines.md",
    "KAS": "kas-appeal-deadlines.md",
    "KOAP": "koap-appeal-deadlines.md",
    "UPK": "upk-appeal-deadlines.md",
}
JSON_FENCE = re.compile(r"^```json\s*$", re.IGNORECASE | re.MULTILINE)
JSON_CLOSE_FENCE = re.compile(r"^```\s*$", re.MULTILINE)


class RegistryError(ValueError):
    """An actionable source or normalization error."""


def _json_fence_payload(markdown: str, document: str) -> str:
    starts = list(JSON_FENCE.finditer(markdown))
    if len(starts) != 1:
        raise RegistryError(
            f"{document}: expected exactly one ```json fence, found {len(starts)}"
        )
    start = starts[0].end()
    close = JSON_CLOSE_FENCE.search(markdown, start)
    if close is None:
        raise RegistryError(f"{document}: unterminated ```json fence")
    if JSON_FENCE.search(markdown, close.end()):
        raise RegistryError(f"{document}: more than one JSON application")
    return markdown[start:close.start()].strip()


def _read_document(source_dir: Path, code: str) -> tuple[dict[str, Any], str, str]:
    path = source_dir / SOURCE_FILES[code]
    if not path.is_file():
        raise RegistryError(f"missing source document: {path}")
    raw = path.read_bytes()
    try:
        markdown = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RegistryError(f"{path}: source is not UTF-8") from error
    payload = _json_fence_payload(markdown, path.name)
    try:
        value = json.loads(payload)
    except json.JSONDecodeError as error:
        raise RegistryError(f"{path.name}: invalid JSON application: {error}") from error
    if not isinstance(value, dict):
        raise RegistryError(f"{path.name}: JSON application must be an object")
    return value, str(path.relative_to(source_dir.parent.parent)), hashlib.sha256(raw).hexdigest()


def _required(mapping: dict[str, Any], key: str, where: str) -> Any:
    if key not in mapping:
        raise RegistryError(f"{where}: missing required field {key!r}")
    return mapping[key]


def _string(mapping: dict[str, Any], key: str, where: str, *, allow_none: bool = False) -> str | None:
    value = _required(mapping, key, where)
    if value is None and allow_none:
        return None
    if not isinstance(value, str):
        raise RegistryError(f"{where}: {key!r} must be a string")
    return value


def _source_metadata(payload: dict[str, Any], code: str, document: str, markdown_sha256: str) -> dict[str, Any]:
    artifact = _required(payload, "artifact", document)
    source = _required(payload, "source", document)
    if not isinstance(artifact, dict) or not isinstance(source, dict):
        raise RegistryError(f"{document}: artifact/source must be objects")
    revision = _required(artifact, "revision", f"{document}.artifact")
    if not isinstance(revision, int) or isinstance(revision, bool):
        raise RegistryError(f"{document}.artifact.revision: expected integer")
    source_hash = _string(source, "sha256", f"{document}.source")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", source_hash or ""):
        raise RegistryError(f"{document}.source.sha256: expected a SHA-256 hex digest")
    return {
        "code": code,
        "document": document,
        "revision": revision,
        "sourceHash": source_hash,
        "markdownSha256": markdown_sha256,
        "title": _string(artifact, "title", f"{document}.artifact"),
        "date": _string(artifact, "date", f"{document}.artifact"),
        "scope": _string(artifact, "scope", f"{document}.artifact"),
        # Keep the complete machine-readable application to make the generated
        # artifact auditable and to avoid silently dropping auxiliary sections.
        "payload": payload,
    }


def _normalization_context(meta: dict[str, Any]) -> dict[str, Any]:
    return {
        "code": meta["code"],
        "document": meta["document"],
        "revision": meta["revision"],
        "sourceHash": meta["sourceHash"],
    }


def _with_context(item: dict[str, Any], meta: dict[str, Any]) -> dict[str, Any]:
    result = dict(item)
    result.update(_normalization_context(meta))
    return result


def _normalize_policy(item: Any, meta: dict[str, Any], index: int) -> dict[str, Any]:
    where = f"{meta['document']}.policies[{index}]"
    if not isinstance(item, dict):
        raise RegistryError(f"{where}: expected object")
    result = _with_context(item, meta)
    policy_id = item.get("policy_id", item.get("id"))
    if not isinstance(policy_id, str) or not policy_id:
        raise RegistryError(f"{where}: missing policy_id/id")
    if not isinstance(item.get("rule"), str) or not isinstance(item.get("source"), str):
        raise RegistryError(f"{where}: rule and source must be strings")
    result["policy_id"] = policy_id
    return result


def _normalize_dependency(item: Any, meta: dict[str, Any], index: int) -> dict[str, Any]:
    where = f"{meta['document']}.triggerDependencies[{index}]"
    if not isinstance(item, dict):
        raise RegistryError(f"{where}: expected object")
    result = _with_context(item, meta)
    dependency_id = item.get("dependency_id", item.get("rule_id", item.get("id")))
    if not isinstance(dependency_id, str) or not dependency_id:
        raise RegistryError(f"{where}: missing dependency_id/rule_id/id")
    if not isinstance(item.get("context"), str) or not isinstance(item.get("source"), str):
        raise RegistryError(f"{where}: context and source must be strings")
    result["dependency_id"] = dependency_id
    return result


def _normalize_question(item: Any, meta: dict[str, Any], index: int) -> dict[str, Any]:
    where = f"{meta['document']}.openQuestions[{index}]"
    if not isinstance(item, dict):
        raise RegistryError(f"{where}: expected object")
    question_id = item.get("question_id", item.get("id"))
    if not isinstance(question_id, str) or not question_id:
        raise RegistryError(f"{where}: missing question_id/id")
    result = _with_context(item, meta)
    result["question_id"] = question_id
    return result


_DURATION_PATTERN = re.compile(
    r"^(?P<prefix>не более\s+)?(?P<value>\d+)\s+"
    r"(?P<unit>календарн\w*\s+(?:дн\w*|сут\w*|месяц\w*|год\w*)|"
    r"рабоч\w*\s+дн\w*|сут\w*|месяц\w*|год\w*)"
    r"(?P<tail>.*)$",
    re.IGNORECASE,
)
_RELATIVE_BEFORE = re.compile(
    r"^не позднее чем за (?P<value>\d+)\s+(?P<unit>календарн\w*\s+(?:дн\w*|сут\w*))\s+(?P<reference>.+)$",
    re.IGNORECASE,
)
_RELATIVE_SAME_PERIOD = re.compile(
    r"^в пределах того же (?P<value>\d+)-месячного периода$", re.IGNORECASE
)


def _duration_unit(text: str) -> tuple[str, str | None]:
    lowered = text.lower()
    if "рабоч" in lowered:
        return "workingDays", "workingDays"
    if "сут" in lowered:
        if "календар" in lowered:
            return "calendarSutki", "calendarSutki"
        return "calendarSutki", "calendarSutki"
    if "дн" in lowered:
        return "calendarDays", "calendarDays"
    if "месяц" in lowered:
        return "months", "months"
    if "год" in lowered:
        return "years", "years"
    raise RegistryError(f"unknown duration unit: {text!r}")


def normalize_duration(value: Any, where: str) -> dict[str, Any]:
    if value is None:
        return {
            "kind": "none",
            "value": None,
            "unit": None,
            "raw": None,
            "isUpperBound": False,
            "relation": None,
            "reference": None,
            "qualifier": None,
        }
    if not isinstance(value, str) or not value.strip():
        raise RegistryError(f"{where}: duration must be a non-empty string or null")
    raw = value.strip()

    relative = _RELATIVE_BEFORE.fullmatch(raw)
    if relative:
        kind, unit = _duration_unit(relative.group("unit"))
        return {
            "kind": "relative",
            "value": int(relative.group("value")),
            "unit": unit,
            "raw": raw,
            "isUpperBound": True,
            "relation": "before",
            "reference": relative.group("reference"),
            "qualifier": None,
        }

    relative = _RELATIVE_SAME_PERIOD.fullmatch(raw)
    if relative:
        return {
            "kind": "relative",
            "value": int(relative.group("value")),
            "unit": "months",
            "raw": raw,
            "isUpperBound": False,
            "relation": "samePeriod",
            "reference": "того же периода",
            "qualifier": None,
        }

    match = _DURATION_PATTERN.fullmatch(raw)
    if not match:
        raise RegistryError(f"{where}: unknown duration formula {raw!r}")
    kind, unit = _duration_unit(match.group("unit"))
    tail = match.group("tail").strip()
    allowed_tail = "с переносом окончания с нерабочего дня"
    if tail and tail != allowed_tail:
        raise RegistryError(f"{where}: unknown duration qualifier {tail!r}")
    return {
        "kind": kind,
        "value": int(match.group("value")),
        "unit": unit,
        "raw": raw,
        "isUpperBound": bool(match.group("prefix")),
        "relation": None,
        "reference": None,
        "qualifier": tail or None,
    }


def _normalize_rule(item: Any, meta: dict[str, Any], index: int) -> dict[str, Any]:
    where = f"{meta['document']}.coreRules[{index}]"
    if not isinstance(item, dict):
        raise RegistryError(f"{where}: expected object")
    for key in ("rule_id", "stage", "act_context", "trigger", "source", "priority"):
        if key not in item or not isinstance(item[key], str):
            raise RegistryError(f"{where}: {key!r} must be a string")
    if "notes" not in item or (item["notes"] is not None and not isinstance(item["notes"], str)):
        raise RegistryError(f"{where}: 'notes' must be a string or null")
    result = _with_context(item, meta)
    original_duration = item.get("duration")
    result["durationText"] = original_duration
    result["duration"] = normalize_duration(original_duration, f"{where}.duration")
    return result


def _normalize_array(payload: dict[str, Any], keys: tuple[str, ...], meta: dict[str, Any], kind: str) -> list[dict[str, Any]]:
    for key in keys:
        if key in payload:
            value = payload[key]
            if not isinstance(value, list):
                raise RegistryError(f"{meta['document']}.{key}: expected array")
            if kind == "policy":
                return [_normalize_policy(item, meta, i) for i, item in enumerate(value)]
            if kind == "dependency":
                return [_normalize_dependency(item, meta, i) for i, item in enumerate(value)]
    return []


def _validate_unique(items: list[dict[str, Any]], key: str, where: str) -> None:
    seen: dict[str, int] = {}
    for index, item in enumerate(items):
        value = item.get(key)
        if not isinstance(value, str) or not value:
            raise RegistryError(f"{where}[{index}]: missing {key}")
        if value in seen:
            raise RegistryError(f"{where}: duplicate {key} {value!r} at indexes {seen[value]} and {index}")
        seen[value] = index


def build_registry(source_dir: Path) -> dict[str, Any]:
    documents: list[dict[str, Any]] = []
    all_rules: list[dict[str, Any]] = []
    all_policies: list[dict[str, Any]] = []
    all_dependencies: list[dict[str, Any]] = []
    all_constraints: list[dict[str, Any]] = []
    all_exclusions: list[dict[str, Any]] = []
    all_questions: list[dict[str, Any]] = []

    for code in EXPECTED_RULE_COUNTS:
        payload, document, markdown_sha256 = _read_document(source_dir, code)
        meta = _source_metadata(payload, code, document, markdown_sha256)
        rules = payload.get("coreRules")
        if not isinstance(rules, list):
            raise RegistryError(f"{document}.coreRules: expected array")
        expected = EXPECTED_RULE_COUNTS[code]
        if len(rules) != expected:
            raise RegistryError(f"{document}: expected {expected} core rules, found {len(rules)}")
        normalized_rules = [_normalize_rule(rule, meta, i) for i, rule in enumerate(rules)]
        policies = _normalize_array(payload, ("computationPolicies", "countingPolicies"), meta, "policy")
        dependencies = _normalize_array(payload, ("triggerDependencies",), meta, "dependency")

        def contextual_array(key: str) -> list[dict[str, Any]]:
            value = payload.get(key, [])
            if not isinstance(value, list):
                raise RegistryError(f"{document}.{key}: expected array")
            return [_with_context(item, meta) if isinstance(item, dict) else item for item in value]

        constraints = contextual_array("constraints")
        exclusions = contextual_array("exclusions")
        questions_raw = contextual_array("openQuestions")
        questions = [_normalize_question(item, meta, i) for i, item in enumerate(questions_raw)]
        documents.append(meta)
        all_rules.extend(normalized_rules)
        all_policies.extend(policies)
        all_dependencies.extend(dependencies)
        all_constraints.extend(constraints)
        all_exclusions.extend(exclusions)
        all_questions.extend(questions)

    _validate_unique(all_rules, "rule_id", "coreRules")
    _validate_unique(all_policies, "policy_id", "policies")
    _validate_unique(all_dependencies, "dependency_id", "triggerDependencies")
    _validate_unique(all_questions, "question_id", "openQuestions")

    return {
        "schemaVersion": 1,
        "sources": documents,
        "coreRules": all_rules,
        "policies": all_policies,
        "triggerDependencies": all_dependencies,
        "constraints": all_constraints,
        "exclusions": all_exclusions,
        "openQuestions": all_questions,
    }


def render_registry(registry: dict[str, Any]) -> bytes:
    return (json.dumps(registry, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=Path("Docs/legal-deadlines"),
        help="directory containing the four appeal-deadlines Markdown files",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("Sources/SudrfKit/Resources/LegalDeadlineRegistry.json"),
        help="generated JSON resource path",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the generated bytes differ from the existing resource",
    )
    args = parser.parse_args(argv)
    try:
        rendered = render_registry(build_registry(args.source_dir.resolve()))
    except (OSError, RegistryError, json.JSONDecodeError) as error:
        print(f"legal deadline registry: error: {error}", file=sys.stderr)
        return 1

    output = args.output.resolve()
    if args.check:
        try:
            existing = output.read_bytes()
        except OSError as error:
            print(f"legal deadline registry: generated resource is missing: {output}: {error}", file=sys.stderr)
            return 1
        if existing != rendered:
            print(f"legal deadline registry: {output} is stale; run {Path(__file__).name}", file=sys.stderr)
            return 1
        print(f"legal deadline registry: {output} is up to date")
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(rendered)
    print(f"legal deadline registry: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
