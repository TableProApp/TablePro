import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packaging"))

import license_metadata  # noqa: E402

APACHE = """
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      Copyright [yyyy] [name of copyright owner]
"""

MIT_ALICE = """Copyright (c) 2019 Alice

Permission is hereby granted, free of charge, to any person obtaining a copy.
The above copyright notice and this permission notice shall be included.
"""

MIT_NO_NOTICE = "Permission is hereby granted, free of charge.\n"

UNICODE = "COPYRIGHT AND PERMISSION NOTICE\n\nCopyright © 1991-2024 Unicode, Inc.\n"


def crate(name, version):
    return {"crate": {"name": name, "version": version}}


def entry(spdx_id, text, *crates):
    return {"id": spdx_id, "name": spdx_id, "text": text, "used_by": list(crates)}


def paragraphs(copyright_text):
    parsed = []
    for block in copyright_text.strip("\n").split("\n\n"):
        fields = {}
        current = None
        for line in block.split("\n"):
            if line.startswith(" "):
                fields[current].append(line[1:])
            else:
                current, _, value = line.partition(": ")
                fields[current] = [value]
        parsed.append(fields)
    return parsed


def files_paragraph(rendered, pattern):
    matches = [p for p in paragraphs(rendered) if pattern in " ".join(p.get("Files", []))]
    if len(matches) != 1:
        raise AssertionError(f"{len(matches)} paragraphs name {pattern}")
    return matches[0]


class RenderCopyrightTests(unittest.TestCase):
    def render(self, licenses, upstream="GNU AFFERO GENERAL PUBLIC LICENSE\n\nTerms.\n"):
        return license_metadata.render_copyright(licenses, upstream)

    def test_header_comes_first_and_upstream_covers_every_file(self):
        rendered = self.render([entry("MIT", MIT_ALICE, crate("a", "1.0.0"))])
        header, upstream = paragraphs(rendered)[:2]

        self.assertEqual(header["Format"], [license_metadata.DEP5_FORMAT])
        self.assertEqual(upstream["Files"], ["*"])
        self.assertEqual(upstream["Copyright"], ["TablePro Authors"])
        self.assertEqual(
            upstream["License"],
            ["AGPL-3.0-or-later", "GNU AFFERO GENERAL PUBLIC LICENSE", ".", "Terms."],
        )

    def test_every_crate_is_named_once_by_its_versioned_vendor_directory(self):
        licenses = [
            entry("MIT", MIT_ALICE, crate("a", "1.0.0"), crate("b", "2.1.0")),
            entry("MIT", MIT_NO_NOTICE, crate("c", "0.3.0"), crate("c", "0.4.1")),
        ]
        rendered = self.render(licenses)

        patterns = []
        for paragraph in paragraphs(rendered)[2:]:
            patterns.extend(" ".join(paragraph["Files"]).split())
        self.assertEqual(
            sorted(patterns),
            ["vendor/a-1.0.0/*", "vendor/b-2.1.0/*", "vendor/c-0.3.0/*", "vendor/c-0.4.1/*"],
        )

    def test_crates_sharing_a_text_share_a_paragraph(self):
        rendered = self.render([entry("MIT", MIT_ALICE, crate("a", "1.0.0"), crate("b", "2.1.0"))])

        paragraph = files_paragraph(rendered, "vendor/a-1.0.0/*")
        self.assertEqual(paragraph["Files"], ["vendor/a-1.0.0/*", "vendor/b-2.1.0/*"])

    def test_a_crate_under_two_licenses_lists_both_with_both_texts(self):
        licenses = [
            entry("MIT", MIT_ALICE, crate("unicode-ident", "1.0.24")),
            entry("Unicode-3.0", UNICODE, crate("unicode-ident", "1.0.24")),
        ]
        paragraph = files_paragraph(self.render(licenses), "vendor/unicode-ident-1.0.24/*")

        self.assertEqual(paragraph["License"][0], "MIT and Unicode-3.0")
        body = "\n".join(paragraph["License"][1:])
        self.assertIn("Permission is hereby granted", body)
        self.assertIn("Copyright © 1991-2024 Unicode, Inc.", body)

    def test_one_text_used_for_several_licenses_appears_once(self):
        licenses = [
            entry("ISC", MIT_ALICE, crate("aws-lc-sys", "0.45.0")),
            entry("MIT", MIT_ALICE, crate("aws-lc-sys", "0.45.0")),
        ]
        paragraph = files_paragraph(self.render(licenses), "vendor/aws-lc-sys-0.45.0/*")

        self.assertEqual(paragraph["License"][0], "ISC and MIT")
        self.assertEqual("\n".join(paragraph["License"]).count("Permission is hereby granted"), 1)

    def test_copyright_takes_the_notices_without_their_prefix(self):
        licenses = [
            entry("MIT", MIT_ALICE, crate("a", "1.0.0")),
            entry("Unicode-3.0", UNICODE, crate("a", "1.0.0")),
        ]
        paragraph = files_paragraph(self.render(licenses), "vendor/a-1.0.0/*")

        self.assertEqual(paragraph["Copyright"], ["2019 Alice", "1991-2024 Unicode, Inc."])

    def test_a_text_without_a_notice_credits_the_crates_authors(self):
        licenses = [entry("MIT", MIT_NO_NOTICE, crate("serde", "1.0.0"), crate("syn", "1.0.0"), crate("syn", "2.0.0"))]
        paragraph = files_paragraph(self.render(licenses), "vendor/serde-1.0.0/*")

        self.assertEqual(paragraph["Copyright"], ["the authors of serde, syn"])

    def test_the_apache_terms_point_at_common_licenses(self):
        licenses = [entry("Apache-2.0", APACHE + "\nCopyright 2011 Google Inc.\n", crate("ryu", "1.0.0"))]
        rendered = self.render(licenses)
        paragraph = files_paragraph(rendered, "vendor/ryu-1.0.0/*")

        self.assertNotIn(license_metadata.APACHE_TERMS, rendered)
        self.assertNotIn("1. Definitions.", rendered)
        body = "\n".join(paragraph["License"][1:])
        self.assertIn("/usr/share/common-licenses/Apache-2.0", body)
        self.assertIn("APPENDIX: How to apply the Apache License to your work.", body)
        self.assertEqual(paragraph["Copyright"], ["2011 Google Inc."])

    def test_an_apache_text_with_no_end_line_is_refused(self):
        broken = APACHE.replace("END OF TERMS AND CONDITIONS", "")

        with self.assertRaises(license_metadata.MetadataError):
            self.render([entry("Apache-2.0", broken, crate("ryu", "1.0.0"))])

    def test_an_exception_is_written_the_dep5_way(self):
        licenses = [entry("Apache-2.0 WITH LLVM-exception", MIT_ALICE, crate("a", "1.0.0"))]
        paragraph = files_paragraph(self.render(licenses), "vendor/a-1.0.0/*")

        self.assertEqual(paragraph["License"][0], "Apache-2.0 with LLVM exception")

    def test_blank_lines_and_tabs_are_deb822_safe(self):
        licenses = [entry("MIT", "Copyright 2020 Bob\n\n\tIndented\fline\n\n", crate("a", "1.0.0"))]
        rendered = self.render(licenses)
        lines = files_paragraph(rendered, "vendor/a-1.0.0/*")["License"]

        self.assertEqual(lines, ["MIT", "Copyright 2020 Bob", ".", "        Indentedline"])
        self.assertNotIn("\t", rendered)
        self.assertTrue(rendered.endswith("\n") and not rendered.endswith("\n\n"))


