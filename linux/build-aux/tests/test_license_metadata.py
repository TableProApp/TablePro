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

GPL2 = """
                    GNU GENERAL PUBLIC LICENSE
                       Version 2, June 1991

 Copyright (C) 1989, 1991 Free Software Foundation, Inc.,
 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

                    GNU GENERAL PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

                     END OF TERMS AND CONDITIONS

            How to Apply These Terms to Your New Programs

    51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

library.  If this is what you want to do, use the GNU Lesser General
Public License instead of this License.
"""

LGPL21 = """
                  GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999

                  GNU LESSER GENERAL PUBLIC LICENSE
   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
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


EXPAT_TERMS_TEXT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction.
"""


def crate_unit(name, version, expression, *texts, authors=None):
    return {
        "files": [f"vendor/{name}-{version}/*"],
        "expression": expression,
        "texts": list(texts),
        "authors": authors or [f"the {name} authors"],
    }


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
        self.assertEqual(self.dep5("LGPL-2.1-or-later OR GPL-2.0-only"), "GPL-2 or LGPL-2.1+")
        self.assertEqual(self.dep5("AGPL-3.0-or-later AND GFDL-1.2-or-later"), "AGPL-3+ and GFDL-1.2+")

    def test_an_exception_is_written_the_dep5_way(self):
        self.assertEqual(self.dep5("Apache-2.0 WITH LLVM-exception"), "Apache-2.0 with LLVM exception")

    def test_a_choice_that_dep5_cannot_group_is_refused(self):
        with self.assertRaises(license_metadata.MetadataError):
            self.dep5("MIT OR (ISC AND (Zlib OR Apache-2.0))")


