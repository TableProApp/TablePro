import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

CHECKER = Path(__file__).resolve().parents[1] / "check-panic-sites.sh"


class PanicSiteModuleResolutionTests(unittest.TestCase):
    def run_guard(self, files):
        temporary = tempfile.TemporaryDirectory(prefix="bookie-panic-sites-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "scripts").mkdir()
        (root / "baselines").mkdir()
        for directory in ("crates", "apps", "tests"):
            (root / directory).mkdir()
        checker = root / "scripts" / "check-panic-sites.sh"
        shutil.copy2(CHECKER, checker)
        (root / "baselines" / "panic-site-baselines.txt").write_text("", encoding="utf8")
        for path, source in files.items():
            target = root / "crates" / "sample" / "src" / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source, encoding="utf8")
        return subprocess.run(["bash", str(checker)], capture_output=True, text=True)

    def test_nested_test_module_does_not_hide_a_production_tests_rs(self):
        result = self.run_guard(
            {
                "lib.rs": "mod parent;\nmod tests;\n",
                "parent.rs": "#[cfg(test)]\nmod tests;\n",
                "parent/tests.rs": "#[test]\nfn test_case() { panic!(\"test\"); }\n",
                "tests.rs": "fn production() { panic!(\"production\"); }\n",
            }
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("src/tests.rs has 1 panic site(s) in production code", result.stderr)
        self.assertNotIn("src/parent/tests.rs has", result.stderr)

    def test_cfg_test_module_inside_a_file_module_uses_its_module_directory(self):
        result = self.run_guard(
            {
                "lib.rs": "#[cfg(test)]\nmod parent;\n",
                "parent.rs": "#[cfg(test)]\nmod tests;\n",
                "parent/tests.rs": "#[test]\nfn test_case() { panic!(\"test\"); }\n",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cfg_test_module_inside_mod_rs_uses_its_parent_directory(self):
        result = self.run_guard(
            {
                "lib.rs": "#[cfg(test)]\nmod parent;\n",
                "parent/mod.rs": "#[cfg(test)]\nmod tests;\n",
                "parent/tests.rs": "#[test]\nfn test_case() { panic!(\"test\"); }\n",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_crate_root_test_module_stays_relative_to_the_source_directory(self):
        result = self.run_guard(
            {
                "lib.rs": "#[cfg(test)]\nmod tests;\n",
                "tests.rs": "#[test]\nfn test_case() { panic!(\"test\"); }\n",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_explicit_test_module_path_stays_relative_to_the_declaring_file(self):
        result = self.run_guard(
            {
                "lib.rs": "#[cfg(test)]\n#[path = \"support/guard_tests.rs\"]\nmod tests;\n",
                "support/guard_tests.rs": "#[test]\nfn test_case() { panic!(\"test\"); }\n",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_children_inherit_the_test_gate_through_file_modules(self):
        result = self.run_guard(
            {
                "lib.rs": "#[cfg(test)]\nmod parent;\n",
                "parent.rs": "mod nested;\n",
                "parent/nested.rs": "#[test]\nfn test_case() { panic!(\"test\"); }\n",
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