class RpmLicenseTests(unittest.TestCase):
    def test_upstream_first_then_each_third_party_license_once(self):
        licenses = [
            entry("MIT", MIT_ALICE, crate("a", "1.0.0")),
            entry("Apache-2.0", APACHE, crate("b", "1.0.0")),
            entry("MIT", MIT_NO_NOTICE, crate("c", "1.0.0")),
            entry("AGPL-3.0-or-later", "x", crate("d", "1.0.0")),
        ]

        self.assertEqual(
            license_metadata.rpm_license(licenses),
            "AGPL-3.0-or-later AND Apache-2.0 AND MIT",
        )

    def test_the_spec_license_line_is_replaced_in_place(self):
        spec = "Name: tablepro\nLicense:        AGPL-3.0-or-later\nURL: x\n"

        self.assertEqual(
            license_metadata.apply_spec_license(spec, "AGPL-3.0-or-later AND MIT"),
            "Name: tablepro\nLicense:        AGPL-3.0-or-later AND MIT\nURL: x\n",
        )

    def test_a_spec_without_exactly_one_license_line_is_refused(self):
        for spec in ("Name: tablepro\n", "License: A\nLicense: B\n"):
            with self.subTest(spec=spec), self.assertRaises(license_metadata.MetadataError):
                license_metadata.apply_spec_license(spec, "MIT")


class CommandTests(unittest.TestCase):
    def setUp(self):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        self.dir = Path(workdir.name)
        (self.dir / "third-party.json").write_text(
            json.dumps({"licenses": [entry("MIT", MIT_ALICE, crate("a", "1.0.0"))]}),
            encoding="utf-8",
        )
        (self.dir / "LICENSE").write_text("AGPL text\n", encoding="utf-8")
        (self.dir / "tablepro.spec").write_text("License: AGPL-3.0-or-later\n", encoding="utf-8")
        (self.dir / "copyright").write_text("stale\n", encoding="utf-8")

    def run_command(self, command):
        self.stderr = io.StringIO()
        with contextlib.redirect_stderr(self.stderr):
            return license_metadata.main(
                [
                    command,
                    "--licenses", str(self.dir / "third-party.json"),
                    "--license-file", str(self.dir / "LICENSE"),
                    "--copyright", str(self.dir / "copyright"),
                    "--spec", str(self.dir / "tablepro.spec"),
                ]
            )

    def test_check_fails_on_stale_files_and_passes_after_write(self):
        self.assertEqual(self.run_command("check"), 1)
        self.assertIn("update-third-party-licenses.sh", self.stderr.getvalue())
        self.assertEqual((self.dir / "copyright").read_text(encoding="utf-8"), "stale\n")

        self.assertEqual(self.run_command("write"), 0)

        self.assertEqual(self.run_command("check"), 0)
        self.assertEqual(
            (self.dir / "tablepro.spec").read_text(encoding="utf-8"),
            "License: AGPL-3.0-or-later AND MIT\n",
        )
        self.assertIn("Files: vendor/a-1.0.0/*", (self.dir / "copyright").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