class RenderCopyrightTests(unittest.TestCase):
    def setUp(self):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        self.texts = Path(workdir.name)
        (self.texts / "MIT.txt").write_text(EXPAT_TERMS_TEXT, encoding="utf-8")

    def render(self, crates=(), dist=(), nested=(), upstream="GNU AFFERO GENERAL PUBLIC LICENSE\n\nTerms.\n", metainfo="AGPL-3.0-or-later"):
        return license_metadata.render_copyright(list(dist), list(crates), list(nested), upstream, metainfo, self.texts)

    def test_header_comes_first_and_upstream_covers_every_file(self):
        rendered = self.render([crate_unit("a", "1.0.0", "MIT", MIT_ALICE)])
        header, upstream = paragraphs(rendered)[:2]

        self.assertEqual(header["Format"], [license_metadata.DEP5_FORMAT])
        self.assertEqual(upstream["Files"], ["*"])
        self.assertEqual(upstream["Copyright"], ["TablePro Authors"])
        self.assertEqual(
            upstream["License"],
            ["AGPL-3+", "GNU AFFERO GENERAL PUBLIC LICENSE", ".", "Terms."],
        )

    def test_the_metainfo_gets_its_own_license(self):
        rendered = self.render([crate_unit("a", "1.0.0", "MIT", MIT_ALICE)], metainfo="CC0-1.0")
        paragraph = files_paragraph(rendered, "metainfo")

        self.assertEqual(paragraph["Files"], ["linux/data/app.tablepro.TablePro.metainfo.xml.in.in"])
        self.assertEqual(paragraph["License"][0], "CC0-1.0")
        self.assertIn("/usr/share/common-licenses/CC0-1.0", "\n".join(paragraph["License"]))

    def test_a_metainfo_license_with_no_text_is_refused(self):
        with self.assertRaises(license_metadata.MetadataError):
            self.render([crate_unit("a", "1.0.0", "MIT", MIT_ALICE)], metainfo="FSFAP")

    def test_a_crate_names_every_license_it_offers_with_the_texts_it_ships(self):
        paragraph = files_paragraph(
            self.render([crate_unit("memchr", "2.7.0", "Unlicense OR MIT", EXPAT_ALICE, "This is free and unencumbered software.\n")]),
            "vendor/memchr-2.7.0/*",
        )

        self.assertEqual(paragraph["License"][0], "Expat or Unlicense")
        body = "\n".join(paragraph["License"])
        self.assertIn("Permission is hereby granted", body)
        self.assertIn("This is free and unencumbered software.", body)

    def test_an_mit_text_that_is_not_expat_keeps_the_name_mit(self):
        paragraph = files_paragraph(self.render([crate_unit("a", "1.0.0", "MIT", X11)]), "vendor/a-1.0.0/*")

        self.assertEqual(paragraph["License"][0], "MIT")

    def test_crates_with_one_text_and_different_expressions_get_their_own_paragraphs(self):
        rendered = self.render(
            [crate_unit("a", "1.0.0", "MIT", MIT_ALICE), crate_unit("b", "2.1.0", "MIT OR Apache-2.0", MIT_ALICE)]
        )

        self.assertEqual(files_paragraph(rendered, "vendor/a-1.0.0/*")["Files"], ["vendor/a-1.0.0/*"])
        self.assertEqual(files_paragraph(rendered, "vendor/b-2.1.0/*")["Files"], ["vendor/b-2.1.0/*"])

    def test_crates_sharing_texts_and_holders_share_a_paragraph(self):
        rendered = self.render(
            [crate_unit("b", "2.1.0", "MIT", MIT_ALICE), crate_unit("a", "1.0.0", "MIT", MIT_ALICE)]
        )

        self.assertEqual(files_paragraph(rendered, "vendor/a-1.0.0/*")["Files"], ["vendor/a-1.0.0/*", "vendor/b-2.1.0/*"])

    def test_crates_sharing_a_text_but_not_their_authors_keep_apart(self):
        rendered = self.render(
            [
                crate_unit("a", "1.0.0", "MIT", MIT_NO_NOTICE, authors=["Alice"]),
                crate_unit("b", "1.0.0", "MIT", MIT_NO_NOTICE, authors=["Bob"]),
            ]
        )

        self.assertEqual(files_paragraph(rendered, "vendor/a-1.0.0/*")["Copyright"], ["Alice"])
        self.assertEqual(files_paragraph(rendered, "vendor/b-1.0.0/*")["Copyright"], ["Bob"])

    def test_a_crate_under_two_licenses_lists_both_with_both_texts(self):
        paragraph = files_paragraph(
            self.render([crate_unit("unicode-ident", "1.0.24", "(MIT OR Apache-2.0) AND Unicode-3.0", MIT_ALICE, UNICODE)]),
            "vendor/unicode-ident-1.0.24/*",
        )

        self.assertEqual(paragraph["License"][0], "Apache-2.0 or MIT, and Unicode-3.0")
        body = "\n".join(paragraph["License"][1:])
        self.assertIn("Permission is hereby granted", body)
        self.assertIn("Copyright © 1991-2024 Unicode, Inc.", body)

    def test_one_text_shipped_twice_appears_once(self):
        paragraph = files_paragraph(
            self.render([crate_unit("aws-lc-sys", "0.45.0", "ISC AND MIT", MIT_ALICE, MIT_ALICE)]),
            "vendor/aws-lc-sys-0.45.0/*",
        )

        self.assertEqual("\n".join(paragraph["License"]).count("Permission is hereby granted"), 1)

    def test_copyright_takes_the_notices_without_their_prefix(self):
        paragraph = files_paragraph(
            self.render([crate_unit("a", "1.0.0", "MIT AND Unicode-3.0", MIT_ALICE, UNICODE)]), "vendor/a-1.0.0/*"
        )

        self.assertEqual(paragraph["Copyright"], ["2019 Alice", "1991-2024 Unicode, Inc."])

    def test_a_notice_written_as_a_field_loses_its_colon(self):
        text = "This product includes code from Apache Spark.\n\nCopyright: 2014 The Apache Software Foundation.\n"
        paragraph = files_paragraph(self.render([crate_unit("a", "1.0.0", "MIT", text)]), "vendor/a-1.0.0/*")

        self.assertEqual(paragraph["Copyright"], ["2014 The Apache Software Foundation."])

    def test_a_text_without_a_notice_credits_the_crates_authors(self):
        paragraph = files_paragraph(
            self.render([crate_unit("serde", "1.0.0", "MIT", MIT_NO_NOTICE, authors=["Erick Tryzelaar <erick.tryzelaar@gmail.com>", "David Tolnay <dtolnay@gmail.com>"])]),
            "vendor/serde-1.0.0/*",
        )

        self.assertEqual(paragraph["Copyright"], ["Erick Tryzelaar <erick.tryzelaar@gmail.com>", "David Tolnay <dtolnay@gmail.com>"])

    def test_a_crate_that_ships_no_license_file_points_at_stand_alone_paragraphs(self):
        rendered = self.render([crate_unit("windows-sys", "0.61.2", "MIT OR Apache-2.0", authors=["Microsoft"])])
        paragraph = files_paragraph(rendered, "vendor/windows-sys-0.61.2/*")

        self.assertEqual(paragraph["License"], ["Apache-2.0 or Expat"])
        self.assertEqual(paragraph["Copyright"], ["Microsoft"])
        standalone = {p["License"][0]: p["License"][1:] for p in paragraphs(rendered) if list(p) == ["License"]}
        self.assertEqual(sorted(standalone), ["Apache-2.0", "Expat"])
        self.assertIn('"/usr/share/common-licenses/Apache-2.0".', "\n".join(standalone["Apache-2.0"]))
        self.assertIn("Permission is hereby granted, free of charge, to any person obtaining a copy", standalone["Expat"])

    def test_a_stand_alone_license_with_no_text_is_refused(self):
        with self.assertRaises(license_metadata.MetadataError):
            self.render([crate_unit("adler", "1.0.0", "0BSD")])

    def test_code_a_crate_carries_comes_after_every_crate_paragraph(self):
        rendered = self.render(
            [crate_unit("a", "1.0.0", "MIT", MIT_ALICE), crate_unit("z", "1.0.0", "MIT", MIT_ALICE)],
            nested=[
                {
                    "files": ["vendor/a-1.0.0/third_party/fiat/*"],
                    "expression": "MIT OR Apache-2.0 OR BSD-1-Clause",
                    "texts": ["The fiat-crypto authors.\n"],
                    "copyright": ["2015-2020 the fiat-crypto authors"],
                }
            ],
        )
        files = [p["Files"] for p in paragraphs(rendered) if "Files" in p]

        self.assertEqual(files[-1], ["vendor/a-1.0.0/third_party/fiat/*"])
        self.assertEqual(files[-2], ["vendor/a-1.0.0/*", "vendor/z-1.0.0/*"])
        nested = files_paragraph(rendered, "third_party/fiat")
        self.assertEqual(nested["Copyright"], ["2015-2020 the fiat-crypto authors"])
        self.assertEqual(nested["License"][0], "Apache-2.0 or BSD-1-Clause or MIT")

    def test_the_dist_tarballs_exceptions_follow_the_upstream_paragraphs(self):
        rendered = self.render(
            [crate_unit("a", "1.0.0", "MIT", MIT_ALICE)],
            dist=[{"files": ["core/fixtures/chinook.db"], "expression": "MIT", "texts": [MIT_ALICE], "copyright": []}],
        )
        files = [p["Files"] for p in paragraphs(rendered) if "Files" in p]

        self.assertEqual(files[:2], [["*"], ["core/fixtures/chinook.db"]])

    def test_a_unit_with_no_holder_is_refused(self):
        with self.assertRaises(license_metadata.MetadataError):
            self.render(nested=[{"files": ["vendor/a-1.0.0/x/*"], "expression": "MIT", "texts": [MIT_NO_NOTICE], "copyright": []}])

    def test_the_apache_terms_point_at_common_licenses(self):
        rendered = self.render([crate_unit("ryu", "1.0.0", "Apache-2.0", APACHE + "\nCopyright 2011 Google Inc.\n")])
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
            self.render([crate_unit("ryu", "1.0.0", "Apache-2.0", broken)])

    def test_the_gpl2_terms_and_their_fsf_address_point_at_common_licenses(self):
        dual = "Copyright The Mbed TLS Contributors\n\nApache-2.0 OR GPL-2.0-or-later.\n" + APACHE + "\n=====\n" + GPL2
        rendered = self.render([crate_unit("mbedtls", "1.0.0", "Apache-2.0 OR GPL-2.0-or-later", dual)])
        paragraph = files_paragraph(rendered, "vendor/mbedtls-1.0.0/*")
        body = "\n".join(paragraph["License"][1:])

        self.assertEqual(paragraph["License"][0], "Apache-2.0 or GPL-2+")
        self.assertNotIn("TERMS AND CONDITIONS FOR COPYING", rendered)
        self.assertNotIn("02110-1301", rendered)
        self.assertIn("/usr/share/common-licenses/Apache-2.0", body)
        self.assertIn("/usr/share/common-licenses/GPL-2", body)
        self.assertTrue(body.rstrip().endswith('"/usr/share/common-licenses/GPL-2".'))
        self.assertEqual(paragraph["Copyright"], ["The Mbed TLS Contributors"])

    def test_the_gpl3_terms_point_at_common_licenses(self):
        gpl3 = (
            "                    GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007\n\n"
            " Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>\n\n"
            "                       TERMS AND CONDITIONS\n\n"
            "Public License instead of this License.  But first, please read\n"
            "<https://www.gnu.org/philosophy/why-not-lgpl.html>.\n"
        )
        unit = {"files": ["vendor/gettext-sys-0.26.0/gettext-0.26.tar.xz"], "expression": "GPL-3.0-or-later", "texts": [gpl3], "copyright": ["Free Software Foundation, Inc."]}
        paragraph = files_paragraph(self.render(nested=[unit]), "gettext-0.26.tar.xz")

        self.assertEqual(paragraph["License"][0], "GPL-3+")
        self.assertEqual(
            paragraph["License"][1:],
            [
                "On Debian systems, the complete text of the GNU General Public License",
                'version 3 can be found in "/usr/share/common-licenses/GPL-3".',
            ],
        )

    def test_the_lgpl_terms_and_their_fsf_address_point_at_common_licenses(self):
        lgpl = LGPL21 + "\n 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA\n\nThat's all there is to it!\n"
        rendered = self.render([crate_unit("a", "1.0.0", "LGPL-2.1-or-later", lgpl)])
        body = files_paragraph(rendered, "vendor/a-1.0.0/*")["License"][1:]

        self.assertNotIn("02110-1301", rendered)
        self.assertEqual(
            body,
            [
                "On Debian systems, the complete text of the GNU Lesser General Public License",
                'version 2.1 can be found in "/usr/share/common-licenses/LGPL-2.1".',
            ],
        )

    def test_a_gpl2_text_with_no_last_line_is_refused(self):
        broken = GPL2.replace("Public License instead of this License.", "")

        with self.assertRaises(license_metadata.MetadataError):
            self.render([crate_unit("a", "1.0.0", "GPL-2.0-or-later", broken)])

    def test_blank_lines_and_tabs_are_deb822_safe(self):
        rendered = self.render([crate_unit("a", "1.0.0", "MIT", "Copyright 2020 Bob\n\n\tIndented\fline\n\n")])
        lines = files_paragraph(rendered, "vendor/a-1.0.0/*")["License"]

        self.assertEqual(lines, ["MIT", "Copyright 2020 Bob", ".", "        Indentedline"])
        self.assertNotIn("\t", rendered)
        self.assertTrue(rendered.endswith("\n") and not rendered.endswith("\n\n"))


