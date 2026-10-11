import re
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
EARLY_EXIT = re.compile(r"\|\s*(grep\s+-\w*q\w*|head\b)")


class EarlyExitPipelineTests(unittest.TestCase):
    def test_pipefail_scripts_do_not_pipe_into_a_reader_that_exits_early(self):
        offenders = []
        for script in sorted(SCRIPTS.glob("*.sh")):
            text = script.read_text()
            if "pipefail" not in text:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                if EARLY_EXIT.search(line):
                    offenders.append(f"{script.name}:{number}: {line.strip()}")
        self.assertEqual(offenders, [], "capture the output first: an early-exiting reader makes the producer fail with SIGPIPE under pipefail")


if __name__ == "__main__":
    unittest.main()
