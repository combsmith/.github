#!/usr/bin/env python3
"""Unit tests for validate-signals.py."""

import sys
import importlib.util
from pathlib import Path
from datetime import datetime

import pytest

# Import the function under test from validate-signals.py using importlib
# (can't use standard import since the filename has a hyphen).
repo_root = Path(__file__).resolve().parent.parent.parent
script_dir = repo_root / ".github" / "scripts" / "feature-ideation"
spec = importlib.util.spec_from_file_location("validate_signals", script_dir / "validate-signals.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
_check_date_time = module._check_date_time


class TestCheckDateTime:
    """Tests for the _check_date_time format checker."""

    def test_valid_iso8601_uppercase_t_z(self):
        """Valid ISO-8601 with uppercase T and Z."""
        assert _check_date_time("2026-09-29T12:34:56Z") is True

    def test_valid_iso8601_uppercase_t_offset(self):
        """Valid ISO-8601 with uppercase T and numeric offset."""
        assert _check_date_time("2026-09-29T12:34:56+00:00") is True

    def test_valid_iso8601_lowercase_t_uppercase_z(self):
        """Valid RFC-3339 with lowercase t and uppercase Z."""
        assert _check_date_time("2026-09-29t12:34:56Z") is True

    def test_valid_iso8601_lowercase_t_lowercase_z(self):
        """Valid RFC-3339 with lowercase t and z."""
        assert _check_date_time("2026-09-29t12:34:56z") is True

    def test_valid_iso8601_lowercase_t_offset(self):
        """Valid RFC-3339 with lowercase t and numeric offset."""
        assert _check_date_time("2026-09-29t12:34:56+00:00") is True

    def test_valid_with_seconds_and_microseconds(self):
        """Valid ISO-8601 with microseconds."""
        assert _check_date_time("2026-09-29T12:34:56.123456Z") is True

    def test_valid_without_seconds(self):
        """Valid ISO-8601 with only hour and minute."""
        assert _check_date_time("2026-09-29T12:34Z") is True

    def test_non_string_returns_true(self):
        """Non-string inputs are delegated to type keyword and return True."""
        assert _check_date_time(12345) is True
        assert _check_date_time(None) is True
        assert _check_date_time({"date": "value"}) is True

    def test_invalid_date_format_raises_value_error(self):
        """Invalid date-time string raises ValueError."""
        with pytest.raises(ValueError, match="not an ISO-8601 date-time"):
            _check_date_time("not-a-date")

    def test_invalid_missing_time_raises_value_error(self):
        """Date without time raises ValueError."""
        with pytest.raises(ValueError, match="not an ISO-8601 date-time"):
            _check_date_time("2026-09-29")

    def test_invalid_wrong_separator_raises_value_error(self):
        """Wrong date-time separator raises ValueError."""
        with pytest.raises(ValueError, match="not an ISO-8601 date-time"):
            _check_date_time("2026-09-29 12:34:56Z")

    def test_invalid_malformed_time_raises_value_error(self):
        """Malformed time component raises ValueError."""
        with pytest.raises(ValueError):
            _check_date_time("2026-09-29T25:99:99Z")

    def test_invalid_partial_date_raises_value_error(self):
        """Incomplete date raises ValueError."""
        with pytest.raises(ValueError, match="not an ISO-8601 date-time"):
            _check_date_time("2026-09T12:34:56Z")

    def test_february_29_leap_year(self):
        """Valid leap year date-time."""
        assert _check_date_time("2024-02-29T12:34:56Z") is True

    def test_february_29_non_leap_year_raises_value_error(self):
        """Invalid non-leap year Feb 29 raises ValueError."""
        with pytest.raises(ValueError):
            _check_date_time("2025-02-29T12:34:56Z")


class TestPathConfinement:
    """CLI path arguments must stay inside the trusted base directories (S8707)."""

    FIXTURE = (
        repo_root / "test" / "workflows" / "feature-ideation" / "fixtures" / "expected"
        / "empty-repo.signals.json"
    )
    SCHEMA = repo_root / ".github" / "schemas" / "signals.schema.json"

    @pytest.fixture
    def confined(self, tmp_path, monkeypatch):
        """Restrict the allowed roots to a single work dir + the repo checkout."""
        work = tmp_path / "work"
        work.mkdir()
        monkeypatch.chdir(work)
        monkeypatch.setattr(
            module, "_allowed_roots", lambda: [str(work.resolve()), str(repo_root)]
        )
        return work

    def test_signals_inside_root_is_validated(self, confined):
        """A signals file inside an allowed root is read and validated."""
        target = confined / "signals.json"
        target.write_text(self.FIXTURE.read_text(encoding="utf-8"), encoding="utf-8")
        assert module.main(["validate-signals.py", "signals.json", str(self.SCHEMA)]) == 0

    def test_relative_traversal_outside_root_is_rejected(self, confined, capsys):
        """A ``../`` path escaping every allowed root exits 2 without reading it."""
        outside = confined.parent / "outside.json"
        outside.write_text(self.FIXTURE.read_text(encoding="utf-8"), encoding="utf-8")
        rc = module.main(["validate-signals.py", "../outside.json", str(self.SCHEMA)])
        assert rc == 2
        assert "outside the allowed directories" in capsys.readouterr().err

    def test_absolute_path_outside_root_is_rejected(self, confined, capsys):
        """An absolute path outside every allowed root exits 2."""
        outside = confined.parent / "outside.json"
        outside.write_text("{}", encoding="utf-8")
        assert module.main(["validate-signals.py", str(outside), str(self.SCHEMA)]) == 2
        assert "outside the allowed directories" in capsys.readouterr().err

    def test_schema_outside_root_is_rejected(self, confined, capsys):
        """The optional schema argument is confined the same way."""
        (confined / "signals.json").write_text(
            self.FIXTURE.read_text(encoding="utf-8"), encoding="utf-8"
        )
        outside_schema = confined.parent / "schema.json"
        outside_schema.write_text(self.SCHEMA.read_text(encoding="utf-8"), encoding="utf-8")
        rc = module.main(["validate-signals.py", "signals.json", str(outside_schema)])
        assert rc == 2
        assert "outside the allowed directories" in capsys.readouterr().err

    def test_default_allowed_roots_include_cwd_and_temp(self, tmp_path, monkeypatch):
        """Default roots cover the CWD, the temp dir, $RUNNER_TEMP and the repo."""
        import os
        import tempfile

        monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
        monkeypatch.chdir(tmp_path)
        roots = module._allowed_roots()
        assert os.path.realpath(os.getcwd()) in roots
        assert os.path.realpath(tempfile.gettempdir()) in roots
        assert os.path.realpath(str(tmp_path)) in roots
        assert str(repo_root) in roots
