from pathlib import Path
import importlib.util
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

    def test_an_unrecognised_log_is_unknown(self):
        self.assertEqual(self.tag("everything is fine\nJob failed"), "unknown")

    def test_the_evidence_is_the_matching_line(self):
        _, _, evidence = classifier.classify_log("a\nMySQL fixture did not become ready\nb")
        self.assertEqual(evidence, "MySQL fixture did not become ready")

    def test_a_log_that_ends_without_a_result_is_infrastructure(self):
        self.assertEqual(self.tag("test a ... ok\ntest b ... ok\n"), "infra")

    def test_a_finished_log_with_nothing_recognised_stays_unknown(self):
        self.assertEqual(self.tag("something odd\n\U0001f3c1  Job failed"), "unknown")


if __name__ == "__main__":
    unittest.main()
