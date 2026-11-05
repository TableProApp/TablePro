import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packaging"))

import license_metadata  # noqa: E402
import source_inventory  # noqa: E402

REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


class InventoryTests(unittest.TestCase):
    def setUp(self):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        self.dir = Path(workdir.name)
        self.packages = []
        self.source = {"crates": [], "files": []}
        (self.dir / "bundled").mkdir()
        (self.dir / "root").mkdir()

    def add_crate(self, name, version, license="MIT", authors=(), files=None, source=REGISTRY):
        directory = self.dir / "registry" / f"{name}-{version}"
        directory.mkdir(parents=True)
        (directory / "Cargo.toml").write_text("[package]\n", encoding="utf-8")
        for path, text in (files or {}).items():
            (directory / path).parent.mkdir(parents=True, exist_ok=True)
            (directory / path).write_text(text, encoding="utf-8")
        self.packages.append(
            {
                "name": name,
                "version": version,
                "source": source,
                "license": license,
                "authors": list(authors),
                "manifest_path": str(directory / "Cargo.toml"),
            }
        )
        return directory

    def inventory(self, clarified=None):
        (self.dir / "source.json").write_text(json.dumps(self.source), encoding="utf-8")
        return source_inventory.inventory(
            {"packages": self.packages},
            clarified or {},
            self.dir / "source.json",
            self.dir / "bundled",
            self.dir / "root",
        )

    def test_every_registry_crate_is_a_unit_whatever_its_kind_or_target(self):
        # cc only builds C code, windows-sys only targets Windows and
        # testcontainers only serves tests: cargo vendor ships all three.
        self.add_crate("cc", "1.4.6", "MIT OR Apache-2.0", files={"LICENSE-MIT": "Copyright (c) 2014 Alex Crichton\n"})
        self.add_crate("windows-sys", "0.61.2", "MIT OR Apache-2.0", authors=["Microsoft"])
        self.add_crate("testcontainers", "0.27.3", "MIT OR Apache-2.0")
        self.add_crate("tablepro", "0.1.0", "AGPL-3.0-or-later", source=None)

        _, crates, nested = self.inventory()

        self.assertEqual(
            [unit["files"] for unit in crates],
            [["vendor/cc-1.4.6/*"], ["vendor/testcontainers-0.27.3/*"], ["vendor/windows-sys-0.61.2/*"]],
        )
        self.assertEqual(nested, [])

    def test_a_crate_carries_every_license_file_at_its_root_as_shipped(self):
        self.add_crate(
            "regex",
            "1.12.0",
            "MIT OR Apache-2.0",
            files={"LICENSE-MIT": "MIT text\n", "LICENSE-APACHE": "Apache text\n", "licenses/LICENSE-rand": "rand text\n", "README.md": "x\n"},
        )

        unit = self.inventory()[1][0]

        self.assertEqual(unit["texts"], ["Apache text\n", "MIT text\n", "rand text\n"])
        self.assertEqual(unit["expression"], "MIT OR Apache-2.0")

    def test_a_crate_without_authors_is_credited_by_name(self):
        self.add_crate("defmt", "1.1.1")

        self.assertEqual(self.inventory()[1][0]["authors"], ["the defmt authors"])

    def test_a_clarified_expression_replaces_the_declared_one(self):
        self.add_crate("ring", "0.17.14", "Apache-2.0 AND ISC")

        unit = self.inventory({"ring": "Apache-2.0 AND ISC AND MIT"})[1][0]

        self.assertEqual(unit["expression"], "Apache-2.0 AND ISC AND MIT")

    def test_a_crate_with_no_expression_is_refused(self):
        self.add_crate("odd", "1.0.0", None)

        with self.assertRaises(source_inventory.InventoryError):
            self.inventory()

    def test_a_license_file_or_archive_below_the_root_must_be_described(self):
        self.add_crate("ring", "0.17.14", files={"third_party/fiat/LICENSE": "fiat\n"})
        self.add_crate("gettext-sys", "0.26.0", files={"gettext-0.26.tar.xz": "archive\n"})

        with self.assertRaises(source_inventory.InventoryError) as raised:
            self.inventory()

        self.assertIn("vendor/gettext-sys-0.26.0/gettext-0.26.tar.xz", str(raised.exception))
        self.assertIn("vendor/ring-0.17.14/third_party/fiat/LICENSE", str(raised.exception))

    def test_described_code_becomes_a_unit_and_the_crates_own_files_are_claimed(self):
        self.add_crate(
            "ring",
            "0.17.14",
            files={"third_party/fiat/LICENSE": "Copyright 2015 the fiat-crypto authors\n", "tests/data.gz": "x\n"},
        )
        self.source["crates"].append(
            {
                "crate": "ring",
                "version": "0.17.14",
                "own": ["tests/*.gz"],
                "paragraphs": [
                    {
                        "files": ["third_party/fiat/*"],
                        "license": "MIT OR Apache-2.0 OR BSD-1-Clause",
                        "texts": ["third_party/fiat/LICENSE"],
                    }
                ],
            }
        )

        nested = self.inventory()[2]

        self.assertEqual(
            nested,
            [
                {
                    "files": ["vendor/ring-0.17.14/third_party/fiat/*"],
                    "expression": "MIT OR Apache-2.0 OR BSD-1-Clause",
                    "texts": ["Copyright 2015 the fiat-crypto authors\n"],
                    "copyright": [],
                }
            ],
        )

    def test_a_text_can_come_from_inside_an_archive_or_be_written_out(self):
        directory = self.add_crate("gettext-sys", "0.26.0")
        member = self.dir / "COPYING"
        member.write_text("GNU GENERAL PUBLIC LICENSE\n", encoding="utf-8")
        with tarfile.open(directory / "gettext-0.26.tar.xz", "w:xz") as tar:
            tar.add(member, arcname="gettext-0.26/COPYING")
        self.source["crates"].append(
            {
                "crate": "gettext-sys",
                "version": "0.26.0",
                "paragraphs": [
                    {
                        "files": ["gettext-0.26.tar.xz"],
                        "license": "GPL-3.0-or-later AND public-domain",
                        "copyright": ["Free Software Foundation, Inc."],
                        "texts": ["gettext-0.26.tar.xz!/gettext-0.26/COPYING"],
                        "text": ["The author disclaims copyright to this source code."],
                    }
                ],
            }
        )

        unit = self.inventory()[2][0]

        self.assertEqual(unit["texts"], ["GNU GENERAL PUBLIC LICENSE\n", "The author disclaims copyright to this source code."])

    def test_a_license_file_inside_a_described_archive_must_be_read(self):
        directory = self.add_crate("gettext-sys", "0.26.0")
        for name in ("COPYING", "LICENSE"):
            (self.dir / name).write_text(f"{name} text\n", encoding="utf-8")
        with tarfile.open(directory / "gettext-0.26.tar.xz", "w:xz") as tar:
            tar.add(self.dir / "COPYING", arcname="gettext-0.26/COPYING")
            tar.add(self.dir / "LICENSE", arcname="gettext-0.26/tree-sitter/LICENSE")
        self.source["crates"].append(
            {
                "crate": "gettext-sys",
                "version": "0.26.0",
                "paragraphs": [
                    {
                        "files": ["gettext-0.26.tar.xz"],
                        "license": "GPL-3.0-or-later",
                        "copyright": ["Free Software Foundation, Inc."],
                        "texts": ["gettext-0.26.tar.xz!/gettext-0.26/COPYING:1-1"],
                    }
                ],
            }
        )

        with self.assertRaises(source_inventory.InventoryError) as raised:
            self.inventory()

        self.assertIn("gettext-0.26.tar.xz!/gettext-0.26/tree-sitter/LICENSE", str(raised.exception))
        self.assertNotIn("gettext-0.26/COPYING,", str(raised.exception))

    def test_an_excerpt_drops_the_comment_markers(self):
        self.add_crate("mongodb", "3.9.1", "Apache-2.0", files={"src/checked.rs": "// Original license:\n// Copyright (c) 2017 zeta12ti\n//\n/* Permission is granted. */\nuse std;\n"})
        self.source["crates"].append(
            {"crate": "mongodb", "version": "3.9.1", "paragraphs": [{"files": ["src/checked.rs"], "license": "MIT", "texts": ["src/checked.rs:2-4"]}]}
        )

        self.assertEqual(self.inventory()[2][0]["texts"], ["Copyright (c) 2017 zeta12ti\n\nPermission is granted.\n"])

    def test_a_described_pattern_that_matches_nothing_is_refused(self):
        self.add_crate("ring", "0.17.14")
        self.source["crates"].append({"crate": "ring", "version": "0.17.14", "own": ["tests/*.gz"]})

        with self.assertRaises(source_inventory.InventoryError):
            self.inventory()

    def test_an_entry_for_a_version_the_lock_lacks_is_refused(self):
        self.add_crate("ring", "0.17.15")
        self.source["crates"].append({"crate": "ring", "version": "0.17.14", "own": []})

        with self.assertRaises(source_inventory.InventoryError) as raised:
            self.inventory()

        self.assertIn("0.17.15", str(raised.exception))

    def test_a_bundled_archive_is_one_unit_under_every_component_it_holds(self):
        directory = self.add_crate("libduckdb-sys", "1.20000.1")
        (self.dir / "duckdb.cpp").write_text("int main() {}\n", encoding="utf-8")
        with tarfile.open(directory / "duckdb.tar.gz", "w:gz") as tar:
            tar.add(self.dir / "duckdb.cpp", arcname="duckdb/src/duckdb.cpp")
        bundle = self.dir / "bundled" / "libduckdb-sys"
        bundle.mkdir()
        (bundle / "duckdb.txt").write_text("Copyright 2018 DuckDB\n", encoding="utf-8")
        (bundle / "re2.txt").write_text("BSD text\n", encoding="utf-8")
        (bundle / "manifest.json").write_text(
            json.dumps(
                {
                    "crate": "libduckdb-sys",
                    "version": "1.20000.1",
                    "files": "duckdb.tar.gz",
                    "components": [
                        {"name": "DuckDB", "file": "duckdb.txt", "license": "MIT", "provides": "duckdb", "version": "2.0.0"},
                        {"name": "RE2", "file": "re2.txt", "license": "BSD-3-Clause", "copyright": ["2009 The RE2 Authors"]},
                        {"name": "AWS-LC copy with no text of its own", "provides": "aws-lc"},
                    ],
                }
            ),
            encoding="utf-8",
        )

        nested = self.inventory()[2]

        self.assertEqual(
            nested,
            [
                {
                    "files": ["vendor/libduckdb-sys-1.20000.1/duckdb.tar.gz"],
                    "expression": "(MIT) AND (BSD-3-Clause)",
                    "texts": ["Copyright 2018 DuckDB\n", "BSD text\n"],
                    "copyright": ["2009 The RE2 Authors"],
                }
            ],
        )
        rendered = license_metadata.render_copyright([], [], nested, "AGPL\n", "AGPL-3.0-or-later", self.dir)
        archive = rendered.split("Files: vendor/libduckdb-sys-1.20000.1/duckdb.tar.gz\n", 1)[1]
        self.assertTrue(archive.startswith("Copyright: 2009 The RE2 Authors\n 2018 DuckDB\nLicense: BSD-3-Clause and MIT\n"))

    def test_a_dist_file_entry_must_match_a_file(self):
        (self.dir / "root" / "core" / "fixtures").mkdir(parents=True)
        (self.dir / "root" / "core" / "fixtures" / "chinook.sqlite").write_text("db\n", encoding="utf-8")
        (self.dir / "root" / "core" / "fixtures" / "LICENSE").write_text("Copyright 2008 Luis Rocha\n", encoding="utf-8")
        self.source["files"].append(
            {"files": ["core/fixtures/*"], "license": "MIT", "texts": ["core/fixtures/LICENSE"], "copyright": []}
        )

        dist = self.inventory()[0]

        self.assertEqual(dist[0]["texts"], ["Copyright 2008 Luis Rocha\n"])
        self.source["files"].append({"files": ["core/missing/*"], "license": "MIT", "copyright": ["x"]})
        with self.assertRaises(source_inventory.InventoryError):
            self.inventory()


class LockTests(unittest.TestCase):
    def test_only_packages_with_a_source_are_vendored(self):
        lock = (
            'version = 4\n\n[[package]]\nname = "a"\nversion = "1.0.0"\nsource = "registry+x"\n\n'
            '[[package]]\nname = "tablepro"\nversion = "0.1.0"\ndependencies = [\n "a",\n]\n\n'
            '[[package]]\nname = "b"\nversion = "2.0.0"\nsource = "git+https://example.com/b#abc"\n'
        )

        self.assertEqual(source_inventory.lock_packages(lock), [("a", "1.0.0"), ("b", "2.0.0")])


if __name__ == "__main__":
    unittest.main()
