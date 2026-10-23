import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.compiled = self.root / "compiled" / "app"
        self.current = self.root / "current checkout" / "app"
        self.output = self.root / "output"
        self.output.mkdir()
        for app, content in ((self.compiled, "compiled checkout"), (self.current, "current checkout")):
            app.mkdir(parents=True)
            data = app.parent / "data"
            data.mkdir()
            (data / "com.tablepro.linux.gschema.xml").write_text(content)
        source = (ROOT / "apps/linux/app/build.rs").read_text()
        source += "\nmod glib_build_tools { pub fn compile_resources(_: &[&str], _: &str, _: &str) {} }\n"
        script = self.root / "build.rs"
        script.write_text(source)
        self.binary = self.root / "build-script"
        subprocess.run(
            ["rustc", "--edition=2024", str(script), "-o", str(self.binary)],
            env=os.environ | {"CARGO_MANIFEST_DIR": str(self.compiled)},
            check=True,
            capture_output=True,
            text=True,
        )
        tools = self.root / "bin"
        tools.mkdir()
        compiler = tools / "glib-compile-schemas"
        compiler.write_text(
            "#!/usr/bin/env python3\n"
            "from pathlib import Path\n"
            "import sys\n"
            "source = Path(sys.argv[-1])\n"
            "files = list(source.glob('*.xml'))\n"
            "if not files: sys.exit(53)\n"
            "output = Path(sys.argv[sys.argv.index('--targetdir') + 1])\n"
            "(output / 'gschemas.compiled').write_text(files[0].read_text())\n"
        )
        compiler.chmod(0o755)
        self.environment = os.environ | {
            "CARGO_MANIFEST_DIR": str(self.current),
            "OUT_DIR": str(self.output),
            "PATH": str(tools) + os.pathsep + os.environ.get("PATH", ""),
        }

    def assert_current_schema(self):
        result = subprocess.run(
            [str(self.binary)], cwd=self.current, env=self.environment, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "gschemas.compiled").read_text(), "current checkout")

    def test_reused_script_compiles_the_current_checkouts_schema(self):
        self.assert_current_schema()

    def test_reused_script_survives_removal_of_its_compilation_checkout(self):
        shutil.rmtree(self.compiled.parent)
        self.assert_current_schema()

    def test_missing_runtime_manifest_does_not_use_the_compilation_checkout(self):
        environment = self.environment.copy()
        environment.pop("CARGO_MANIFEST_DIR")
        result = subprocess.run(
            [str(self.binary)], cwd=self.current, env=environment, capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.output / "gschemas.compiled").exists())


if __name__ == "__main__":
    unittest.main()
