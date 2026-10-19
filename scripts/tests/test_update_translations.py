import importlib.util
import contextlib
import io
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "update-translations.py"
SPEC = importlib.util.spec_from_file_location("update_translations", SCRIPT)
TRANSLATIONS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRANSLATIONS)


class TranslationGenerationTests(unittest.TestCase):
    def test_finds_qualified_calls_and_returns_sorted_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "apps/linux/app/src"
            (source / "z.rs").parent.mkdir(parents=True)
            (source / "z.rs").write_text('crate::tr!("later");\n', encoding="utf-8")
            (source / "a.rs").write_text('tr!("first");\n', encoding="utf-8")
            (source / "unused.rs").write_text('println!("not translated");\n', encoding="utf-8")
            self.assertEqual(
                [path.relative_to(root).as_posix() for path in TRANSLATIONS.translation_sources(root)],
                ["apps/linux/app/src/a.rs", "apps/linux/app/src/z.rs"],
            )

    def test_rejects_translation_calls_without_a_string_literal(self):
        with self.assertRaisesRegex(RuntimeError, "must start with a string literal"):
            TRANSLATIONS.extraction_source('tr!(format!("message"));')

    def test_extracts_rust_strings_without_parsing_the_rust_file(self):
        source = r'''crate::tr!("Hello \
            world\u{2026}");
let value = 3;
'''
        self.assertEqual(TRANSLATIONS.extraction_source(source), 'tr("Hello world…")\n\n\n')
        self.assertEqual(TRANSLATIONS.extraction_source('crate::tr!(\n    "Next line");\n'), '\ntr("Next line")\n')

    def test_normalizes_only_catalog_creation_timestamp(self):
        pot = '"POT-Creation-Date: 2026-10-19 10:20+0200\\n"\nmsgid "A"\n'
        normalized = TRANSLATIONS.normalize_catalog(pot)
        self.assertTrue(normalized.startswith('"POT-Creation-Date: 1970-01-01 00:00+0000'))
        self.assertIn('msgid "A"', normalized)

    def test_reports_pot_and_potfiles_drift_independently(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog = root / "apps/linux/po/tablepro.pot"
            potfiles = root / "apps/linux/po/POTFILES.in"
            catalog.parent.mkdir(parents=True)
            catalog.write_text("current pot\n", encoding="utf-8")
            potfiles.write_text("stale source.rs\n", encoding="utf-8")
            self.assertEqual(
                TRANSLATIONS.stale_outputs(root, "current pot\n", "expected source.rs\n"),
                (potfiles,),
            )
            self.assertEqual(
                TRANSLATIONS.stale_outputs(root, "stale pot\n", "stale source.rs\n"),
                (catalog,),
            )

    def test_generates_catalog_and_normalizes_gettext_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "apps/linux/app/src/view.rs"
            source.parent.mkdir(parents=True)
            source.write_text('crate::tr!("Hello");\n', encoding="utf-8")
            manifest = root / "apps/linux/app/Cargo.toml"
            manifest.parent.mkdir(parents=True, exist_ok=True)
            manifest.write_text('[package]\nversion = "0.2.0"\n', encoding="utf-8")

            def write_catalog(command, cwd, env, check):
                self.assertIn("--language=Python", command)
                self.assertIn("--package-version=0.2.0", command)
                self.assertEqual(env["SOURCE_DATE_EPOCH"], "0")
                output = Path(next(argument.removeprefix("--output=") for argument in command if argument.startswith("--output=")))
                output.write_text(
                    '"POT-Creation-Date: 2026-10-19 00:00+0000\\n"\n'
                    '"Content-Type: text/plain; charset=CHARSET\\n"\n'
                    "#, python-brace-format\nmsgid \"Hello {name}\"\nmsgstr \"\"\n",
                    encoding="utf-8",
                )
                return TRANSLATIONS.subprocess.CompletedProcess(command, 0)

            with patch.object(TRANSLATIONS.subprocess, "run", side_effect=write_catalog):
                catalog, potfiles = TRANSLATIONS.generate_catalog(root)
            self.assertIn('"POT-Creation-Date: 1970-01-01 00:00+0000\\n"', catalog)
            self.assertIn('"Content-Type: text/plain; charset=UTF-8\\n"', catalog)
            self.assertIn("#, rust-format", catalog)
            self.assertEqual(potfiles, "apps/linux/app/src/view.rs\n")

    def test_fails_generation_when_there_are_no_translation_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "no Rust translation source files"):
                TRANSLATIONS.generate_catalog(Path(directory))

    def test_read_exact_returns_none_for_missing_catalog_files(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(TRANSLATIONS.read_exact(Path(directory) / "missing.pot"))

    def test_check_mode_accepts_current_catalogs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog, potfiles = self.catalog_paths(root)
            catalog.parent.mkdir(parents=True)
            catalog.write_text("catalog\n", encoding="utf-8")
            potfiles.write_text("source.rs\n", encoding="utf-8")
            with self.patched_main(root, catalog, potfiles, ("catalog\n", "source.rs\n"), ["--check"]):
                self.assertEqual(TRANSLATIONS.main(), 0)

    def test_check_mode_reports_stale_catalogs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog, potfiles = self.catalog_paths(root)
            catalog.parent.mkdir(parents=True)
            catalog.write_text("old catalog\n", encoding="utf-8")
            potfiles.write_text("source.rs\n", encoding="utf-8")
            error = io.StringIO()
            with self.patched_main(root, catalog, potfiles, ("new catalog\n", "source.rs\n"), ["--check"]), contextlib.redirect_stderr(error):
                self.assertEqual(TRANSLATIONS.main(), 1)
            self.assertIn("tablepro.pot", error.getvalue())
            self.assertIn("@@", error.getvalue())

    def test_update_mode_writes_both_catalog_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            catalog, potfiles = self.catalog_paths(root)
            expected = ("catalog\n", "source.rs\n")
            with self.patched_main(root, catalog, potfiles, expected, []):
                self.assertEqual(TRANSLATIONS.main(), 0)
            self.assertEqual(catalog.read_text(encoding="utf-8"), expected[0])
            self.assertEqual(potfiles.read_text(encoding="utf-8"), expected[1])

    def test_generation_errors_return_failure(self):
        error = io.StringIO()
        with (
            patch.object(TRANSLATIONS, "generate_catalog", side_effect=RuntimeError("generation failed")),
            patch.object(sys, "argv", ["update-translations.py"]),
            contextlib.redirect_stderr(error),
        ):
            self.assertEqual(TRANSLATIONS.main(), 1)
        self.assertIn("generation failed", error.getvalue())

    def test_script_entry_point_exits_with_catalog_failure(self):
        def write_catalog(command, cwd, env, check):
            output = Path(next(argument.removeprefix("--output=") for argument in command if argument.startswith("--output=")))
            output.write_text('msgid "stub"\nmsgstr ""\n', encoding="utf-8")
            return TRANSLATIONS.subprocess.CompletedProcess(command, 0)

        with (
            patch.object(TRANSLATIONS.subprocess, "run", side_effect=write_catalog),
            patch.object(sys, "argv", [str(SCRIPT), "--check"]),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as raised,
        ):
            runpy.run_path(str(SCRIPT), run_name="__main__")
        self.assertEqual(raised.exception.code, 1)

    def catalog_paths(self, root):
        return root / "apps/linux/po/tablepro.pot", root / "apps/linux/po/POTFILES.in"

    def patched_main(self, root, catalog, potfiles, generated, arguments):
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(TRANSLATIONS, "ROOT", root))
        stack.enter_context(patch.object(TRANSLATIONS, "CATALOG", catalog))
        stack.enter_context(patch.object(TRANSLATIONS, "POTFILES", potfiles))
        stack.enter_context(patch.object(TRANSLATIONS, "generate_catalog", return_value=generated))
        stack.enter_context(patch.object(sys, "argv", ["update-translations.py", *arguments]))
        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        return stack


if __name__ == "__main__":
    unittest.main()
