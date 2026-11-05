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
MATRIX = {
    "ubuntu": [{"series": "resolute", "version": "26.04"}, {"series": "stonking", "version": "26.10"}],
    "fedora": ["44", "45"],
    "architectures": [
        {"runner": "ubuntu-24.04", "deb": "amd64", "rpm": "x86_64", "flatpak": "x86_64"},
        {"runner": "ubuntu-24.04-arm", "deb": "arm64", "rpm": "aarch64", "flatpak": "aarch64"},
    ],
}


def built_files(version):
    packaged = version.replace("-", "~", 1)
    files = {
        "linux-sources": [f"tablepro-{version}.tar.xz", f"tablepro-{version}-vendor.tar.xz"],
        "linux-pot": ["tablepro.pot"],
        "linux-flatpak-bundles": ["tablepro-x86_64.flatpak", "tablepro-aarch64.flatpak"],
    }
    for name in ("26.04", "26.10"):
        for arch, runner in (("amd64", "X64"), ("arm64", "ARM64")):
            files[f"linux-deb-{name}-{runner}"] = [
                f"tablepro_{packaged}-0ppa1~{name}_{arch}.deb",
                f"tablepro-dbgsym_{packaged}-0ppa1~{name}_{arch}.ddeb",
                f"tablepro_{packaged}-0ppa1~{name}_{arch}.buildinfo",
                f"tablepro_{packaged}-0ppa1~{name}_{arch}.changes",
            ]
    for fedora in ("44", "45"):
        for arch, runner in (("x86_64", "X64"), ("aarch64", "ARM64")):
            files[f"linux-rpm-{fedora}-{runner}"] = [
                f"tablepro-{packaged}-1.fc{fedora}.{arch}.rpm",
                f"tablepro-debuginfo-{packaged}-1.fc{fedora}.{arch}.rpm",
                f"tablepro-debugsource-{packaged}-1.fc{fedora}.{arch}.rpm",
                f"tablepro-{packaged}-1.fc{fedora}.src.rpm",
            ]
    return files