class CoverageTests(unittest.TestCase):
    LOCK = """version = 4

[[package]]
name = "cc"
version = "1.4.6"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "00"

[[package]]
name = "serde"
version = "1.0.228"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "00"

[[package]]
name = "tablepro"
version = "0.1.0"

[[package]]
name = "windows-sys"
version = "0.61.2"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "00"
"""

    def copyright(self, *patterns):
        files = "\n".join([f"Files: {patterns[0]}"] + [f" {pattern}" for pattern in patterns[1:]])
        return f"Format: x\n\nFiles: *\nCopyright: TablePro Authors\nLicense: AGPL-3+\n\n{files}\nCopyright: Alice\nLicense: Expat\n"

    def test_a_build_only_or_platform_only_crate_without_a_paragraph_fails(self):
        # cc builds DuckDB and windows-sys is for Windows only: neither is in
        # the binaries' inventory, and both are in the vendor tarball.
        problems = license_metadata.check_coverage(self.copyright("vendor/serde-1.0.228/*"), self.LOCK)

        self.assertEqual(len(problems), 1)
        self.assertIn("cc-1.4.6, windows-sys-0.61.2", problems[0])

    def test_every_crate_of_the_lock_with_a_paragraph_passes(self):
        copyright_text = self.copyright("vendor/cc-1.4.6/*", "vendor/serde-1.0.228/*", "vendor/windows-sys-0.61.2/*")

        self.assertEqual(license_metadata.check_coverage(copyright_text, self.LOCK), [])

    def test_a_paragraph_for_a_crate_the_lock_no_longer_has_fails(self):
        copyright_text = self.copyright(
            "vendor/cc-1.4.6/*", "vendor/serde-1.0.227/*", "vendor/serde-1.0.228/*", "vendor/windows-sys-0.61.2/*"
        )
        problems = license_metadata.check_coverage(copyright_text, self.LOCK)

        self.assertEqual(len(problems), 1)
        self.assertIn("serde-1.0.227", problems[0])

    def test_a_paragraph_for_code_inside_a_crate_does_not_count_as_the_crate(self):
        copyright_text = self.copyright("vendor/cc-1.4.6/third_party/*", "vendor/serde-1.0.228/*", "vendor/windows-sys-0.61.2/*")

        self.assertIn("cc-1.4.6", license_metadata.check_coverage(copyright_text, self.LOCK)[0])


