import contextlib
import importlib.util
import io
import runpy
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "check-doc-symbols.py"
SPEC = importlib.util.spec_from_file_location("check_doc_symbols", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class DocSymbolTests(unittest.TestCase):
    def test_accepts_a_documented_type_that_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text("Uses `Widget`.\n", encoding="utf-8")
            (root / "widget.rs").write_text("pub struct Widget {}\n", encoding="utf-8")
            self.assertEqual(CHECKER.check_references(root, (("guide.md", "widget.rs", "Widget", "struct"),)), [])

    def test_rejects_a_stale_source_symbol(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text("Uses `Widget`.\n", encoding="utf-8")
            (root / "widget.rs").write_text("pub struct Gadget {}\n", encoding="utf-8")
            self.assertIn(
                "guide.md: struct Widget is missing from widget.rs",
                CHECKER.check_references(root, (("guide.md", "widget.rs", "Widget", "struct"),)),
            )

    def test_ignores_a_symbol_mentioned_only_in_a_comment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text("Uses `Widget`.\n", encoding="utf-8")
            (root / "widget.rs").write_text("// pub struct Widget {}\npub struct Gadget {}\n", encoding="utf-8")
            self.assertIn(
                "guide.md: struct Widget is missing from widget.rs",
                CHECKER.check_references(root, (("guide.md", "widget.rs", "Widget", "struct"),)),
            )

    def test_requires_a_complete_documented_identifier(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text("Uses `Widgetish`.\n", encoding="utf-8")
            (root / "widget.rs").write_text("pub struct Widget {}\n", encoding="utf-8")
            self.assertIn(
                "guide.md: named symbol is missing: Widget",
                CHECKER.check_references(root, (("guide.md", "widget.rs", "Widget", "struct"),)),
            )

    def test_rejects_a_missing_named_source_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text("Run `tool.sh`.\n", encoding="utf-8")
            self.assertIn(
                "guide.md: referenced source path is missing: tool.sh",
                CHECKER.check_references(root, (("guide.md", "tool.sh", "tool.sh", "file"),)),
            )

    def test_rejects_a_missing_documentation_page(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertIn(
                "guide.md: documentation page is missing",
                CHECKER.check_references(root, (("guide.md", "widget.rs", "Widget", "struct"),)),
            )

    def test_rejects_a_symbol_absent_from_the_documentation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text("Uses another type.\n", encoding="utf-8")
            (root / "widget.rs").write_text("pub struct Widget {}\n", encoding="utf-8")
            self.assertIn(
                "guide.md: named symbol is missing: Widget",
                CHECKER.check_references(root, (("guide.md", "widget.rs", "Widget", "struct"),)),
            )

    def test_accepts_a_documented_existing_script(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "guide.md").write_text("Run `tool.sh`.\n", encoding="utf-8")
            (root / "tool.sh").write_text("#!/bin/sh\n", encoding="utf-8")
            self.assertEqual(CHECKER.check_references(root, (("guide.md", "tool.sh", "tool.sh", "file"),)), [])

    def test_direct_entry_point_reports_success(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as raised:
                runpy.run_path(str(SCRIPT), run_name="__main__")
        self.assertEqual(raised.exception.code, 0)
        self.assertIn("doc symbols: ok", output.getvalue())


if __name__ == "__main__":
    unittest.main()
