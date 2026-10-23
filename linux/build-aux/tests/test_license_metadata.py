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

EXPAT_ALICE = """Copyright (c) 2019 Alice

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
"""

UNICODE = "COPYRIGHT AND PERMISSION NOTICE\n\nCopyright © 1991-2024 Unicode, Inc.\n"


X11 = EXPAT_ALICE + "Except as contained in this notice, the name of Alice shall not be used in advertising.\n"


def crate(name, version):
    return {"crate": {"name": name, "version": version}}


def entry(spdx_id, text, *crates):
    return {"id": spdx_id, "name": spdx_id, "text": text, "used_by": list(crates)}


def declared(licenses, **expressions):
    crates = []
    for license in licenses:
        for used_by in license["used_by"]:
            name, version = used_by["crate"]["name"], used_by["crate"]["version"]
            record = {"name": name, "version": version, "license": expressions.get(name, license["id"])}
            if record not in crates:
                crates.append(record)
    return crates


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


class ParseExpressionTests(unittest.TestCase):
    def test_commuted_choices_are_one_term(self):
        self.assertEqual(
            license_metadata.parse_expression("MIT OR Apache-2.0"),
            license_metadata.parse_expression("Apache-2.0 OR MIT"),
        )

    def test_and_binds_tighter_than_or(self):
        parsed = license_metadata.parse_expression("MIT OR Apache-2.0 AND ISC")

        self.assertEqual(license_metadata.spdx(parsed), "(Apache-2.0 AND ISC) OR MIT")

    def test_nested_operators_flatten(self):
        parsed = license_metadata.parse_expression("(MIT OR (Apache-2.0 OR MIT)) AND (Zlib AND ISC)")

        self.assertEqual(license_metadata.spdx(parsed), "(Apache-2.0 OR MIT) AND ISC AND Zlib")

    def test_an_exception_stays_with_its_license(self):
        parsed = license_metadata.parse_expression("Apache-2.0 WITH LLVM-exception OR MIT")

        self.assertEqual(parsed, ("or", (("with", "Apache-2.0", "LLVM-exception"), ("license", "MIT"))))

    def test_a_slash_is_read_as_or(self):
        self.assertEqual(
            license_metadata.parse_expression("MIT/Apache-2.0"),
            license_metadata.parse_expression("MIT OR Apache-2.0"),
        )

    def test_a_malformed_or_unread_expression_is_refused(self):
        malformed = ("", "MIT OR", "(MIT", "MIT)", "MIT Apache-2.0", "MIT WITH (", "(MIT OR ISC) WITH LLVM-exception", "Unknown")
        for text in malformed:
            with self.subTest(text=text), self.assertRaises(license_metadata.MetadataError):
                license_metadata.parse_expression(text)


class Dep5Tests(unittest.TestCase):
    def dep5(self, text, expat=True):
        return license_metadata.dep5(license_metadata.parse_expression(text), expat)

    def test_choices_are_written_with_or(self):
        self.assertEqual(self.dep5("Unlicense OR MIT"), "Expat or Unlicense")

    def test_mit_is_expat_only_when_the_text_is(self):
        self.assertEqual(self.dep5("MIT", expat=False), "MIT")
        self.assertTrue(license_metadata.is_expat(EXPAT_ALICE))
        self.assertFalse(license_metadata.is_expat(MIT_ALICE))
        self.assertFalse(license_metadata.is_expat(X11))

    def test_an_and_of_choices_takes_commas(self):
        self.assertEqual(
            self.dep5("(MIT OR Apache-2.0) AND Unicode-3.0"),
            "Apache-2.0 or Expat, and Unicode-3.0",
        )
        self.assertEqual(self.dep5("ISC AND Zlib"), "ISC and Zlib")

    def test_or_later_and_only_take_the_dep5_suffix(self):
        self.assertEqual(self.dep5("LGPL-2.1-or-later OR GPL-2.0-only"), "GPL-2.0 or LGPL-2.1+")

    def test_an_exception_is_written_the_dep5_way(self):
        self.assertEqual(self.dep5("Apache-2.0 WITH LLVM-exception"), "Apache-2.0 with LLVM exception")

    def test_a_choice_that_dep5_cannot_group_is_refused(self):
        with self.assertRaises(license_metadata.MetadataError):
            self.dep5("MIT OR (ISC AND (Zlib OR Apache-2.0))")


