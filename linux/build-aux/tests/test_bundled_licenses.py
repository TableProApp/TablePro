import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packaging"))

import bundled_licenses  # noqa: E402
import license_metadata  # noqa: E402

CRATE_MIT = "Copyright 2021 The Crate Authors\n\nPermission is hereby granted, free of charge.\n"
RE2 = "Copyright (c) 2009 The RE2 Authors. All rights reserved.\n\nRedistribution and use in source and binary forms.\n"
SKA = "Copyright Malte Skarupke 2016.\nDistributed under the Boost Software License, Version 1.0.\n"

NOTICE = """# Third-party licenses

## License texts

### MIT License

Used by:

- engine-sys 1.2.3

~~~~text
Copyright 2021 The Crate Authors
~~~~
"""


def third_party(version="1.2.3"):
    return {
        "licenses": [
            {
                "id": "MIT",
                "name": "MIT License",
                "text": CRATE_MIT,
                "used_by": [{"crate": {"name": "engine-sys", "version": version}}],
            }
        ],
        "crates": [{"name": "engine-sys", "version": version, "license": "MIT"}],
    }


def bundles(version="1.2.3"):
    component = {"license_name": "BSD 3-Clause \"New\" or \"Revised\" License", "text": RE2}
    return [
        {
            "crate": "engine-sys",
            "version": version,
            "source": "https://example.com/engine/tree/abc",
            "components": [
                {**component, "name": "RE2", "path": "third_party/re2/LICENSE", "id": "BSD-3-Clause", "license": "BSD-3-Clause"},
                {
                    "name": "ska_sort",
                    "path": "third_party/ska_sort/LICENSE",
                    "id": "BSL-1.0",
                    "license": "BSL-1.0 AND MIT",
                    "license_name": "Boost Software License 1.0",
                    "text": SKA,
                },
            ],
        }
    ]


class MergeJsonTest(unittest.TestCase):
    def test_bundled_code_is_listed_under_its_crate(self):
        data = bundled_licenses.merge_json(third_party(), bundles())

        added = [record for record in data["licenses"] if "component" in record]
        self.assertEqual([record["component"] for record in added], ["RE2", "ska_sort"])
        self.assertEqual(added[0]["text"], RE2)
        self.assertEqual(added[0]["used_by"], [{"crate": {"name": "engine-sys", "version": "1.2.3"}}])
        self.assertEqual(data["crates"][0]["license"], "BSD-3-Clause AND BSL-1.0 AND MIT")

    def test_a_second_run_writes_the_same_file(self):
        once = bundled_licenses.merge_json(third_party(), bundles())
        twice = bundled_licenses.merge_json(json.loads(json.dumps(once)), bundles())

        self.assertEqual(bundled_licenses.render_json(twice), bundled_licenses.render_json(once))

    def test_another_crate_version_needs_its_own_texts(self):
        with self.assertRaisesRegex(bundled_licenses.BundledError, "is for 1.2.3, but 2.0.0 is linked"):
            bundled_licenses.merge_json(third_party("2.0.0"), bundles())

    def test_a_crate_no_longer_linked_is_named(self):
        data = third_party()
        data["crates"] = []

        with self.assertRaisesRegex(bundled_licenses.BundledError, "engine-sys is no longer linked"):
            bundled_licenses.merge_json(data, bundles())

    def test_the_copyright_file_names_every_bundled_holder(self):
        data = bundled_licenses.merge_json(third_party(), bundles())

        copyright = license_metadata.render_copyright(data["licenses"], data["crates"], "AGPL text\n", "AGPL-3.0-or-later")

        self.assertIn("2009 The RE2 Authors. All rights reserved.", copyright)
        self.assertIn("Malte Skarupke 2016.", copyright)
        self.assertIn("License: BSD-3-Clause and BSL-1.0 and MIT", copyright)


class RenderJsonTest(unittest.TestCase):
    def test_the_layout_is_the_templates(self):
        template = Path(__file__).resolve().parent.parent.parent / "data" / "licenses" / "third-party.json"
        text = template.read_text(encoding="utf-8")

        self.assertEqual(bundled_licenses.render_json(json.loads(text)), text)


class MergeNoticeTest(unittest.TestCase):
    def test_the_section_follows_the_crate_licenses_and_is_replaced_on_a_second_run(self):
        once = bundled_licenses.merge_notice(NOTICE, bundles())
        twice = bundled_licenses.merge_notice(once, bundles())

        self.assertEqual(once, twice)
        self.assertTrue(once.startswith(NOTICE.rstrip("\n") + "\n\n## Code compiled into crates\n"))
        self.assertIn("### RE2: BSD 3-Clause", once)
        self.assertIn("from `third_party/re2/LICENSE` in https://example.com/engine/tree/abc.", once)
        self.assertIn("~~~~text\n" + RE2.rstrip("\n") + "\n~~~~", once)


class MainTest(unittest.TestCase):
    def test_writes_both_files_from_a_bundle_folder(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "bundled" / "engine-sys"
            folder.mkdir(parents=True)
            (folder / "re2.txt").write_text(RE2, encoding="utf-8")
            component = bundles()[0]["components"][0]
            manifest = {
                "crate": "engine-sys",
                "version": "1.2.3",
                "source": "https://example.com/engine/tree/abc",
                "components": [{key: value for key, value in component.items() if key != "text"} | {"file": "re2.txt"}],
            }
            (folder / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            licenses = root / "third-party.json"
            licenses.write_text(json.dumps(third_party()), encoding="utf-8")
            notice = root / "NOTICE.md"
            notice.write_text(NOTICE, encoding="utf-8")

            status = bundled_licenses.main(
                ["--bundled", str(root / "bundled"), "--licenses", str(licenses), "--notice", str(notice)]
            )

            self.assertEqual(status, 0)
            written = json.loads(licenses.read_text(encoding="utf-8"))
            self.assertEqual(written["crates"][0]["license"], "BSD-3-Clause AND MIT")
            self.assertIn("### RE2: BSD 3-Clause", notice.read_text(encoding="utf-8"))

    def test_a_stale_bundle_fails_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "bundled" / "engine-sys"
            folder.mkdir(parents=True)
            (folder / "manifest.json").write_text(
                json.dumps({"crate": "engine-sys", "version": "0.9.0", "source": "x", "components": []}),
                encoding="utf-8",
            )
            licenses = root / "third-party.json"
            original = json.dumps(third_party())
            licenses.write_text(original, encoding="utf-8")
            notice = root / "NOTICE.md"
            notice.write_text(NOTICE, encoding="utf-8")

            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                status = bundled_licenses.main(
                    ["--bundled", str(root / "bundled"), "--licenses", str(licenses), "--notice", str(notice)]
                )

            self.assertEqual(status, 1)
            self.assertIn("is for 0.9.0, but 1.2.3 is linked", stderr.getvalue())
            self.assertEqual(licenses.read_text(encoding="utf-8"), original)


if __name__ == "__main__":
    unittest.main()
