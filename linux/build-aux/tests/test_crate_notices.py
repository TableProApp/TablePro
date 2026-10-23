import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packaging"))

import crate_notices  # noqa: E402

ARROW = "Apache Arrow\nCopyright 2016-2026 The Apache Software Foundation\n"


class CrateNoticesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def package(self, name, version, files):
        crate = self.root / f"{name}-{version}"
        crate.mkdir()
        (crate / "Cargo.toml").write_text("[package]\n", encoding="utf-8")
        for file_name, text in files.items():
            (crate / file_name).write_text(text, encoding="utf-8")
        return {"name": name, "version": version, "manifest_path": str(crate / "Cargo.toml")}

    def run_main(self, crates, packages):
        licenses = self.root / "third-party.json"
        metadata = self.root / "metadata.json"
        output = self.root / "NOTICE"
        licenses.write_text(json.dumps({"licenses": [], "crates": crates}), encoding="utf-8")
        metadata.write_text(json.dumps({"packages": packages}), encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = crate_notices.main(
                ["--licenses", str(licenses), "--metadata", str(metadata), "--output", str(output)]
            )
        return code, output.read_text(encoding="utf-8") if output.exists() else None, stderr.getvalue()

    def test_crates_sharing_a_notice_are_listed_once_above_it(self):
        packages = [
            self.package("arrow", "58.4.0", {"NOTICE.txt": ARROW}),
            self.package("arrow-array", "58.4.0", {"NOTICE.txt": ARROW}),
            self.package("serde", "1.0.0", {}),
        ]
        crates = [{"name": p["name"], "version": p["version"], "license": "Apache-2.0"} for p in packages]

        code, written, _ = self.run_main(crates, packages)

        self.assertEqual(code, 0)
        self.assertTrue(written.startswith(crate_notices.HEADER))
        self.assertEqual(written.count("Apache Arrow"), 1)
        self.assertIn("Used by: arrow 58.4.0, arrow-array 58.4.0\n\n" + ARROW, written)
        self.assertNotIn("serde", written)

    def test_a_crate_cargo_metadata_does_not_list_is_refused(self):
        code, written, stderr = self.run_main([{"name": "gone", "version": "1.0.0", "license": "MIT"}], [])

        self.assertEqual(code, 1)
        self.assertIsNone(written)
        self.assertIn("gone 1.0.0", stderr)

    def test_a_package_left_out_of_third_party_json_is_not_read(self):
        packages = [self.package("dev-only", "1.0.0", {"NOTICE": "Dev Only\n"})]

        code, written, _ = self.run_main([], packages)

        self.assertEqual(code, 0)
        self.assertEqual(written, crate_notices.HEADER)


if __name__ == "__main__":
    unittest.main()
