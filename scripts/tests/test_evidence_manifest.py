import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

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

    def layer_report_fixture(self, **updates):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "manifest.json"
        report = {
            "schema_version": 1,
            "commit": "a" * 40,
            "working_tree": "",
            "tracked_diff_sha256": hashlib.sha256(b"").hexdigest(),
            "started_utc": "2026-10-24T00:00:00+00:00",
            "status": "passed",
            "layers": {"quick": {"status": "passed", "steps": []}},
            "finished_utc": "2026-10-24T00:00:01+00:00",
        }
        report.update(updates)
        path.write_text(json.dumps(report))
        return path, report

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

    def test_manifest_accepts_module_filters_with_matching_children(self):
        for selector in ("module", "module::", "module::*"):
            with self.subTest(selector=selector):
                log = "test module::first ... ok\ntest module::second ... ok\ntest result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
                path, manifest = self.fixture(selector=selector, log_content=log)
                manifest["validation"]["focused_test"].update(
                    command="cargo test -p package module::", result="2 passed, 0 failed"
                )
                path.write_text(json.dumps(manifest))
                self.assertEqual(VALIDATOR.validate_manifest(path, strict=True)[0], [])

    def test_module_filter_rejects_unrelated_names_and_wrong_counts(self):
        for names, count in [(["other::first", "other::second"], 2), (["module_extra::first", "module_extra::second"], 2), (["module::first", "module::second"], 1)]:
            with self.subTest(names=names, count=count):
                log = "".join(f"test {name} ... ok\n" for name in names)
                log += f"test result: ok. {len(names)} passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
                path, manifest = self.fixture(selector="module::*", log_content=log)
                manifest["validation"]["focused_test"].update(command="cargo test -p package module::", result=f"{count} passed, 0 failed")
                path.write_text(json.dumps(manifest))
                self.assertTrue(VALIDATOR.validate_manifest(path, strict=True)[0])

    def test_exact_selector_does_not_accept_module_children(self):
        log = "test module::child ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n"
        path, manifest = self.fixture(selector="module", log_content=log)
        manifest["validation"]["focused_test"]["command"] = "cargo test -p package module -- --exact"
        path.write_text(json.dumps(manifest))
        self.assertTrue(VALIDATOR.validate_manifest(path, strict=True)[0])

    def test_manifest_accepts_single_source_digest_with_source_file(self):
        path, manifest = self.fixture()
        source = path.parent / "source.rs"
        source.write_text("source")
        manifest["source_file"] = "source.rs"
        manifest["source_sha256"] = hashlib.sha256(b"source").hexdigest()
        path.write_text(json.dumps(manifest))
        self.assertEqual(VALIDATOR.validate_manifest(path, strict=True)[0], [])

    def test_manifest_verifies_a_source_digest_at_its_own_commit_after_checkout_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "--quiet"], cwd=repo, check=True)
            app = repo / "app.rs"
            app.write_text("app source")
            self._commit(repo, "app.rs")
            app_commit = self._revision(repo)

            historical_source = b"recorded test source"
            historical_prefix = "lin" + "ux"
            historical_relative_path = "/".join(("crates", "app", "tests", "gtk_safety.py"))
            historical_path = repo / historical_prefix / historical_relative_path
            historical_path.parent.mkdir(parents=True)
            historical_path.write_bytes(historical_source)
            self._commit(repo, f"{historical_prefix}/{historical_relative_path}")

            already_prefixed_path = "/".join((historical_prefix, "generated", "source.py"))
            prefixed_source = b"source path already includes the old prefix"
            prefixed_path = repo / already_prefixed_path
            prefixed_path.parent.mkdir(parents=True)
            prefixed_path.write_bytes(prefixed_source)
            self._commit(repo, already_prefixed_path)
            test_commit = self._revision(repo)

            current_source = repo / historical_relative_path
            current_source.parent.mkdir(parents=True)
            current_source.write_text("current checkout")
            manifest_path = repo / "evidence/manifest.json"
            manifest_path.parent.mkdir()
            manifest_path.write_text(json.dumps({
                "schema_version": 1,
                "source_commit": app_commit,
                "source_sha256": {
                    historical_relative_path: hashlib.sha256(historical_source).hexdigest(),
                    already_prefixed_path: hashlib.sha256(prefixed_source).hexdigest(),
                },
                "source_commits": {
                    historical_relative_path: test_commit,
                    already_prefixed_path: test_commit,
                },
            }))

            with mock.patch.object(VALIDATOR, "ROOT", repo):
                errors, warnings = VALIDATOR.validate_manifest(manifest_path, strict=True)

        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_manifest_rejects_a_per_source_commit_that_does_not_match_the_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "--quiet"], cwd=repo, check=True)
            source = repo / "source.rs"
            source.write_text("recorded source")
            self._commit(repo, "source.rs")
            commit = self._revision(repo)
            manifest_path = repo / "evidence/manifest.json"
            manifest_path.parent.mkdir()
            manifest_path.write_text(json.dumps({
                "schema_version": 1,
                "source_commit": commit,
                "source_sha256": {"source.rs": hashlib.sha256(b"different source").hexdigest()},
                "source_commits": {"source.rs": commit},
            }))

            with mock.patch.object(VALIDATOR, "ROOT", repo):
                errors, _ = VALIDATOR.validate_manifest(manifest_path, strict=True)

        self.assertTrue(any("source digest does not match its recorded commit" in error for error in errors))

    def test_manifest_rejects_an_oversized_per_file_source_commit_map_before_git_lookup(self):
        path, manifest = self.fixture()
        source_names = [f"source-{index}.rs" for index in range(VALIDATOR.MAX_SOURCE_COMMITS + 1)]
        expected = hashlib.sha256(b"source").hexdigest()
        manifest["source_sha256"] = {name: expected for name in source_names}
        manifest["source_commits"] = {name: "a" * 40 for name in source_names}
        path.write_text(json.dumps(manifest))

        with mock.patch.object(VALIDATOR, "source_bytes_at_commit", return_value=b"source") as source_lookup:
            errors, _ = VALIDATOR.validate_manifest(path, strict=True)

        self.assertTrue(any("too many per-file source commits" in error for error in errors))
        source_lookup.assert_not_called()

    def test_manifest_refuses_invalid_per_file_source_mappings(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "--quiet"], cwd=repo, check=True)
            source = repo / "source.rs"
            source.write_text("recorded source")
            self._commit(repo, "source.rs")
            commit = self._revision(repo)
            manifest_path = repo / "evidence/manifest.json"
            manifest_path.parent.mkdir()
            source_sha256 = {"source.rs": hashlib.sha256(b"recorded source").hexdigest()}

            with mock.patch.object(VALIDATOR, "ROOT", repo):
                manifest_path.write_text(json.dumps({
                    "schema_version": 1,
                    "source_commit": commit,
                    "source_sha256": source_sha256,
                    "source_commits": [],
                }))
                errors, _ = VALIDATOR.validate_manifest(manifest_path, strict=True)
                self.assertTrue(any("source_commits must map" in error for error in errors))

                manifest_path.write_text(json.dumps({
                    "schema_version": 1,
                    "source_commit": commit,
                    "source_sha256": source_sha256,
                    "source_commits": {"orphan.rs": commit},
                }))
                errors, _ = VALIDATOR.validate_manifest(manifest_path, strict=True)
                self.assertTrue(any("has no matching source_sha256 entry" in error for error in errors))

                manifest_path.write_text(json.dumps({
                    "schema_version": 1,
                    "source_commit": commit,
                    "source_sha256": source_sha256,
                    "source_commits": {"source.rs": "invalid"},
                }))
                errors, _ = VALIDATOR.validate_manifest(manifest_path, strict=True)
                self.assertTrue(any("invalid source commit" in error for error in errors))

                manifest_path.write_text(json.dumps({
                    "schema_version": 1,
                    "source_commit": commit,
                    "source_sha256": source_sha256,
                    "source_commits": {"source.rs": None},
                }))
                errors, _ = VALIDATOR.validate_manifest(manifest_path, strict=True)
                self.assertTrue(any("invalid source commit" in error for error in errors))

                missing_digest = hashlib.sha256(b"missing source").hexdigest()
                manifest_path.write_text(json.dumps({
                    "schema_version": 1,
                    "source_commit": commit,
                    "source_sha256": {"missing.rs": missing_digest},
                    "source_commits": {"missing.rs": commit},
                }))
                errors, _ = VALIDATOR.validate_manifest(manifest_path, strict=True)
                for unsafe_path in ("../outside.rs", "/outside.rs"):
                    manifest_path.write_text(json.dumps({
                        "schema_version": 1,
                        "source_commit": commit,
                        "source_sha256": {unsafe_path: missing_digest},
                        "source_commits": {unsafe_path: commit},
                    }))
                    errors, _ = VALIDATOR.validate_manifest(manifest_path, strict=True)
                    self.assertTrue(any(
                        "source digest does not match its recorded commit" in error for error in errors
                    ))

        self.assertTrue(any("source digest does not match its recorded commit" in error for error in errors))

    @staticmethod
    def _commit(repo, path):
        subprocess.run(["git", "add", path], cwd=repo, check=True)
        subprocess.run(
            ["git", "-c", "user.name=Evidence Test", "-c", "user.email=evidence@example.invalid", "commit", "--quiet", "-m", "fixture"],
            cwd=repo,
            check=True,
        )

    @staticmethod
    def _revision(repo):
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
        ).stdout.strip()

    def test_selector_extracts_the_last_positional_cargo_test_filter(self):
        selector, exact = VALIDATOR.test_selector(
            "cargo test --manifest-path Cargo.toml --features sqlite package::module::case -- --exact"
        )
        self.assertEqual((selector, exact), ("package::module::case", True))

    def test_selector_returns_no_filter_for_non_test_commands(self):
        self.assertEqual(VALIDATOR.test_selector("cargo check -p package"), (None, False))

    def test_a_manifest_without_the_evidence_schema_is_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps({"format": "unrelated report"}))
            self.assertEqual(VALIDATOR.validate_manifest(path, strict=True), ([], []))

    def test_missing_or_malformed_manifest_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing.json"
            malformed = Path(directory) / "malformed.json"
            malformed.write_text("{")
            self.assertTrue(VALIDATOR.validate_manifest(missing, strict=True)[0])
            self.assertTrue(VALIDATOR.validate_manifest(malformed, strict=True)[0])

    def test_missing_source_identity_is_warning_or_strict_error(self):
        path, manifest = self.fixture()
        manifest.pop("source_commit")
        manifest["source_sha256"] = {}
        path.write_text(json.dumps(manifest))
        errors, warnings = VALIDATOR.validate_manifest(path)
        self.assertFalse(errors)
        self.assertEqual(len(warnings), 1)
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertEqual(len(errors), 1)

    def test_clean_test_layer_report_uses_its_commit_as_source_identity(self):
        path, _ = self.layer_report_fixture()
        errors, warnings = VALIDATOR.validate_manifest(path, strict=True)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_dirty_test_layer_report_keeps_tracked_and_untracked_source_identity(self):
        path, report = self.layer_report_fixture(
            working_tree=" M tracked.rs\n?? new.rs",
            tracked_diff_sha256="b" * 64,
            untracked_inputs=["new.rs"],
            untracked_inputs_sha256="c" * 64,
        )
        errors, warnings = VALIDATOR.validate_manifest(path, strict=True)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])
        self.assertEqual(json.loads(path.read_text()), report)

    def test_test_layer_report_rejects_malformed_commit_and_diff_fingerprints(self):
        path, _ = self.layer_report_fixture(commit="not-a-commit", tracked_diff_sha256="bad")
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("invalid test-layer report commit" in error for error in errors))
        self.assertTrue(any("invalid test-layer report tracked diff digest" in error for error in errors))

    def test_test_layer_report_rejects_a_non_string_status_without_raising(self):
        path, _ = self.layer_report_fixture(status=[])
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("invalid test-layer report status" in error for error in errors))

    def test_test_layer_report_rejects_wrong_types_for_tree_and_layers(self):
        path, _ = self.layer_report_fixture(working_tree={}, layers=[])
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("working_tree must be a string" in error for error in errors))
        self.assertTrue(any("layers must be an object" in error for error in errors))

    def test_test_layer_report_validates_optional_untracked_input_identity(self):
        invalid_reports = [
            ({"untracked_inputs": "new.rs"}, "untracked_inputs must be a path list"),
            ({"untracked_inputs": [1]}, "untracked_inputs must be a path list"),
            ({"untracked_inputs": ["new.rs"]}, "paths require an untracked inputs digest"),
            (
                {"untracked_inputs": [], "untracked_inputs_sha256": "bad"},
                "invalid test-layer report untracked inputs digest",
            ),
            (
                {"untracked_inputs": [], "untracked_inputs_sha256": 12},
                "invalid test-layer report untracked inputs digest",
            ),
        ]
        for fields, expected_error in invalid_reports:
            with self.subTest(fields=fields):
                path, _ = self.layer_report_fixture(**fields)
                errors, _ = VALIDATOR.validate_manifest(path, strict=True)
                self.assertTrue(any(expected_error in error for error in errors))

    def test_manifest_rejects_non_object_json_without_raising(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text("[]")
            errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("manifest must be an object" in error for error in errors))

    def test_manifest_rejects_non_string_source_and_log_digests_without_raising(self):
        path, manifest = self.fixture()
        manifest["source_sha256"] = {"source.rs": 64}
        manifest["log_sha256"] = {"focused.txt": None}
        path.write_text(json.dumps(manifest))
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertTrue(any("invalid source digest" in error for error in errors))
        self.assertTrue(any("invalid log digest" in error for error in errors))

    def test_invalid_source_digest_is_rejected_even_without_strict_mode(self):
        path, manifest = self.fixture()
        manifest["source_sha256"] = {"source.rs": "bad"}
        path.write_text(json.dumps(manifest))
        self.assertTrue(VALIDATOR.validate_manifest(path)[0])

    def test_source_drift_is_reported_without_failing_strict_validation(self):
        path, manifest = self.fixture()
        source = path.parent / "source.rs"
        source.write_text("current")
        manifest["source_sha256"] = {"source.rs": hashlib.sha256(b"previous").hexdigest()}
        path.write_text(json.dumps(manifest))
        with mock.patch.object(VALIDATOR, "ROOT", path.parent):
            errors, warnings = VALIDATOR.validate_manifest(path, strict=True)
        self.assertEqual(errors, [])
        self.assertTrue(warnings)

    def test_invalid_or_missing_log_digest_is_warning_or_strict_error(self):
        path, manifest = self.fixture()
        manifest["log_sha256"] = {"focused.txt": "bad", "absent.txt": "0" * 64}
        path.write_text(json.dumps(manifest))
        errors, warnings = VALIDATOR.validate_manifest(path)
        self.assertFalse(errors)
        self.assertEqual(len(warnings), 2)
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertEqual(len(errors), 2)

    def test_digest_fields_with_the_wrong_shape_are_rejected_in_strict_mode(self):
        path, manifest = self.fixture()
        manifest["source_sha256"] = ["bad"]
        manifest["log_sha256"] = ["bad"]
        path.write_text(json.dumps(manifest))
        errors, _ = VALIDATOR.validate_manifest(path, strict=True)
        self.assertEqual(len(errors), 2)

    def test_focused_result_requires_a_pass_count_and_matching_log_summary(self):
        path, manifest = self.fixture()
        manifest["validation"]["focused_test"]["result"] = "completed"
        path.write_text(json.dumps(manifest))
        self.assertTrue(VALIDATOR.validate_manifest(path, strict=True)[0])
        path, manifest = self.fixture()
        manifest["validation"]["focused_test"]["result"] = "2 passed, 0 failed"
        path.write_text(json.dumps(manifest))
        self.assertTrue(VALIDATOR.validate_manifest(path, strict=True)[0])

    def test_focused_command_mismatch_is_a_warning_without_strict_mode(self):
        path, manifest = self.fixture(selector="case::other")
        path.write_text(json.dumps(manifest))
        errors, warnings = VALIDATOR.validate_manifest(path)
        self.assertFalse(errors)
        self.assertTrue(warnings)

    def test_cli_reports_a_malformed_manifest_as_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            invalid = Path(directory) / "invalid.json"
            invalid.write_text("{")
            output = io.StringIO()
            with (
                mock.patch.object(sys, "argv", ["validate-evidence", "--strict", str(invalid)]),
                contextlib.redirect_stderr(output),
            ):
                result = VALIDATOR.main()
            self.assertEqual(result, 1)
            self.assertTrue(output.getvalue())

    def test_manifest_paths_resolve_from_the_script_root_and_default_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "evidence"
            first = evidence / "b" / "manifest.json"
            second = evidence / "a" / "manifest.json"
            first.parent.mkdir(parents=True)
            second.parent.mkdir(parents=True)
            first.write_text('{"schema_version": 1}')
            second.write_text('{"schema_version": 1}')
            with mock.patch.object(VALIDATOR, "ROOT", root), mock.patch.object(VALIDATOR, "EVIDENCE", evidence):
                self.assertEqual(VALIDATOR.manifests(["missing.json"]), [root / "missing.json"])
                self.assertEqual(VALIDATOR.manifests([]), [second, first])

    def test_cli_reports_valid_manifests_and_historical_warnings(self):
        path, manifest = self.fixture()
        manifest.pop("source_commit")
        path.write_text(json.dumps(manifest))
        output = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["validate-evidence", str(path)]),
            contextlib.redirect_stdout(output),
        ):
            result = VALIDATOR.main()
        self.assertEqual(result, 0)
        self.assertIn(str(path), output.getvalue())


if __name__ == "__main__":
    unittest.main()
