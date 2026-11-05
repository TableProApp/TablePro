import contextlib
import hashlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "packaging"))

import release_assets  # noqa: E402

BETA = "0.1.0-beta.1"


def built_files(version, series=("26.04", "26.10")):
    packaged = version.replace("-", "~", 1)
    files = {
        "linux-sources": [f"tablepro-{version}.tar.xz", f"tablepro-{version}-vendor.tar.xz"],
        "linux-pot": ["tablepro.pot"],
        "linux-flatpak-x86_64": ["tablepro-x86_64.flatpak"],
        "linux-flatpak-aarch64": ["tablepro-aarch64.flatpak"],
    }
    for name in series:
        for arch, runner in (("amd64", "X64"), ("arm64", "ARM64")):
            files[f"linux-deb-{name}-{runner}"] = [
                f"tablepro_{packaged}-0ppa1~{name}_{arch}.deb",
                f"tablepro-dbgsym_{packaged}-0ppa1~{name}_{arch}.ddeb",
                f"tablepro_{packaged}-0ppa1~{name}_{arch}.buildinfo",
                f"tablepro_{packaged}-0ppa1~{name}_{arch}.changes",
            ]
    for arch, runner in (("x86_64", "X64"), ("aarch64", "ARM64")):
        files[f"linux-rpm-{runner}"] = [
            f"tablepro-{packaged}-1.fc44.{arch}.rpm",
            f"tablepro-debuginfo-{packaged}-1.fc44.{arch}.rpm",
            f"tablepro-debugsource-{packaged}-1.fc44.{arch}.rpm",
            f"tablepro-{packaged}-1.fc44.src.rpm",
        ]
    return files


class GatherTests(unittest.TestCase):
    def artifacts(self, files):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        root = Path(workdir.name)
        for directory, names in files.items():
            (root / "artifacts" / directory).mkdir(parents=True)
            for name in names:
                (root / "artifacts" / directory / name).write_text(f"{directory}/{name}", encoding="utf-8")
        return root / "artifacts", root / "release"

    def test_a_beta_publishes_every_package_without_a_tilde(self):
        artifacts, out = self.artifacts(built_files(BETA))

        names = release_assets.gather(artifacts, out, BETA)

        self.assertEqual(
            names,
            [
                "tablepro-0.1.0-beta.1-aarch64.flatpak",
                "tablepro-0.1.0-beta.1-fedora-44-aarch64.rpm",
                "tablepro-0.1.0-beta.1-fedora-44-x86_64.rpm",
                "tablepro-0.1.0-beta.1-ubuntu-26.04-amd64.deb",
                "tablepro-0.1.0-beta.1-ubuntu-26.04-arm64.deb",
                "tablepro-0.1.0-beta.1-ubuntu-26.10-amd64.deb",
                "tablepro-0.1.0-beta.1-ubuntu-26.10-arm64.deb",
                "tablepro-0.1.0-beta.1-vendor.tar.xz",
                "tablepro-0.1.0-beta.1-x86_64.flatpak",
                "tablepro-0.1.0-beta.1.tar.xz",
                "tablepro.pot",
            ],
        )
        self.assertEqual(sorted(path.name for path in out.iterdir()), sorted([*names, "SHA256SUMS"]))
        self.assertFalse(any("~" in name for name in names))

    def test_sha256sums_lists_each_asset_as_sha256sum_does(self):
        artifacts, out = self.artifacts(built_files("0.1.0"))

        names = release_assets.gather(artifacts, out, "0.1.0")

        lines = (out / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        self.assertEqual([line.split("  ", 1)[1] for line in lines], names)
        for line in lines:
            digest, name = line.split("  ", 1)
            self.assertEqual(digest, hashlib.sha256((out / name).read_bytes()).hexdigest())

    def test_the_debs_keep_their_builds_apart(self):
        artifacts, out = self.artifacts(built_files("0.1.0"))

        release_assets.gather(artifacts, out, "0.1.0")

        self.assertEqual(
            (out / "tablepro-0.1.0-ubuntu-26.10-arm64.deb").read_text(encoding="utf-8"),
            "linux-deb-26.10-ARM64/tablepro_0.1.0-0ppa1~26.10_arm64.deb",
        )

    def test_a_missing_architecture_fails(self):
        for directory in ("linux-deb-26.10-ARM64", "linux-rpm-X64", "linux-flatpak-aarch64", "linux-pot"):
            with self.subTest(directory=directory):
                files = built_files(BETA)
                del files[directory]
                artifacts, out = self.artifacts(files)

                with self.assertRaises(release_assets.AssetError):
                    release_assets.gather(artifacts, out, BETA)
                self.assertFalse(out.exists())

    def test_no_deb_at_all_fails(self):
        files = {key: value for key, value in built_files(BETA).items() if not key.startswith("linux-deb-")}
        artifacts, out = self.artifacts(files)

        with self.assertRaisesRegex(release_assets.AssetError, r"ubuntu-\*\.deb"):
            release_assets.gather(artifacts, out, BETA)

    def test_a_package_of_another_version_fails(self):
        files = built_files(BETA)
        files["linux-deb-26.04-X64"][0] = "tablepro_0.1.0~beta.2-0ppa1~26.04_amd64.deb"
        artifacts, out = self.artifacts(files)

        with self.assertRaisesRegex(release_assets.AssetError, r"packages 0\.1\.0~beta\.2, not 0\.1\.0~beta\.1"):
            release_assets.gather(artifacts, out, BETA)

    def test_two_files_for_one_asset_fail(self):
        files = built_files(BETA)
        files["linux-deb-26.04-X64-again"] = [files["linux-deb-26.04-X64"][0]]
        artifacts, out = self.artifacts(files)

        with self.assertRaisesRegex(release_assets.AssetError, "would both publish"):
            release_assets.gather(artifacts, out, BETA)

    def test_a_version_the_release_workflow_refuses_fails(self):
        artifacts, out = self.artifacts(built_files("0.1.0-rc.1"))

        with self.assertRaisesRegex(release_assets.AssetError, "nor a beta"):
            release_assets.gather(artifacts, out, "0.1.0-rc.1")

    def test_main_reports_on_stderr_and_exits_1(self):
        files = built_files(BETA)
        del files["linux-flatpak-x86_64"]
        artifacts, out = self.artifacts(files)
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            failed = release_assets.main(["--version", BETA, str(artifacts), str(out)])

        self.assertEqual(failed, 1)
        self.assertIn("tablepro-0.1.0-beta.1-x86_64.flatpak", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