class RpmProvidesTests(unittest.TestCase):
    BUNDLES = {
        ("engine-sys", "1.2.3"): {
            "crate": "engine-sys",
            "version": "1.2.3",
            "components": [
                {"name": "Engine", "provides": "engine", "version": "2.0.0"},
                {"name": "RE2", "provides": "re2"},
                {"name": "a snippet", "license": "MIT"},
            ],
        }
    }

    def test_each_library_is_provided_with_its_version_when_it_has_one(self):
        crates = [{"name": "engine-sys", "version": "1.2.3", "license": "MIT"}]

        self.assertEqual(
            license_metadata.rpm_provides(crates, self.BUNDLES), ["bundled(engine) = 2.0.0", "bundled(re2)"]
        )

    def test_a_bundle_for_a_crate_the_binaries_do_not_link_is_refused(self):
        with self.assertRaises(license_metadata.MetadataError):
            license_metadata.rpm_provides([{"name": "engine-sys", "version": "1.2.4", "license": "MIT"}], self.BUNDLES)

    def test_the_block_after_its_comment_is_replaced_in_place(self):
        comment = license_metadata.PROVIDES_COMMENT
        spec = f"License: MIT\n{comment}\nProvides:       bundled(old) = 1\nProvides:       bundled(gone)\nURL: x\n"

        self.assertEqual(
            license_metadata.apply_spec_provides(spec, ["bundled(engine) = 2.0.0"]),
            f"License: MIT\n{comment}\nProvides:       bundled(engine) = 2.0.0\nURL: x\n",
        )
        self.assertEqual(license_metadata.apply_spec_provides(f"{comment}\nURL: x\n", []), f"{comment}\nURL: x\n")

    def test_a_spec_without_exactly_one_block_is_refused(self):
        comment = license_metadata.PROVIDES_COMMENT
        for spec in ("License: MIT\nProvides: bundled(a)\n", f"{comment}\nURL: x\n{comment}\n"):
            with self.subTest(spec=spec), self.assertRaises(license_metadata.MetadataError):
                license_metadata.apply_spec_provides(spec, ["bundled(a)"])


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
    LOCK = """version = 4

[[package]]
name = "a"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "cc"
version = "1.4.6"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "tablepro"
version = "0.1.0"
"""

    def setUp(self):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        self.dir = Path(workdir.name)
        self.linux = self.dir / "linux"
        self.linux.mkdir()
        (self.linux / "third-party.json").write_text(
            json.dumps(
                {
                    "licenses": [{"id": "MIT", "name": "MIT", "text": MIT_ALICE, "used_by": [{"crate": {"name": "a", "version": "1.0.0"}}]}],
                    "crates": [{"name": "a", "version": "1.0.0", "license": "MIT"}],
                }
            ),
            encoding="utf-8",
        )
        (self.linux / "LICENSE").write_text("AGPL text\n", encoding="utf-8")
        metainfo = self.linux / license_metadata.METAINFO
        metainfo.parent.mkdir(parents=True)
        metainfo.write_text("<component><metadata_license>CC0-1.0</metadata_license></component>\n", encoding="utf-8")
        (self.linux / "tablepro.spec").write_text(
            f"License: AGPL-3.0-or-later\n{license_metadata.PROVIDES_COMMENT}\nProvides:       bundled(old)\n",
            encoding="utf-8",
        )
        (self.linux / "copyright").write_text("stale\n", encoding="utf-8")
        (self.dir / "Cargo.lock").write_text(self.LOCK, encoding="utf-8")
        for name in ("a-1.0.0", "cc-1.4.6", "tablepro"):
            (self.dir / "registry" / name).mkdir(parents=True)
            (self.dir / "registry" / name / "Cargo.toml").write_text("[package]\n", encoding="utf-8")
        (self.dir / "registry" / "a-1.0.0" / "LICENSE-MIT").write_text(MIT_ALICE, encoding="utf-8")
        registry = "registry+https://github.com/rust-lang/crates.io-index"
        packages = [
            {"name": "a", "version": "1.0.0", "source": registry, "license": "MIT", "authors": [], "dir": "a-1.0.0"},
            {"name": "cc", "version": "1.4.6", "source": registry, "license": "MIT OR Apache-2.0", "authors": ["Alex Crichton"], "dir": "cc-1.4.6"},
            {"name": "tablepro", "version": "0.1.0", "source": None, "license": "AGPL-3.0-or-later", "authors": [], "dir": "tablepro"},
        ]
        for package in packages:
            package["manifest_path"] = str(self.dir / "registry" / package.pop("dir") / "Cargo.toml")
        (self.dir / "metadata.json").write_text(json.dumps({"packages": packages}), encoding="utf-8")
        (self.dir / "about.toml").write_text("accepted = []\n", encoding="utf-8")
        (self.dir / "source.json").write_text('{"crates": [], "files": []}\n', encoding="utf-8")
        (self.dir / "bundled").mkdir()
        (self.dir / "texts").mkdir()
        (self.dir / "texts" / "MIT.txt").write_text(EXPAT_TERMS_TEXT, encoding="utf-8")

    def run_command(self, command):
        self.stderr = io.StringIO()
        arguments = [
            command,
            "--licenses", str(self.linux / "third-party.json"),
            "--license-file", str(self.linux / "LICENSE"),
            "--copyright", str(self.linux / "copyright"),
            "--spec", str(self.linux / "tablepro.spec"),
            "--lock", str(self.dir / "Cargo.lock"),
            "--bundled", str(self.dir / "bundled"),
        ]
        if command == "write":
            arguments += [
                "--metadata", str(self.dir / "metadata.json"),
                "--about", str(self.dir / "about.toml"),
                "--source", str(self.dir / "source.json"),
                "--texts", str(self.dir / "texts"),
            ]
        with contextlib.redirect_stderr(self.stderr):
            return license_metadata.main(arguments)

    def test_check_fails_on_stale_files_and_passes_after_write(self):
        self.assertEqual(self.run_command("check"), 1)
        self.assertIn("update-third-party-licenses.sh", self.stderr.getvalue())
        self.assertEqual((self.linux / "copyright").read_text(encoding="utf-8"), "stale\n")

        self.assertEqual(self.run_command("write"), 0, self.stderr.getvalue())

        self.assertEqual(self.run_command("check"), 0, self.stderr.getvalue())
        self.assertEqual(
            (self.linux / "tablepro.spec").read_text(encoding="utf-8"),
            f"License: %{{shrink:\n    AGPL-3.0-or-later AND\n    CC0-1.0 AND\n    MIT\n}}\n{license_metadata.PROVIDES_COMMENT}\n",
        )
        copyright_text = (self.linux / "copyright").read_text(encoding="utf-8")
        self.assertIn("Files: vendor/a-1.0.0/*", copyright_text)
        self.assertIn("Files: vendor/cc-1.4.6/*\nCopyright: Alex Crichton\nLicense: Apache-2.0 or Expat\n", copyright_text)

    def test_check_fails_when_the_lock_gains_a_crate_the_copyright_file_lacks(self):
        self.assertEqual(self.run_command("write"), 0, self.stderr.getvalue())
        lock = self.LOCK + '\n[[package]]\nname = "windows-sys"\nversion = "0.61.2"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n'
        (self.dir / "Cargo.lock").write_text(lock, encoding="utf-8")

        self.assertEqual(self.run_command("check"), 1)
        self.assertIn("windows-sys-0.61.2", self.stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
