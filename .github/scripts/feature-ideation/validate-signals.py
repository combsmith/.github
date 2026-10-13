#!/usr/bin/env python3
"""Validate a signals.json file against signals.schema.json.

Usage:
    validate-signals.py <signals.json> [<schema.json>]

Exit codes:
    0  valid
    1  invalid (validation error printed to stderr)
    2  usage / file error
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:
    sys.stderr.write(
        "[validate-signals] python jsonschema not installed. "
        "Install with: pip install jsonschema\n"
    )
    sys.exit(2)


# `format` keywords (e.g. "format": "date-time") are not enforced by
# Draft202012Validator unless an explicit FormatChecker is supplied. The
# default FormatChecker also does NOT include `date-time` — that requires the
# optional `rfc3339-validator` dependency. Avoid pulling in extra deps by
# registering the small inline validator below on a module-level checker.
# Caught by Copilot review on PR petry-projects/.github#85.
FORMAT_CHECKER = FormatChecker()


@FORMAT_CHECKER.checks("date-time", raises=(ValueError, TypeError))
def _check_date_time(instance) -> bool:  # noqa: ANN001 — jsonschema callback signature
    """FormatChecker callback for the JSON-schema ``date-time`` format.

    Accepts ISO-8601 / RFC-3339 strings via ``datetime.fromisoformat`` (Python
    3.11+ accepts the trailing ``Z``; for older interpreters we substitute it).
    RFC-3339 §5.6 also permits a lowercase ``t`` date/time separator and a
    lowercase ``z`` zone designator, so both cases are accepted. Raises
    ``ValueError`` for strings that are not date-times; non-strings are left to
    the ``type`` keyword.
    """
    if not isinstance(instance, str):
        return True  # non-strings handled by `type` keyword, not format
    # Must look like a date-time, not just any string. Require at least
    # YYYY-MM-DDTHH:MM[:SS]. RFC-3339 permits a lowercase "t" separator.
    if not re.match(r"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}", instance):
        raise ValueError(f"not an ISO-8601 date-time: {instance!r}")
    # datetime.fromisoformat before Python 3.11 accepts neither a lowercase "t"
    # separator nor a "Z"/"z" zone designator, both of which RFC-3339 permits.
    # Normalize the separator to "T" and substitute the numeric UTC offset so
    # valid RFC-3339 timestamps validate on every interpreter.
    candidate = instance
    if len(candidate) > 10 and candidate[10] in ("t", "T"):
        candidate = f"{candidate[:10]}T{candidate[11:]}"
    if candidate[-1] in ("Z", "z"):
        candidate = f"{candidate[:-1]}+00:00"
    datetime.fromisoformat(candidate)
    return True


# Repo checkout containing this script (…/.github/scripts/feature-ideation/).
_REPO_ROOT = os.path.realpath(Path(__file__).resolve().parent.parent.parent.parent)


def _allowed_roots() -> list[str]:
    """Trusted base directories that CLI path arguments must resolve inside.

    Covers every legitimate caller: repo fixtures/schemas (CWD or this script's
    checkout), the reusable workflow's ``${{ runner.temp }}/signals.json``
    (``$RUNNER_TEMP``), and test scratch files (the system temp dir).
    """
    roots = [os.path.realpath(os.getcwd()), os.path.realpath(tempfile.gettempdir())]
    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp:
        roots.append(os.path.realpath(runner_temp))
    roots.append(_REPO_ROOT)
    return roots


def _confine_path(raw: str | os.PathLike[str]) -> Path | None:
    """Resolve ``raw`` and return it only if it lies inside an allowed root.

    Guards against path traversal (``../``, absolute paths, symlinks) via the
    CLI arguments — SonarCloud pythonsecurity:S8707. Returns ``None`` when the
    resolved path escapes every allowed root.
    """
    candidate = os.path.realpath(raw)
    for root in _allowed_roots():
        if os.path.commonpath([root, candidate]) == root:
            return Path(candidate)
    return None


def main(argv: list[str]) -> int:
    if len(argv) < 2 or len(argv) > 3:
        sys.stderr.write(
            "usage: validate-signals.py <signals.json> [<schema.json>]\n"
        )
        return 2

    raw_schema = argv[2] if len(argv) == 3 else os.path.join(
        _REPO_ROOT, ".github", "schemas", "signals.schema.json"
    )
    signals_path = _confine_path(argv[1])
    if signals_path is None:
        sys.stderr.write(
            f"[validate-signals] path is outside the allowed directories: {argv[1]}\n"
        )
        return 2
    schema_path = _confine_path(raw_schema)
    if schema_path is None:
        sys.stderr.write(
            f"[validate-signals] schema path is outside the allowed directories: {raw_schema}\n"
        )
        return 2

    if not signals_path.exists():
        sys.stderr.write(f"[validate-signals] not found: {signals_path}\n")
        return 2
    if not schema_path.exists():
        sys.stderr.write(f"[validate-signals] schema not found: {schema_path}\n")
        return 2

    try:
        signals = json.loads(signals_path.read_text(encoding="utf-8"))
    except OSError as exc:
        # File read errors (permissions, I/O) must also exit 2. Caught by
        # CodeRabbit review on PR petry-projects/.github#85.
        sys.stderr.write(f"[validate-signals] cannot read {signals_path}: {exc}\n")
        return 2
    except json.JSONDecodeError as exc:
        # Per the docstring contract, exit 2 means usage / file error and
        # exit 1 means schema validation error. A malformed signals file
        # is a file/data error, not a schema violation. Caught by
        # CodeRabbit review on PR petry-projects/.github#85.
        sys.stderr.write(f"[validate-signals] invalid JSON in {signals_path}: {exc}\n")
        return 2

    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except OSError as exc:
        sys.stderr.write(f"[validate-signals] cannot read schema {schema_path}: {exc}\n")
        return 2
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"[validate-signals] invalid schema JSON: {exc}\n")
        return 2

    validator = Draft202012Validator(schema, format_checker=FORMAT_CHECKER)
    errors = sorted(validator.iter_errors(signals), key=lambda e: list(e.absolute_path))
    if not errors:
        print(f"[validate-signals] OK: {signals_path}")
        return 0

    sys.stderr.write(f"[validate-signals] {len(errors)} validation error(s) in {signals_path}:\n")
    for err in errors:
        path = "/".join(str(p) for p in err.absolute_path) or "<root>"
        sys.stderr.write(f"  - {path}: {err.message}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
