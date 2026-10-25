import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "apps/linux/flatpak/com.tablepro.linux.json"
HELPER = ROOT / "scripts/build-flatpak.sh"


class FlatpakSetupTests(unittest.TestCase):
    def test_setup_runtime_refs_match_manifest(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        helper = HELPER.read_text(encoding="utf-8")
        marker = "flatpak install -y flathub "

        if marker not in helper:
            self.fail("the helper no longer documents Flatpak runtime installation")
        install_block = helper.split(marker, 1)[1].split("\n\nArch:", 1)[0]
        install_tokens = install_block.replace("\\\n", " ").split()
        runtime_version = manifest["runtime-version"]
        expected_refs = [
            f"{manifest['sdk']}//{runtime_version}",
            f"{manifest['runtime']}//{runtime_version}",
        ]
        actual_refs = [
            token for token in install_tokens
            if token.startswith((f"{manifest['sdk']}//", f"{manifest['runtime']}//"))
        ]

        self.assertCountEqual(actual_refs, expected_refs)


if __name__ == "__main__":
    unittest.main()