class RenderCopyrightTests(unittest.TestCase):
    def render(self, licenses, crates=None, upstream="GNU AFFERO GENERAL PUBLIC LICENSE\n\nTerms.\n", metainfo="AGPL-3.0-or-later"):
        if crates is None:
            crates = declared(licenses)
        return license_metadata.render_copyright(licenses, crates, upstream, metainfo)

    def test_header_comes_first_and_upstream_covers_every_file(self):
        rendered = self.render([entry("MIT", MIT_ALICE, crate("a", "1.0.0"))])
        header, upstream = paragraphs(rendered)[:2]

        self.assertEqual(header["Format"], [license_metadata.DEP5_FORMAT])
        self.assertEqual(upstream["Files"], ["*"])
        self.assertEqual(upstream["Copyright"], ["TablePro Authors"])
        self.assertEqual(
            upstream["License"],
            ["AGPL-3.0+", "GNU AFFERO GENERAL PUBLIC LICENSE", ".", "Terms."],
        )

    def test_the_metainfo_gets_its_own_license(self):
        rendered = self.render([entry("MIT", MIT_ALICE, crate("a", "1.0.0"))], metainfo="CC0-1.0")
        paragraph = files_paragraph(rendered, "metainfo")

        self.assertEqual(paragraph["Files"], [license_metadata.METAINFO.as_posix()])
        self.assertEqual(paragraph["License"][0], "CC0-1.0")
        self.assertIn("/usr/share/common-licenses/CC0-1.0", "\n".join(paragraph["License"]))

    def test_a_metainfo_license_with_no_text_is_refused(self):
        with self.assertRaises(license_metadata.MetadataError):
            self.render([entry("MIT", MIT_ALICE, crate("a", "1.0.0"))], metainfo="FSFAP")

    def test_a_crate_names_every_license_it_offers_with_the_text_it_is_used_under(self):
        licenses = [entry("MIT", EXPAT_ALICE, crate("memchr", "2.7.0"))]
        crates = declared(licenses, memchr="Unlicense OR MIT")
        paragraph = files_paragraph(self.render(licenses, crates), "vendor/memchr-2.7.0/*")

        self.assertEqual(paragraph["License"][0], "Expat or Unlicense")
        self.assertIn("Permission is hereby granted", "\n".join(paragraph["License"]))

    def test_an_mit_text_that_is_not_expat_keeps_the_name_mit(self):
        licenses = [entry("MIT", X11, crate("a", "1.0.0"))]
        paragraph = files_paragraph(self.render(licenses), "vendor/a-1.0.0/*")

        self.assertEqual(paragraph["License"][0], "MIT")

    def test_crates_with_one_text_and_different_expressions_get_their_own_paragraphs(self):
        licenses = [entry("MIT", MIT_ALICE, crate("a", "1.0.0"), crate("b", "2.1.0"))]
        rendered = self.render(licenses, declared(licenses, b="MIT OR Apache-2.0"))

        self.assertEqual(files_paragraph(rendered, "vendor/a-1.0.0/*")["Files"], ["vendor/a-1.0.0/*"])
        self.assertEqual(files_paragraph(rendered, "vendor/b-2.1.0/*")["Files"], ["vendor/b-2.1.0/*"])

    def test_a_crate_with_a_text_and_no_expression_or_the_reverse_is_refused(self):
        licenses = [entry("MIT", MIT_ALICE, crate("a", "1.0.0"))]
        extra = {"name": "b", "version": "1.0.0", "license": "MIT"}
        for crates in ([], declared(licenses) + [extra]):
            with self.subTest(crates=crates), self.assertRaises(license_metadata.MetadataError):
                self.render(licenses, crates)

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
        crates = declared(licenses, **{"unicode-ident": "(MIT OR Apache-2.0) AND Unicode-3.0"})
        paragraph = files_paragraph(self.render(licenses, crates), "vendor/unicode-ident-1.0.24/*")

        self.assertEqual(paragraph["License"][0], "Apache-2.0 or MIT, and Unicode-3.0")
        body = "\n".join(paragraph["License"][1:])
        self.assertIn("Permission is hereby granted", body)
        self.assertIn("Copyright © 1991-2024 Unicode, Inc.", body)

    def test_one_text_used_for_several_licenses_appears_once(self):
        licenses = [
            entry("ISC", MIT_ALICE, crate("aws-lc-sys", "0.45.0")),
            entry("MIT", MIT_ALICE, crate("aws-lc-sys", "0.45.0")),
        ]
        crates = declared(licenses, **{"aws-lc-sys": "ISC AND MIT"})
        paragraph = files_paragraph(self.render(licenses, crates), "vendor/aws-lc-sys-0.45.0/*")

        self.assertEqual(paragraph["License"][0], "ISC and MIT")
        self.assertEqual("\n".join(paragraph["License"]).count("Permission is hereby granted"), 1)

    def test_copyright_takes_the_notices_without_their_prefix(self):
        licenses = [
            entry("MIT", MIT_ALICE, crate("a", "1.0.0")),
            entry("Unicode-3.0", UNICODE, crate("a", "1.0.0")),
        ]
        paragraph = files_paragraph(self.render(licenses, declared(licenses, a="MIT AND Unicode-3.0")), "vendor/a-1.0.0/*")

        self.assertEqual(paragraph["Copyright"], ["2019 Alice", "1991-2024 Unicode, Inc."])

    def test_a_notice_written_as_a_field_loses_its_colon(self):
        text = "This product includes code from Apache Spark.\n\nCopyright: 2014 The Apache Software Foundation.\n"
        licenses = [entry("MIT", text, crate("a", "1.0.0"))]
        paragraph = files_paragraph(self.render(licenses), "vendor/a-1.0.0/*")

        self.assertEqual(paragraph["Copyright"], ["2014 The Apache Software Foundation."])

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

    def test_blank_lines_and_tabs_are_deb822_safe(self):
        licenses = [entry("MIT", "Copyright 2020 Bob\n\n\tIndented\fline\n\n", crate("a", "1.0.0"))]
        rendered = self.render(licenses)
        lines = files_paragraph(rendered, "vendor/a-1.0.0/*")["License"]

        self.assertEqual(lines, ["MIT", "Copyright 2020 Bob", ".", "        Indentedline"])
        self.assertNotIn("\t", rendered)
        self.assertTrue(rendered.endswith("\n") and not rendered.endswith("\n\n"))


