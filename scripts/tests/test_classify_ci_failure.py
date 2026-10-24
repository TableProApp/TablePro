import contextlib
import io
import json
import os
from pathlib import Path
import importlib.util
import tempfile
from unittest import mock
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("classify_ci_failure", ROOT / "scripts/classify-ci-failure.py")
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


class ClassifyCiFailureTests(unittest.TestCase):
    def tag(self, text):
        return classifier.classify_log(text)[0]

    def test_an_image_pull_timeout_is_infrastructure(self):
        text = 'start MongoDB fixture: Client(PullImage { descriptor: "mongo:7", err: RequestTimeoutError })'
        self.assertEqual(self.tag(text), "infra")

    def test_a_fixture_that_never_became_ready_is_infrastructure(self):
        self.assertEqual(self.tag("MySQL fixture did not become ready\nJob failed"), "infra")

    def test_a_compiler_crash_is_infrastructure(self):
        self.assertEqual(self.tag("sccache: Compiler killed by signal 11\nerror: could not compile `tablepro-app`"), "infra")

    def test_a_missing_runner_bind_path_is_infrastructure(self):
        text = 'invalid mount config for type "bind": bind source path does not exist: /tmp/.tmp1cLtTA'
        self.assertEqual(self.tag(text), "infra")

    def test_infrastructure_wins_over_the_failing_test_line_it_caused(self):
        text = "test mysql_accepts_a_query ... FAILED\nthread 'x' panicked at tests/integration.rs:61:41:\nstart mysql container: StartupTimeout"
        self.assertEqual(self.tag(text), "infra")

    def test_a_window_that_did_not_appear_is_gui_timing(self):
        text = "AssertionError: application did not expose its expected window: INFO starting"
        self.assertEqual(self.tag(text), "gui-timing")

    def test_a_crash_of_the_application_is_code(self):
        self.assertEqual(self.tag("AssertionError: application exited with -6: thread caused non-unwinding panic"), "code")

    def test_a_failing_unit_test_is_code(self):
        text = "test ui::grid::local_sort::sorts ... FAILED\nthread 'x' panicked at src/lib.rs:10:5:\nassertion failed"
        self.assertEqual(self.tag(text), "code")

    def test_a_compile_error_is_code(self):
        self.assertEqual(self.tag("error[E0063]: missing field `preview` in initializer"), "code")

    def test_a_missing_accessible_node_is_ambiguous_not_timing(self):
        self.assertEqual(self.tag("AssertionError: expected an accessible name containing 'Rows 1 - 3' to appear:"), "gui")

    def test_a_fixture_connection_refused_is_infrastructure(self):
        text = "thread 'disconnection::x' panicked at crates/drivers/clickhouse/tests/support/clickhouse.rs:39:42:\nconnect: ConnectionRefused"
        self.assertEqual(self.tag(text), "infra")

    def test_a_startup_layout_abort_is_code_not_a_missing_window(self):
        text = "AssertionError: application did not expose its expected window: Gtk-CRITICAL **: gtk_widget_measure: assertion 'for_size >= -1' failed"
        self.assertEqual(self.tag(text), "code")

    def test_a_linker_bus_error_is_infrastructure_not_a_lint_failure(self):
        text = "collect2: fatal error: ld terminated with signal 7 [Bus error]\nerror: could not compile `tablepro-agentd` (bin \"tablepro-agentd\") due to 1 previous error\nJob failed"
        self.assertEqual(self.tag(text), "infra")

    def test_a_missing_fixture_image_is_infrastructure(self):
        text = "Error response from daemon: No such image: clickhouse/clickhouse-server:24.8-alpine\nJob failed"
        self.assertEqual(self.tag(text), "infra")

    def test_a_fixture_container_that_exited_before_the_tests_is_infrastructure(self):
        text = "container tablepro-driver-tls-mongo-1 exited (48)\nJob failed"
        self.assertEqual(self.tag(text), "infra")

    def test_an_unrecognised_log_is_unknown(self):
        self.assertEqual(self.tag("everything is fine\nJob failed"), "unknown")

    def test_the_evidence_is_the_matching_line(self):
        _, _, evidence = classifier.classify_log("a\nMySQL fixture did not become ready\nb")
        self.assertEqual(evidence, "MySQL fixture did not become ready")

    def test_a_log_that_ends_without_a_result_is_infrastructure(self):
        self.assertEqual(self.tag("test a ... ok\ntest b ... ok\n"), "infra")

    def test_a_finished_log_with_nothing_recognised_stays_unknown(self):
        self.assertEqual(self.tag("something odd\n\U0001f3c1  Job failed"), "unknown")

    def test_signatures_outside_the_log_tail_do_not_override_recent_evidence(self):
        text = "No such image: old-image\n" + ("x" * classifier.TAIL_BYTES) + "\nnew failure\nJob failed"
        tag, _, evidence = classifier.classify_log(text)
        self.assertEqual(tag, "unknown")
        self.assertEqual(evidence, "")

    def test_api_base_prefers_an_explicit_repository_api(self):
        with mock.patch.dict(os.environ, {"FORGEJO_API": "http://forgejo.example/api/v1/repos/team/app"}):
            self.assertEqual(classifier.api_base(), "http://forgejo.example/api/v1/repos/team/app")

    def test_api_base_derives_repository_path_from_remote(self):
        result = mock.Mock(stdout="http://forgejo.example/team/app.git\n")
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(classifier.subprocess, "run", return_value=result):
            self.assertEqual(classifier.api_base(), "http://forgejo.example/api/v1/repos/team/app")

    def test_api_base_rejects_a_remote_without_a_server_and_repository(self):
        result = mock.Mock(stdout="/local/path/app.git\n")
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(classifier.subprocess, "run", return_value=result):
            with self.assertRaises(SystemExit):
                classifier.api_base()

    def test_classify_run_fetches_logs_only_for_failed_jobs(self):
        jobs = [
            {"id": 1, "name": "passed", "status": "success"},
            {"id": 2, "name": "failed", "status": "failure"},
        ]
        with (
            mock.patch.object(classifier, "read_token", return_value="secret"),
            mock.patch.object(classifier, "api_base", return_value="http://forgejo/api"),
            mock.patch.object(classifier, "fetch", side_effect=[json.dumps({"jobs": jobs}), "No such image: postgres"])
                as fetch,
        ):
            result = classifier.classify_run(42, tail=1)
        self.assertEqual(len(result), 1)
        name, tag, _, evidence, tail = result[0]
        self.assertEqual((name, tag, evidence, tail), ("failed", "infra", "No such image: postgres", ["No such image: postgres"]))
        self.assertEqual(
            [call.args[0] for call in fetch.call_args_list],
            ["http://forgejo/api/actions/runs/42/jobs", "http://forgejo/api/actions/jobs/2/logs"],
        )

    def test_cli_log_prints_classification_and_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "job.log"
            path.write_text("No such image: postgres\n")
            output = io.StringIO()
            with mock.patch.object(classifier.sys, "argv", ["classify", "--log", str(path)]), contextlib.redirect_stdout(output):
                classifier.main()
        self.assertIn("infra:", output.getvalue())
        self.assertIn("No such image: postgres", output.getvalue())

    def test_cli_lists_runs_from_a_list_shaped_api_response(self):
        runs = [{"id": 12, "status": "success", "event": "push", "prettyref": "refs/heads/linux", "title": "check"}]
        output = io.StringIO()
        with (
            mock.patch.object(classifier.sys, "argv", ["classify", "--list", "4"]),
            mock.patch.object(classifier, "read_token", return_value="secret"),
            mock.patch.object(classifier, "api_base", return_value="http://forgejo/api"),
            mock.patch.object(classifier, "fetch", return_value=json.dumps(runs)),
            contextlib.redirect_stdout(output),
        ):
            classifier.main()
        self.assertIn("12", output.getvalue())
        self.assertIn("refs/heads/linux", output.getvalue())

    def test_cli_lists_jobs_and_classifies_failed_run_with_tail(self):
        jobs_output = io.StringIO()
        with (
            mock.patch.object(classifier.sys, "argv", ["classify", "--jobs", "42"]),
            mock.patch.object(classifier, "read_token", return_value="secret"),
            mock.patch.object(classifier, "api_base", return_value="http://forgejo/api"),
            mock.patch.object(classifier, "fetch", return_value=json.dumps([{"name": "unit", "status": "success"}])),
            contextlib.redirect_stdout(jobs_output),
        ):
            classifier.main()
        self.assertIn("success", jobs_output.getvalue())
        self.assertIn("unit", jobs_output.getvalue())
        run_output = io.StringIO()
        with (
            mock.patch.object(classifier.sys, "argv", ["classify", "--run", "42", "--tail", "1"]),
            mock.patch.object(classifier, "classify_run", return_value=[("unit", "code", "test failed", "failed test", ["failed test"])]),
            contextlib.redirect_stdout(run_output),
        ):
            classifier.main()
        self.assertIn("summary: 1 code", run_output.getvalue())
        self.assertIn("failed test", run_output.getvalue())


if __name__ == "__main__":
    unittest.main()
