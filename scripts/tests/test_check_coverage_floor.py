import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "check_coverage_floor", Path(__file__).resolve().parent.parent / "check-coverage-floor.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CoverageFloorTests(unittest.TestCase):
    def test_a_total_below_the_floor_fails(self):
        ok, message = module.verdict(56.9, 57.0)
        self.assertFalse(ok)
        self.assertIn("below the floor", message)

    def test_a_total_at_the_floor_passes(self):
        self.assertTrue(module.verdict(57.0, 57.0)[0])

    def test_a_total_a_point_above_asks_for_a_higher_floor(self):
        ok, message = module.verdict(58.2, 57.0)
        self.assertTrue(ok)
        self.assertIn("raise the floor", message)

    def test_the_percent_comes_from_the_llvm_cov_totals(self):
        report = {"data": [{"totals": {"lines": {"percent": 61.5}}}]}
        self.assertEqual(module.line_percent(report), 61.5)

    def test_the_checked_in_floor_is_a_number(self):
        self.assertGreater(float(module.FLOOR_FILE.read_text().strip()), 0)


if __name__ == "__main__":
    unittest.main()
