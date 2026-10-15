import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP = ROOT / "docs" / "regression-tests.md"

ROW = re.compile(r"^\|(.+)\|\s*$")
LINK = re.compile(r"^\[[^\]]+\]\(([^)#]+)\)$")
TICKED = re.compile(r"^`([^`]+)`$")
GUARD_NAME = re.compile(r"\bfn\s+(f\d{3}_\w+)")
JOB = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def sections():
    found = {}
    current = None
    for line in MAP.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            current = line[3:].strip()
            found[current] = []
            continue
        match = ROW.match(line)
        if current is None or not match:
            continue
        cells = [cell.strip() for cell in match.group(1).split("|")]
        if set(cells[0]) <= set("-: ") or cells[0] in ("Finding", "Helper"):
            continue
        found[current].append(cells)
    return found


def ticked(cell):
    match = TICKED.match(cell)
    if not match:
        raise AssertionError(f"not a backticked name: {cell}")
    return match.group(1)


def linked(cell):
    match = LINK.match(cell)
    if not match:
        raise AssertionError(f"not a link to a file: {cell}")
    return (MAP.parent / match.group(1)).resolve()


def defines(path, name):
    source = path.read_text(encoding="utf-8")
    return re.search(rf"\bfn\s+{re.escape(name)}\b", source) is not None


def finding_prefix(finding):
    return "f" + finding.removeprefix("F-") + "_"


class RegressionNamesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        found = sections()
        cls.findings = [cells[0] for cells in found["Findings"]]
        cls.guards = [(cells[0], cells[1], ticked(cells[2]), linked(cells[3])) for cells in found["Guards"]]
        cls.retired = [(ticked(cells[2]), linked(cells[3])) for cells in found["Retired helpers"]]
        cls.tests = [guard for guard in cls.guards if guard[1] != "ci-job"]
        cls.jobs = [guard for guard in cls.guards if guard[1] == "ci-job"]

    def test_the_map_names_findings_and_guards(self):
        self.assertTrue(self.findings)
        self.assertTrue(self.tests)

    def test_every_finding_has_a_guard(self):
        guarded = {guard[0] for guard in self.guards}
        for finding in self.findings:
            with self.subTest(finding=finding):
                self.assertTrue(finding in guarded, f"{finding} has no guard")
        for finding in guarded:
            with self.subTest(finding=finding):
                self.assertTrue(finding in self.findings, f"{finding} guards a finding the page does not list")

    def test_every_test_carries_its_finding(self):
        for finding, _, name, _ in self.tests:
            with self.subTest(name=name):
                self.assertTrue(name.startswith(finding_prefix(finding)), f"{name} is listed under {finding}")

    def test_every_listed_test_is_defined_in_its_file(self):
        for name, path in [(guard[2], guard[3]) for guard in self.tests] + self.retired:
            with self.subTest(name=name):
                self.assertTrue(path.is_file(), f"{path} does not exist")
                self.assertTrue(defines(path, name), f"no fn {name} in {path.relative_to(ROOT)}")

    def test_every_finding_named_test_is_listed(self):
        listed = {(name, path) for _, _, name, path in self.tests}
        for path in sorted((ROOT / "crates").rglob("*.rs")):
            for name in GUARD_NAME.findall(path.read_text(encoding="utf-8")):
                with self.subTest(name=name):
                    self.assertTrue(
                        (name, path.resolve()) in listed,
                        f"{path.relative_to(ROOT)} defines {name}, which docs/regression-tests.md does not list",
                    )

    def test_every_listed_ci_job_exists(self):
        workflows = {path for _, _, _, path in self.jobs}
        if not all(path.is_file() for path in workflows):
            self.skipTest("the workflow is outside this source tree")
        for _, _, job, path in self.jobs:
            with self.subTest(job=job):
                lines = path.read_text(encoding="utf-8").split("\njobs:\n", 1)[-1].splitlines()
                ids = {match.group(1) for match in map(JOB.match, lines) if match}
                self.assertTrue(job in ids, f"no job {job} in {path.name}")


if __name__ == "__main__":
    unittest.main()
