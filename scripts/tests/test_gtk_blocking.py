import contextlib
import io
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "check-gtk-blocking.py"
SPEC = importlib.util.spec_from_file_location("check_gtk_blocking", SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class GtkBlockingTests(unittest.TestCase):
    def test_multiline_fully_qualified_sleep_is_rejected(self):
        source = "std :: thread :: sleep (Duration::from_secs(1));"
        self.assertEqual(CHECKER.violations(source), [(1, "std::thread::sleep")])

    def test_module_and_function_aliases_are_rejected(self):
        module_alias = "use std::thread as worker; worker::sleep(Duration::ZERO);"
        function_alias = "use std::thread::sleep as pause; pause(Duration::ZERO);"
        self.assertEqual(CHECKER.violations(module_alias)[0][1], "worker::sleep")
        self.assertEqual(CHECKER.violations(function_alias)[0][1], "pause(...)")

    def test_plain_thread_module_import_is_rejected(self):
        source = "use std::thread;\nthread::sleep(Duration::ZERO);"
        self.assertEqual(CHECKER.violations(source), [(2, "thread::sleep")])

    def test_tokenizer_tracks_nested_comments_escaped_newlines_and_raw_delimiters(self):
        source = '/* outer\n/* inner */ end */ let text = "first\\\nsecond";\nlet raw = br##"thread::sleep()"##;\nstd::thread::sleep(Duration::ZERO);'
        self.assertEqual(CHECKER.violations(source), [(5, "std::thread::sleep")])

    def test_tokenizer_keeps_character_literals_and_lifetimes_out_of_calls(self):
        source = "let marker = 'x';\nfn borrow<'a>(value: &'a str) -> &'a str { value }\nstd::thread::sleep(Duration::ZERO);"
        self.assertEqual(CHECKER.violations(source), [(3, "std::thread::sleep")])

    def test_cfg_test_ranges_cover_multiple_attributes_items_and_local_bodies(self):
        source = '''
            #[cfg(test)]
            #[allow(dead_code)]
            fn test_item() { std::thread::sleep(Duration::ZERO); }
            #[cfg(test)]
            const TEST_VALUE: bool = { std::thread::sleep(Duration::ZERO); true };
            #[cfg(test)]
            static TEST_STATIC: bool = false;
        '''
        self.assertEqual(CHECKER.violations(source), [])

    def test_malformed_test_item_without_a_body_remains_in_production_source(self):
        source = "#[cfg(test)] fn incomplete\nstd::thread::sleep(Duration::ZERO)"
        self.assertEqual(CHECKER.violations(source), [(2, "std::thread::sleep")])

    def test_imported_names_include_sleep_thread_alias_and_nested_thread_alias(self):
        source = '''
            use std::thread::sleep;
            use std::thread;
            use std::{thread as worker, io};
            use std::{thread};
        '''
        sleep_names, thread_names, block_on_names = CHECKER.imported_names(CHECKER.tokens(source))
        self.assertEqual(sleep_names, {"sleep"})
        self.assertEqual(thread_names, {"thread", "worker"})
        self.assertEqual(block_on_names, {"block_on"})

    def test_check_paths_skips_test_filenames_and_reports_production_source(self):
        with tempfile.TemporaryDirectory(dir=CHECKER.ROOT) as temp_dir:
            base = Path(temp_dir)
            test_file = base / "widget_tests.rs"
            tests_file = base / "tests.rs"
            source_file = base / "widget.rs"
            test_file.write_text("std::thread::sleep(Duration::ZERO);", encoding="utf-8")
            tests_file.write_text("block_on(future);", encoding="utf-8")
            source_file.write_text("fn run() {\n    block_on(future);\n}", encoding="utf-8")

            failures = CHECKER.check_paths([test_file, tests_file, source_file])

        self.assertEqual(failures, [(source_file.relative_to(CHECKER.ROOT), 2, "block_on")])

    def test_main_reports_production_violations_and_success(self):
        failure = (Path("apps/linux/app/src/ui/example.rs"), 8, "pause(...) ")
        output = io.StringIO()
        with patch.object(CHECKER, "check_paths", return_value=[failure]), contextlib.redirect_stdout(output):
            self.assertEqual(CHECKER.main(), 1)
        self.assertIn("example.rs:8: pause(...) ", output.getvalue())

        output = io.StringIO()
        with patch.object(CHECKER, "check_paths", return_value=[]), contextlib.redirect_stdout(output):
            self.assertEqual(CHECKER.main(), 0)
        self.assertIn("gtk-blocking: ok", output.getvalue())

    def test_sleep_import_tree_and_block_on_are_rejected(self):
        sleep_import = "use std::thread::{self, sleep as pause}; pause(Duration::ZERO);"
        block_on = "context.block_on(async { 1 });"
        self.assertEqual(CHECKER.violations(sleep_import)[0][1], "pause(...)")
        self.assertEqual(CHECKER.violations(block_on), [(1, "block_on")])
        alias = "use futures::executor::block_on as wait; wait(async { 1 });"
        self.assertEqual(CHECKER.violations(alias)[0][1], "wait")

    def test_test_only_items_comments_and_strings_are_allowed(self):
        source = '''
            #[cfg(test)]
            mod tests {
                fn wait() { std::thread::sleep(Duration::ZERO); }
            }
            // std::thread::sleep(Duration::ZERO);
            let text = r#"context.block_on(async {})"#;
        '''
        self.assertEqual(CHECKER.violations(source), [])

    def test_owned_relm4_commands_are_allowed(self):
        source = "sender.oneshot_command(|shutdown, _| async move { shutdown.await });"
        self.assertEqual(CHECKER.violations(source), [])


if __name__ == "__main__":
    unittest.main()
