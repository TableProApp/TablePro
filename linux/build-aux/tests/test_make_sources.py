import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "packaging" / "make-sources.sh"

NOT_KEYS = ["key", "phc_", "phc_abc def", "phc_abc\n", "phc_abc$(id)", "phc_abc'", "-Dprofile=development"]


def run(*args):
    with tempfile.TemporaryDirectory() as work:
        out = Path(work, "sources")
        result = subprocess.run(
            ["sh", str(SCRIPT), *args, str(out)], capture_output=True, text=True, check=False
        )
        return result, out.exists()


class MakeSourcesTest(unittest.TestCase):
    def test_a_posthog_key_that_is_not_one_is_refused_before_anything_runs(self):
        for key in NOT_KEYS:
            with self.subTest(key=key):
                result, made = run("--posthog-key", key)

                self.assertEqual(result.returncode, 2)
                self.assertIn("takes a PostHog project key", result.stderr)
                self.assertFalse(made)


if __name__ == "__main__":
    unittest.main()
