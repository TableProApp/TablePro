import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("gtk_runner", ROOT / "apps/linux/app/tests/gtk_runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def scenario(name):
    def body():
        pass

    body.__name__ = name
    return body


class Script:
    def __init__(self, outcomes):
        self.outcomes = {name: list(results) for name, results in outcomes.items()}
        self.ran = []

    def __call__(self, current):
        name = current.__name__
        self.ran.append(name)
        results = self.outcomes.get(name, [None])
        result = results.pop(0) if len(results) > 1 else results[0]
        if result is not None:
            raise AssertionError(result)


class GtkRunnerTests(unittest.TestCase):
    def run_all(self, names, outcomes, retries=0):
        script = Script(outcomes)
        lines = []
        failures = runner.run_scenarios([scenario(name) for name in names], script, retries, lines.append)
        return script, lines, failures

    def test_every_passing_scenario_is_reported_and_nothing_fails(self):
        script, lines, failures = self.run_all(["a", "b"], {})
        self.assertEqual(failures, [])
        self.assertTrue(lines[0].startswith("passed: a (duration: "))
        self.assertTrue(lines[1].startswith("passed: b (duration: "))

    def test_scenario_duration_is_reported_in_seconds(self):
        with patch.object(runner.time, "perf_counter", side_effect=[4.0, 4.125]):
            _, lines, failures = self.run_all(["a"], {})

        self.assertEqual(failures, [])
        self.assertEqual(lines, ["passed: a (duration: 0.125s)"])

    def test_a_failure_does_not_stop_the_scenarios_after_it(self):
        script, lines, failures = self.run_all(["a", "b", "c"], {"a": ["boom"]})
        self.assertEqual(script.ran, ["a", "b", "c"])
        self.assertEqual([name for name, _ in failures], ["a"])
        self.assertTrue(any(line.startswith("passed: c ") for line in lines))
        self.assertNotIn("passed: a", lines)

    def test_every_failing_scenario_is_collected_in_order(self):
        _, _, failures = self.run_all(["a", "b", "c"], {"a": ["one"], "c": ["three"]})
        self.assertEqual([(name, str(error)) for name, error in failures], [("a", "one"), ("c", "three")])

    def test_a_retry_that_passes_counts_as_a_pass_and_is_printed(self):
        script, lines, failures = self.run_all(["a"], {"a": ["flaky", None]}, retries=1)
        self.assertEqual(failures, [])
        self.assertEqual(script.ran, ["a", "a"])
        self.assertTrue(lines[0].startswith("RETRY: a failed after "))
        self.assertIn("running it again: flaky", lines[0])
        self.assertTrue(lines[-1].startswith("passed: a (duration: "))

    def test_each_retry_attempt_reports_its_own_duration(self):
        with patch.object(runner.time, "perf_counter", side_effect=[1.0, 1.2, 2.0, 2.4]):
            _, lines, failures = self.run_all(["a"], {"a": ["flaky", None]}, retries=1)

        self.assertEqual(failures, [])
        self.assertEqual(
            lines,
            ["RETRY: a failed after 0.200s, running it again: flaky", "passed: a (duration: 0.400s)"],
        )

    def test_a_final_failure_reports_its_duration(self):
        with patch.object(runner.time, "perf_counter", side_effect=[5.0, 5.75]):
            _, lines, failures = self.run_all(["a"], {"a": ["broken"]})

        self.assertEqual([name for name, _ in failures], ["a"])
        self.assertEqual(lines[0], "FAILED: a (duration: 0.750s)")

    def test_a_scenario_that_keeps_failing_is_reported_after_its_retries(self):
        script, lines, failures = self.run_all(["a", "b"], {"a": ["still broken"]}, retries=2)
        self.assertEqual(script.ran, ["a", "a", "a", "b"])
        self.assertEqual([name for name, _ in failures], ["a"])

    def test_each_failure_prints_its_assertion_text_for_log_filters(self):
        _, lines, _ = self.run_all(["a"], {"a": ["first line\nsecond line"]})
        self.assertTrue(any(line.startswith("FAILED: a ") for line in lines))
        self.assertIn("AssertionError: first line\nsecond line", lines)

    def test_the_summary_lists_every_failed_scenario(self):
        _, _, failures = self.run_all(["a", "b", "c"], {"a": ["x"], "c": ["y"]})
        self.assertEqual(runner.summary(failures), "2 GTK scenario(s) failed: a, c")


if __name__ == "__main__":
    unittest.main()
