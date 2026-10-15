import importlib.util
import unittest
from pathlib import Path

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
        self.assertEqual(lines, ["passed: a", "passed: b"])

    def test_a_failure_does_not_stop_the_scenarios_after_it(self):
        script, lines, failures = self.run_all(["a", "b", "c"], {"a": ["boom"]})
        self.assertEqual(script.ran, ["a", "b", "c"])
        self.assertEqual([name for name, _ in failures], ["a"])
        self.assertIn("passed: c", lines)
        self.assertNotIn("passed: a", lines)

    def test_every_failing_scenario_is_collected_in_order(self):
        _, _, failures = self.run_all(["a", "b", "c"], {"a": ["one"], "c": ["three"]})
        self.assertEqual([(name, str(error)) for name, error in failures], [("a", "one"), ("c", "three")])

    def test_a_retry_that_passes_counts_as_a_pass_and_is_printed(self):
        script, lines, failures = self.run_all(["a"], {"a": ["flaky", None]}, retries=1)
        self.assertEqual(failures, [])
        self.assertEqual(script.ran, ["a", "a"])
        self.assertTrue(lines[0].startswith("RETRY: a failed once, running it again: flaky"))
        self.assertEqual(lines[-1], "passed: a")

    def test_a_scenario_that_keeps_failing_is_reported_after_its_retries(self):
        script, lines, failures = self.run_all(["a", "b"], {"a": ["still broken"]}, retries=2)
        self.assertEqual(script.ran, ["a", "a", "a", "b"])
        self.assertEqual([name for name, _ in failures], ["a"])

    def test_each_failure_prints_its_assertion_text_for_log_filters(self):
        _, lines, _ = self.run_all(["a"], {"a": ["first line\nsecond line"]})
        self.assertIn("FAILED: a", lines)
        self.assertIn("AssertionError: first line\nsecond line", lines)

    def test_the_summary_lists_every_failed_scenario(self):
        _, _, failures = self.run_all(["a", "b", "c"], {"a": ["x"], "c": ["y"]})
        self.assertEqual(runner.summary(failures), "2 GTK scenario(s) failed: a, c")


if __name__ == "__main__":
    unittest.main()
