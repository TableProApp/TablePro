import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "check_crate_coverage_floors", Path(__file__).resolve().parent.parent / "check-crate-coverage-floors.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def report(*files):
    return {
        "data": [
            {"files": [{"filename": name, "summary": {"lines": {"count": count, "covered": covered}}}
                       for name, count, covered in files]}
        ]
    }


class CrateCoverageFloorTests(unittest.TestCase):
    def test_lines_are_summed_over_the_crate_source_only(self):
        data = report(
            ("/w/crates/drivers/postgres/src/a.rs", 100, 90),
            ("/w/crates/drivers/postgres/src/b.rs", 100, 70),
            ("/w/crates/drivers/postgres/tests/c.rs", 500, 0),
            ("/w/crates/drivers/postgres-extra/src/d.rs", 100, 0),
        )
        self.assertEqual(module.crate_lines(data, "crates/drivers/postgres"), (200, 160))

    def test_a_crate_below_its_floor_fails_and_names_the_crate(self):
        ok, message = module.verdict("crates/core", 100, 80, 90)
        self.assertFalse(ok)
        self.assertIn("crates/core", message)
        self.assertIn("below the floor", message)

    def test_a_crate_at_its_floor_passes(self):
        self.assertTrue(module.verdict("crates/core", 100, 90, 90)[0])

    def test_a_crate_far_above_its_floor_asks_for_a_higher_one(self):
        ok, message = module.verdict("crates/core", 100, 97, 90)
        self.assertTrue(ok)
        self.assertIn("raise the floor to 94", message)

    def test_a_crate_missing_from_the_report_fails_instead_of_passing_silently(self):
        ok, message = module.verdict("crates/core", 0, 0, 90)
        self.assertFalse(ok)
        self.assertIn("no source lines", message)

    def test_only_checks_just_the_named_crates(self):
        data = report(("/w/crates/core/src/a.rs", 100, 50), ("/w/crates/policy/src/a.rs", 100, 99))
        floors = {"crates/core": 90.0, "crates/policy": 90.0}
        self.assertEqual([ok for ok, _ in module.check(data, floors, ["crates/policy"])], [True])
        self.assertEqual([ok for ok, _ in module.check(data, floors, None)], [False, True])

    def test_an_unknown_crate_in_only_fails(self):
        self.assertFalse(module.check(report(), {"crates/core": 90.0}, ["crates/nope"])[0][0])

    def test_floors_parse_and_reject_a_malformed_line(self):
        self.assertEqual(module.parse_floors("# c\n\ncrates/core 92\n"), {"crates/core": 92.0})
        with self.assertRaises(ValueError):
            module.parse_floors("crates/core\n")

    def test_the_checked_in_floors_file_parses_and_has_sane_values(self):
        floors = module.parse_floors(module.DEFAULT_FLOORS.read_text())
        self.assertGreaterEqual(len(floors), 6)
        for crate, floor in floors.items():
            self.assertTrue((module.DEFAULT_FLOORS.parent.parent / crate / "Cargo.toml").exists(), crate)
            self.assertTrue(50 <= floor <= 100, (crate, floor))


if __name__ == "__main__":
    unittest.main()
