import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_comment_lines", ROOT / "scripts/check-comment-lines.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class CommentLineTests(unittest.TestCase):
    def counts(self, files):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            return checker.comment_counts(root)

    def test_every_comment_form_counts_and_code_does_not(self):
        counts = self.counts({"crates/a/src/lib.rs": "// one\n  /// two\n//! three\nlet url = \"http://x\"; \nfn f() {}\n"})
        self.assertEqual(counts, {"crates/a/src/lib.rs": 3})

    def test_tests_directories_and_vendored_code_are_not_scanned(self):
        counts = self.counts({"crates/a/tests/t.rs": "// c\n", "vendor/x/src/lib.rs": "// c\n"})
        self.assertEqual(counts, {})

    def test_a_file_may_not_gain_comment_lines_and_a_new_file_starts_at_zero(self):
        baselines = checker.read_baselines("# header\ncrates/a/src/lib.rs 2\n")
        self.assertEqual(checker.problems({"crates/a/src/lib.rs": 2}, baselines), [])
        self.assertEqual(checker.problems({"crates/a/src/lib.rs": 1}, baselines), [])
        self.assertEqual(len(checker.problems({"crates/a/src/lib.rs": 3}, baselines)), 1)
        self.assertEqual(len(checker.problems({"crates/b/src/new.rs": 1}, baselines)), 1)

    def test_the_real_tree_is_within_its_baseline(self):
        counts = checker.comment_counts(ROOT)
        baselines = checker.read_baselines((ROOT / "comment-line-baselines.txt").read_text())
        self.assertEqual(checker.problems(counts, baselines), [])


if __name__ == "__main__":
    unittest.main()