class RpmLicenseTests(unittest.TestCase):
    def test_upstream_first_then_each_crate_expression_once_with_every_choice(self):
        crates = [
            {"name": "a", "version": "1.0.0", "license": "MIT OR Apache-2.0"},
            {"name": "b", "version": "1.0.0", "license": "Apache-2.0 OR MIT"},
            {"name": "c", "version": "1.0.0", "license": "Unlicense OR MIT"},
            {"name": "d", "version": "1.0.0", "license": "(MIT OR Apache-2.0) AND Unicode-3.0"},
            {"name": "e", "version": "1.0.0", "license": "MIT"},
            {"name": "f", "version": "1.0.0", "license": "AGPL-3.0-or-later"},
        ]

        self.assertEqual(
            license_metadata.rpm_license(crates, "CC0-1.0"),
            ["AGPL-3.0-or-later", "CC0-1.0", "(Apache-2.0 OR MIT)", "MIT", "(MIT OR Unlicense)", "Unicode-3.0"],
        )

    def test_the_metainfo_license_is_left_out_when_it_is_the_upstream_one(self):
        crates = [{"name": "a", "version": "1.0.0", "license": "MIT"}]

        self.assertEqual(license_metadata.rpm_license(crates, "AGPL-3.0-or-later"), ["AGPL-3.0-or-later", "MIT"])

    def test_a_one_line_license_tag_becomes_a_block_and_a_block_is_replaced(self):
        spec = "Name: tablepro\nLicense:        AGPL-3.0-or-later\nURL: x\n"
        block = "Name: tablepro\nLicense:        %{shrink:\n    AGPL-3.0-or-later AND\n    (Apache-2.0 OR MIT)\n}\nURL: x\n"

        self.assertEqual(
            license_metadata.apply_spec_license(spec, ["AGPL-3.0-or-later", "(Apache-2.0 OR MIT)"]),
            block,
        )
        self.assertEqual(
            license_metadata.apply_spec_license(block, ["AGPL-3.0-or-later", "MIT"]),
            "Name: tablepro\nLicense:        %{shrink:\n    AGPL-3.0-or-later AND\n    MIT\n}\nURL: x\n",
        )

    def test_a_spec_without_exactly_one_license_tag_is_refused(self):
        for spec in ("Name: tablepro\n", "License: A\nLicense: B\n"):
            with self.subTest(spec=spec), self.assertRaises(license_metadata.MetadataError):
                license_metadata.apply_spec_license(spec, ["MIT"])


class CommandTests(unittest.TestCase):
    def setUp(self):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        self.dir = Path(workdir.name)
        licenses = [entry("MIT", MIT_ALICE, crate("a", "1.0.0"))]
        (self.dir / "third-party.json").write_text(
            json.dumps({"licenses": licenses, "crates": declared(licenses)}),
            encoding="utf-8",
        )
        (self.dir / "LICENSE").write_text("AGPL text\n", encoding="utf-8")
        metainfo = self.dir / license_metadata.METAINFO
        metainfo.parent.mkdir(parents=True)
        metainfo.write_text(
            "<component><metadata_license>CC0-1.0</metadata_license></component>\n", encoding="utf-8"
        )
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
            "License: %{shrink:\n    AGPL-3.0-or-later AND\n    CC0-1.0 AND\n    MIT\n}\n",
        )
        self.assertIn("Files: vendor/a-1.0.0/*", (self.dir / "copyright").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
