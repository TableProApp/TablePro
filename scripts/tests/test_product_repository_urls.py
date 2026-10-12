from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PRODUCT_URL = "https://github.com/cozyGarage/BookiE"


class ProductRepositoryUrlTests(unittest.TestCase):
    def test_linux_product_metadata_and_rc_verification_use_the_product_repository(self):
        paths = {
            "scripts/build-arch-rc.sh": f'remote="${{TABLEPRO_RC_REMOTE:-{PRODUCT_URL}.git}}"',
            "apps/linux/packaging/arch/PKGBUILD": f'url="{PRODUCT_URL}"',
            "apps/linux/flatpak/com.tablepro.linux.metainfo.xml": f"<url type=\"homepage\">{PRODUCT_URL}</url>",
            "apps/linux/app/src/ui/app/status_pages.rs": f'.website("{PRODUCT_URL}")',
            "scripts/update-translations.py": f'--msgid-bugs-address={PRODUCT_URL}/issues',
            "apps/linux/po/tablepro.pot": f"Report-Msgid-Bugs-To: {PRODUCT_URL}/issues",
        }
        for relative_path, expected in paths.items():
            with self.subTest(path=relative_path):
                contents = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn(expected, contents)
                self.assertNotIn("https://github.com/cozyGarage/TablePro", contents)

    def test_about_dialog_links_bookie_contributors_to_the_product_repository(self):
        contents = (ROOT / "apps/linux/app/src/ui/app/status_pages.rs").read_text(encoding="utf-8")
        self.assertIn(f"BookiE contributors {PRODUCT_URL}", contents)


if __name__ == "__main__":
    unittest.main()
