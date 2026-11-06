import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "packaging" / "build-flatpak.sh"

# flatpak-builder keeps the manifest it was given, and flatpak makes the bundle.
FLATPAK_BUILDER = """#!/bin/sh
for last; do :; done
cp "$last" "$MANIFEST_SEEN"
"""
FLATPAK = """#!/bin/sh
case "$1" in
--default-arch) echo x86_64 ;;
build-bundle) touch "$4" ;;
esac
"""


def config_opts(manifest):
    module = next(module for module in manifest["modules"] if module["name"] == "tablepro")
    return module["config-opts"]


class BuildFlatpakTest(unittest.TestCase):
    def build(self, key):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            tools = work / "bin"
            tools.mkdir()
            for name, script in {"flatpak-builder": FLATPAK_BUILDER, "flatpak": FLATPAK}.items():
                tool = tools / name
                tool.write_text(script)
                tool.chmod(0o755)
            dist = work / "tablepro-0.1.0.tar.xz"
            dist.touch()
            vendor = work / "tablepro-0.1.0-vendor.tar.xz"
            with tarfile.open(vendor, "w:xz") as archive:
                config = b"[source.crates-io]\n"
                entry = tarfile.TarInfo("vendor/cargo-config.toml")
                entry.size = len(config)
                archive.addfile(entry, io.BytesIO(config))
                if key is not None:
                    data = f"{key}\n".encode()
                    entry = tarfile.TarInfo("vendor/posthog-key")
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
            seen = work / "seen.json"
            environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", MANIFEST_SEEN=str(seen))
            result = subprocess.run(
                ["sh", str(SCRIPT), str(dist), str(vendor), str(work / "out")],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            manifest = json.loads(seen.read_text()) if seen.exists() else None
            return result, manifest

    def test_the_key_a_release_vendor_tarball_carries_goes_to_meson(self):
        result, manifest = self.build("phc_Abc123_x-Y")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            config_opts(manifest), ["-Dprofile=default", "-Dflatpak=true", "-Dposthog_key=phc_Abc123_x-Y"]
        )

    def test_a_vendor_tarball_without_a_key_builds_without_one(self):
        result, manifest = self.build(None)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config_opts(manifest), ["-Dprofile=default", "-Dflatpak=true"])

    def test_a_key_that_is_not_one_is_refused_before_anything_builds(self):
        for key in ["", "key", "phc_", "phc_abc def", "phc_abc$(id)", 'phc_abc"', "phc_a|b"]:
            with self.subTest(key=key):
                result, manifest = self.build(key)

                self.assertEqual(result.returncode, 2)
                self.assertIn("holds no PostHog project key", result.stderr)
                self.assertIsNone(manifest)


if __name__ == "__main__":
    unittest.main()
