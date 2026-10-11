import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_doc_links", ROOT / "scripts/check-doc-links.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class DocLinkTests(unittest.TestCase):
    def broken(self, files):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            return [(str(p.relative_to(root)), target) for p, target in checker.broken_links(root, [root / n for n in files if n.endswith(".md")])]

    def test_a_link_to_an_existing_file_is_fine(self):
        self.assertEqual(self.broken({"a.md": "[b](b.md)", "b.md": "x"}), [])

    def test_a_link_to_a_missing_file_is_reported_with_its_target(self):
        self.assertEqual(self.broken({"a.md": "[b](gone.md)"}), [("a.md", "gone.md")])

    def test_anchors_and_queries_are_ignored_but_the_file_must_exist(self):
        self.assertEqual(self.broken({"a.md": "[b](b.md#top)", "b.md": "x"}), [])
        self.assertEqual(self.broken({"a.md": "[b](gone.md#top)"}), [("a.md", "gone.md")])

    def test_urls_and_pure_anchors_are_not_files(self):
        text = "[u](https://example.com/x) [m](mailto:a@b.c) [h](#here) [t](tel:123) [f](ftp://host/file)"
        self.assertEqual(self.broken({"a.md": text}), [])

    def test_links_resolve_relative_to_the_linking_file(self):
        files = {"docs/a.md": "[b](../crates/x.rs)", "crates/x.rs": "fn main() {}"}
        self.assertEqual(self.broken(files), [])

    def test_links_inside_code_fences_are_not_checked(self):
        self.assertEqual(self.broken({"a.md": "```\n[b](gone.md)\n```\n"}), [])

    def test_links_into_generated_target_output_are_plain_text(self):
        self.assertEqual(self.broken({"a.md": "[r](../target/quality/x/report.json)"}), [])

    def test_markdown_in_generated_package_output_is_not_indexed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            generated = root / "packaging/out/pkg/usr/share/doc/app/LICENSE.md"
            source = root / "docs/source.md"
            generated.parent.mkdir(parents=True)
            source.parent.mkdir(parents=True)
            generated.write_text("[missing](../not-shipped.md)")
            source.write_text("source")
            files = checker.markdown_files(root)
            self.assertIn(source, files)
            self.assertNotIn(generated, files)

    def test_a_directory_target_counts_as_existing(self):
        self.assertEqual(self.broken({"a.md": "[d](dir/)", "dir/f.txt": "x"}), [])


if __name__ == "__main__":
    unittest.main()
