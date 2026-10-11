import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CiReportTests(unittest.TestCase):
    def test_collects_only_cargo_test_summary_lines(self):
        lines = [
            "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out",
            "test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out",
            "noise test result: ok. 7 passed;",
            "test result: unknown. 5 passed;",
        ]
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/ci-report.py"),
                "regex-test",
                sys.executable,
                "-c",
                f"print({chr(10).join(lines)!r})",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        evidence = next(line.removeprefix("Evidence: ") for line in result.stdout.splitlines() if line.startswith("Evidence: "))
        report = json.loads((Path(evidence) / "report.json").read_text())
        self.assertEqual(report["test_summaries"], lines[:2])


if __name__ == "__main__":
    unittest.main()
