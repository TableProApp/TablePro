import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import importlib.util

SPEC = importlib.util.spec_from_file_location("validate_evidence", ROOT / "validate-evidence.py")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class EvidenceManifestTests(unittest.TestCase):
    def fixture(self, selector="case::regression", log_content=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        log = "test case::regression ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
        if log_content is not None:
            log = log_content
        (directory / "focused.txt").write_text(log)
        manifest = {
            "schema_version": 1,
            "source_commit": "a" * 40,
            "source_sha256": {},
            "log_sha256": {"focused.txt": hashlib.sha256(log.encode()).hexdigest()},
            "test": selector,
            "validation": {
                "focused_test": {
                    "command": "cargo test -p package case::regression -- --exact",
                    "result": "1 passed, 0 failed",
                    "log": "focused.txt",
                }
            },
        }
        path = directory / "manifest.json"
        path.write_text(json.dumps(manifest))
        return path, manifest

    def test_focused_manifest_checks_digest_selector_and_executed_count(self):
        path, _ = self.fixture()
        self.assertEqual(VALIDATOR.validate_manifest(path, strict=True)[0], [])

    def test_manifest_rejects_stale_selector(self):
        path, manifest = self.fixture(selector="case::old_name")
        path.write_text(json.dumps(manifest))
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("differs from focused command" in error for error in errors))

    def test_manifest_rejects_missing_execution(self):
        path, _ = self.fixture(log_content="test result: ok. 0 passed; 0 failed; 0 ignored\n")
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("executed an unexpected number" in error for error in errors))

    def test_manifest_rejects_corrupt_log_digest(self):
        path, manifest = self.fixture()
        manifest["log_sha256"]["focused.txt"] = "0" * 64
        path.write_text(json.dumps(manifest))
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("digest mismatch" in error for error in errors))

    def test_manifest_accepts_multiple_tests_run_by_wrapper_script(self):
        path, manifest = self.fixture()
        names = ["first_case", "second_case"]
        log = "test first_case ... ok\ntest second_case ... ok\ntest result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
        (path.parent / "focused.txt").write_text(log)
        manifest["test"] = names
        manifest["log_sha256"]["focused.txt"] = hashlib.sha256(log.encode()).hexdigest()
        manifest["validation"]["focused_test"].update(
            command="bash scripts/run-focused.sh",
            result="2 passed, 0 failed",
        )
        path.write_text(json.dumps(manifest))
        self.assertEqual(VALIDATOR.validate_manifest(path, strict=True)[0], [])

    def test_manifest_accepts_single_source_digest_with_source_file(self):
        path, manifest = self.fixture()
        source = path.parent / "source.rs"
        source.write_text("source")
        manifest["source_file"] = "source.rs"
        manifest["source_sha256"] = hashlib.sha256(b"source").hexdigest()
        path.write_text(json.dumps(manifest))
        self.assertEqual(VALIDATOR.validate_manifest(path, strict=True)[0], [])


if __name__ == "__main__":
    unittest.main()
