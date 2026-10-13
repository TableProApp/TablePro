import importlib.util
import tempfile
import unittest
from collections import Counter
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "check_mutants_baseline", Path(__file__).resolve().parent.parent / "check-mutants-baseline.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MutantBaselineTests(unittest.TestCase):
    def test_line_and_column_numbers_do_not_change_the_key(self):
        a = module.key("crates/core/src/a.rs:12:5: replace foo -> bool with true")
        b = module.key("crates/core/src/a.rs:99:9: replace foo -> bool with true")
        self.assertEqual(a, b)
        self.assertEqual(a, "crates/core/src/a.rs: replace foo -> bool with true")

    def test_a_range_location_is_handled(self):
        self.assertEqual(
            module.key("crates/core/src/a.rs:12:5-12:20: replace x with y"), "crates/core/src/a.rs: replace x with y"
        )

    def test_a_missed_mutant_that_is_in_the_baseline_passes(self):
        mutant = Counter({"a.rs: replace f with 1": 1})
        self.assertTrue(module.judge(mutant, mutant, 2)[0])

    def test_a_new_missed_mutant_fails_and_is_named(self):
        ok, lines = module.judge(Counter({"a.rs: replace f with 1": 1}), Counter(), 2)
        self.assertFalse(ok)
        self.assertTrue(any("NEW missed mutant: a.rs: replace f with 1" in line for line in lines))

    def test_a_second_copy_of_a_known_mutant_is_new(self):
        known = Counter({"a.rs: replace f with 1": 1})
        self.assertFalse(module.judge(Counter({"a.rs: replace f with 1": 2}), known, 2)[0])

    def test_a_mutant_that_is_now_caught_is_reported_but_does_not_fail(self):
        ok, lines = module.judge(Counter(), Counter({"a.rs: replace f with 1": 1}), 0)
        self.assertTrue(ok)
        self.assertTrue(any("now caught" in line for line in lines))

    def test_a_run_that_did_not_complete_fails(self):
        for status in (1, 4, 70, 137):
            self.assertFalse(module.judge(Counter(), Counter(), status)[0], status)

    def test_the_files_are_read_and_a_missing_baseline_means_none_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "out" / "mutants.out").mkdir(parents=True)
            (root / "out" / "mutants.out" / "missed.txt").write_text("a.rs:1:1: replace f with 1\n")
            self.assertEqual(module.main(["x", "core", str(root / "out"), "2", "--baseline-dir", str(root)]), 1)
            (root / "core.txt").write_text("# accepted\na.rs:7:7: replace f with 1\n")
            self.assertEqual(module.main(["x", "core", str(root / "out"), "2", "--baseline-dir", str(root)]), 0)


if __name__ == "__main__":
    unittest.main()
