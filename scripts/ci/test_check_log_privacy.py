#!/usr/bin/env python3
"""Fixture tests for check-log-privacy.py, run against the real `.swiftlint.yml` regex."""

from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_log_privacy", Path(__file__).with_name("check-log-privacy.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

REJECTED = [
    'logger.error("a \\(error.localizedDescription, privacy: .public)")',
    'logger.error("b \\(String(describing: error), privacy: .public)")',
    'logger.error("c \\(error, privacy: .public)")',
    'logger.error("d \\(String(describing: sqlError), privacy: .public)")',
    'logger.error("e \\(e, privacy: .public)")',
    'logger.error("f \\(error.message, privacy: .public)")',
    'logger.error("g \\(nioSslError.description, privacy: .public)")',
    'logger.error("h \\(error,\n        privacy: .public)")',
    'logger.error("i \\(error?.localizedDescription ?? "nil", privacy: .public)")',
    'logger.error("j \\(error.localizedDescription.prefix(200), privacy: .public)")',
    'logger.error("k \\(scripting.errorDescription ?? "", privacy: .public)")',
]

ACCEPTED = [
    'logger.error("a \\(error.localizedDescription, privacy: .private)")',
    'logger.error("b \\(LogRedaction.publicDescription(of: error), privacy: .public)")',
    'logger.error("c \\(error.publicLogShape, privacy: .public)")',
    'logger.error("d \\(errorClass, privacy: .public)")',
    'logger.error("e \\(errors.count, privacy: .public)")',
    'logger.error("f \\(error.code, privacy: .public)")',
    'logger.error("g \\(String(describing: type(of: error)), privacy: .public)")',
    'logger.error("h \\(hasError, privacy: .public)")',
    'logger.error("i \\(isError, privacy: .public)")',
]


class CheckLogPrivacyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        shutil.copy(ROOT / ".swiftlint.yml", self.root / ".swiftlint.yml")
        self.pattern = check.rule_pattern(self.root / ".swiftlint.yml")

    def tearDown(self) -> None:
        shutil.rmtree(self.root)

    def write(self, directory: str, name: str, lines: list[str]) -> None:
        folder = self.root / directory
        folder.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def test_every_rejected_spelling_is_reported_on_its_own_line(self) -> None:
        self.write("Plugins/Driver", "Rejected.swift", REJECTED)
        found = check.offenders(self.root, self.pattern)
        self.assertEqual(found, [f"Plugins/Driver/Rejected.swift:{number}" for number in [*range(1, 9), 10, 11, 12]])

    def test_safe_spellings_are_not_reported(self) -> None:
        self.write("Plugins/Driver", "Accepted.swift", ACCEPTED)
        self.assertEqual(check.offenders(self.root, self.pattern), [])

    def test_app_and_packages_are_scanned_and_build_output_is_not(self) -> None:
        self.write("TablePro/Core", "App.swift", REJECTED[:1])
        self.write("Packages/Core/Sources", "Package.swift", REJECTED[:1])
        self.write("Packages/Core/.build/checkouts/dep", "Vendored.swift", REJECTED[:1])
        found = check.offenders(self.root, self.pattern)
        self.assertEqual(found, ["TablePro/Core/App.swift:1", "Packages/Core/Sources/Package.swift:1"])

    def test_the_repository_itself_is_clean(self) -> None:
        self.assertEqual(check.offenders(ROOT, check.rule_pattern(ROOT / ".swiftlint.yml")), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
