import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "rpm" / "copr-sources.sh"


def run(payload):
    with tempfile.TemporaryDirectory() as work:
        Path(work, "hook_payload").write_text(payload)
        result = subprocess.run(
            ["sh", str(SCRIPT)], cwd=work, capture_output=True, text=True, check=False
        )
        return result, sorted(path.name for path in Path(work).iterdir())


class CoprSourcesTest(unittest.TestCase):
    def test_other_releases_of_the_repository_are_refused(self):
        for tag in ["v0.40.0", "plugin-trino-v1.0.14", "linux-vnext", ""]:
            with self.subTest(tag=tag):
                result, files = run(tag)

                self.assertEqual(result.returncode, 1)
                self.assertIn("not a Linux release tag", result.stderr)
                self.assertEqual(files, ["hook_payload"])

    def test_a_tag_that_would_change_the_url_is_refused(self):
        for tag in ["linux-v0.1.0/../../main", "linux-v0.1.0?x", "linux-v0.1.0 x"]:
            with self.subTest(tag=tag):
                result, files = run(tag)

                self.assertEqual(result.returncode, 1)
                self.assertIn("not a release tag", result.stderr)
                self.assertEqual(files, ["hook_payload"])


if __name__ == "__main__":
    unittest.main()