def declared(version):
    """What each package's own metadata says, read from its asset name as the real tools would."""
    packaged = version.replace("-", "~", 1)

    def read_deb(path):
        arch = path.name.rsplit("-", 1)[1].removesuffix(".deb")
        return ("tablepro", f"{packaged}-0ppa1~26.04", arch)

    def read_rpm(path):
        arch = path.name.rsplit("-", 1)[1].removesuffix(".rpm")
        return ("tablepro", packaged, arch)

    return read_deb, read_rpm


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

    def test_a_beta_publishes_every_declared_package_without_a_tilde(self):
        artifacts, out = self.artifacts(built_files(BETA))

        names = release_assets.gather(artifacts, out, BETA, MATRIX)

        self.assertEqual(len(names), 3 + 2 * 2 + 2 * 2 + 2)
        self.assertIn("tablepro-0.1.0-beta.1-ubuntu-26.10-arm64.deb", names)
        self.assertIn("tablepro-0.1.0-beta.1-fedora-45-aarch64.rpm", names)
        self.assertIn("tablepro-0.1.0-beta.1-x86_64.flatpak", names)
        self.assertEqual(sorted(path.name for path in out.iterdir()), sorted([*names, "SHA256SUMS"]))
        self.assertFalse(any("~" in name for name in names))

    def test_sha256sums_lists_each_asset_as_sha256sum_does(self):
        artifacts, out = self.artifacts(built_files("0.1.0"))

        names = release_assets.gather(artifacts, out, "0.1.0", MATRIX)

        lines = (out / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        self.assertEqual([line.split("  ", 1)[1] for line in lines], names)
        for line in lines:
            digest, name = line.split("  ", 1)
            self.assertEqual(digest, hashlib.sha256((out / name).read_bytes()).hexdigest())

    def test_the_debs_keep_their_builds_apart(self):
        artifacts, out = self.artifacts(built_files("0.1.0"))

        release_assets.gather(artifacts, out, "0.1.0", MATRIX)

        self.assertEqual(
            (out / "tablepro-0.1.0-ubuntu-26.10-arm64.deb").read_text(encoding="utf-8"),
            "linux-deb-26.10-ARM64/tablepro_0.1.0-0ppa1~26.10_arm64.deb",
        )

    def test_a_missing_architecture_series_or_release_fails(self):
        cases = {
            "an architecture": ["linux-deb-26.10-ARM64"],
            "a whole Ubuntu series": ["linux-deb-26.10-X64", "linux-deb-26.10-ARM64"],
            "a whole Fedora release": ["linux-rpm-45-X64", "linux-rpm-45-ARM64"],
            "the bundles": ["linux-flatpak-bundles"],
            "the template": ["linux-pot"],
        }
        for case, directories in cases.items():
            with self.subTest(case=case):
                files = built_files(BETA)
                for directory in directories:
                    del files[directory]
                artifacts, out = self.artifacts(files)

                with self.assertRaisesRegex(release_assets.AssetError, "the release has no"):
                    release_assets.gather(artifacts, out, BETA, MATRIX)
                self.assertFalse(out.exists())

    def test_a_package_the_matrix_does_not_declare_fails(self):
        files = built_files(BETA)
        files["linux-deb-27.04-X64"] = ["tablepro_0.1.0~beta.1-0ppa1~27.04_amd64.deb"]
        artifacts, out = self.artifacts(files)

        with self.assertRaisesRegex(release_assets.AssetError, "declares no tablepro-0.1.0-beta.1-ubuntu-27.04"):
            release_assets.gather(artifacts, out, BETA, MATRIX)

    def test_a_package_of_another_version_fails(self):
        files = built_files(BETA)
        files["linux-deb-26.04-X64"][0] = "tablepro_0.1.0~beta.2-0ppa1~26.04_amd64.deb"
        artifacts, out = self.artifacts(files)

        with self.assertRaisesRegex(release_assets.AssetError, r"packages 0\.1\.0~beta\.2, not 0\.1\.0~beta\.1"):
            release_assets.gather(artifacts, out, BETA, MATRIX)

    def test_two_files_for_one_asset_fail(self):
        files = built_files(BETA)
        files["linux-deb-26.04-X64-again"] = [files["linux-deb-26.04-X64"][0]]
        artifacts, out = self.artifacts(files)

        with self.assertRaisesRegex(release_assets.AssetError, "would both publish"):
            release_assets.gather(artifacts, out, BETA, MATRIX)

    def test_a_version_the_release_workflow_refuses_fails(self):
        artifacts, out = self.artifacts(built_files("0.1.0-rc.1"))

        with self.assertRaisesRegex(release_assets.AssetError, "nor a beta"):
            release_assets.gather(artifacts, out, "0.1.0-rc.1", MATRIX)

    def test_the_committed_matrix_declares_both_architectures(self):
        matrix = release_assets.load_matrix()

        self.assertEqual([arch["deb"] for arch in matrix["architectures"]], ["amd64", "arm64"])
        self.assertTrue(matrix["ubuntu"] and matrix["fedora"])


class VerifyTests(unittest.TestCase):
    def release(self, version=BETA):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        root = Path(workdir.name)
        for directory, names in built_files(version).items():
            (root / "artifacts" / directory).mkdir(parents=True)
            for name in names:
                (root / "artifacts" / directory / name).write_text(name, encoding="utf-8")
        release_assets.gather(root / "artifacts", root / "release", version, MATRIX)
        return root / "release"

    def test_a_gathered_release_verifies(self):
        release = self.release()
        read_deb, read_rpm = declared(BETA)

        names = release_assets.verify(release, BETA, MATRIX, read_deb, read_rpm)

        self.assertEqual(len(names), 13)

    def test_a_changed_file_fails(self):
        release = self.release()
        (release / "tablepro-0.1.0-beta.1-aarch64.flatpak").write_text("changed", encoding="utf-8")

        with self.assertRaisesRegex(release_assets.AssetError, "does not match its SHA256SUMS line"):
            release_assets.verify(release, BETA, MATRIX, *declared(BETA))

    def test_a_missing_file_fails(self):
        release = self.release()
        (release / "tablepro-0.1.0-beta.1-fedora-44-x86_64.rpm").unlink()

        with self.assertRaisesRegex(release_assets.AssetError, "the release has no"):
            release_assets.verify(release, BETA, MATRIX, *declared(BETA))

    def test_a_package_that_declares_another_version_or_architecture_fails(self):
        release = self.release()
        read_deb, read_rpm = declared(BETA)
        cases = {
            "version": (read_deb, lambda path: ("tablepro", "0.1.0~beta.2", read_rpm(path)[2])),
            "architecture": (lambda path: ("tablepro", read_deb(path)[1], "i386"), read_rpm),
            "name": (read_deb, lambda path: ("other", read_rpm(path)[1], read_rpm(path)[2])),
        }
        for case, readers in cases.items():
            with self.subTest(case=case):
                with self.assertRaises(release_assets.AssetError):
                    release_assets.verify(release, BETA, MATRIX, *readers)

    def test_main_reports_on_stderr_and_exits_1(self):
        workdir = tempfile.TemporaryDirectory()
        self.addCleanup(workdir.cleanup)
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            failed = release_assets.main(["verify", "--version", BETA, workdir.name])

        self.assertEqual(failed, 1)
        self.assertIn("SHA256SUMS", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
