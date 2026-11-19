import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ElementTree
import zipfile

SCRIPT = pathlib.Path(__file__).with_name("appinstaller.py")
spec = importlib.util.spec_from_file_location("appinstaller", SCRIPT)
appinstaller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appinstaller)

PUBLISHER = "CN=TablePro, O=TablePro, L=Ho Chi Minh City, C=VN"
NS = "{http://schemas.microsoft.com/appx/appinstaller/2017/2}"


def bundle(folder: pathlib.Path, version: str, publisher: str = PUBLISHER) -> pathlib.Path:
    path = folder / f"TablePro_{version}_x64_arm64.msixbundle"
    manifest = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle" SchemaVersion="5.0">'
        f'<Identity Name="TablePro" Publisher="{publisher}" Version="{version}" /></Bundle>'
    )
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("AppxMetadata/AppxBundleManifest.xml", manifest)
    return path


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, check=False)


class PackageVersionTests(unittest.TestCase):
    def test_a_beta_sorts_below_its_release_and_above_the_release_before(self):
        versions = ["0.1.0", "0.2.0-beta.1", "0.2.0-beta.2", "0.2.0", "0.2.1", "0.10.0-beta.1"]
        packages = [appinstaller.package_version(version)[0] for version in versions]
        self.assertEqual(packages, ["0.1.0.99", "0.2.0.1", "0.2.0.2", "0.2.0.99", "0.2.1.99", "0.10.0.1"])
        keys = [tuple(int(part) for part in package.split(".")) for package in packages]
        self.assertEqual(keys, sorted(keys))

    def test_the_channel_follows_the_tag(self):
        self.assertEqual(appinstaller.package_version("1.2.3")[1], "stable")
        self.assertEqual(appinstaller.package_version("1.2.3-beta.98")[1], "beta")

    def test_refuses_what_msix_or_the_channels_cannot_order(self):
        for version in ["0.2", "0.2.0.0", "v0.2.0", "01.2.0", "0.2.0-beta.0", "0.2.0-beta.99", "0.2.0-beta",
                        "0.2.0-rc.1", "65536.0.0", "0.2.0-beta.01"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                appinstaller.package_version(version)
        self.assertEqual(appinstaller.package_version("65535.65535.65535")[0], "65535.65535.65535.99")

    def test_version_prints_what_the_workflow_reads(self):
        result = run("version", "0.3.0-beta.4")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "package=0.3.0.4\nchannel=beta\nappinstaller=TablePro-Beta.appinstaller\n")
        self.assertNotEqual(run("version", "0.3.0-rc.1").returncode, 0)


class WriteTests(unittest.TestCase):
    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp())

    def read(self, path: pathlib.Path) -> ElementTree.Element:
        return ElementTree.fromstring(path.read_bytes())

    def test_a_release_names_its_bundle_and_the_stable_channel_file(self):
        out = self.folder / "TablePro.appinstaller"
        url = "https://github.com/TableProApp/TablePro/releases/download/windows-v0.2.0/TablePro_0.2.0.99_x64_arm64.msixbundle"
        result = run("write", "--version", "0.2.0", "--bundle", str(bundle(self.folder, "0.2.0.99")),
                     "--bundle-uri", url, "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        root = self.read(out)
        self.assertEqual(root.tag, f"{NS}AppInstaller")
        self.assertEqual(root.attrib, {"Version": "0.2.0.99", "Uri": "https://updates.tablepro.app/windows/TablePro.appinstaller"})
        main = root.find(f"{NS}MainBundle")
        self.assertEqual(main.attrib, {"Name": "TablePro", "Publisher": PUBLISHER, "Version": "0.2.0.99", "Uri": url})
        self.assertEqual(root.find(f"{NS}UpdateSettings/{NS}OnLaunch").attrib, {"HoursBetweenUpdateChecks": "24"})
        self.assertIsNotNone(root.find(f"{NS}UpdateSettings/{NS}AutomaticBackgroundTask"))
        out.read_bytes().decode("ascii")

    def test_a_beta_points_at_the_beta_channel_file(self):
        out = self.folder / "TablePro-Beta.appinstaller"
        result = run("write", "--version", "0.3.0-beta.2", "--bundle", str(bundle(self.folder, "0.3.0.2")),
                     "--bundle-uri", "https://example.invalid/b.msixbundle", "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        root = self.read(out)
        self.assertEqual(root.get("Uri"), "https://updates.tablepro.app/windows/TablePro-Beta.appinstaller")
        self.assertIsNone(root.find(f"{NS}UpdateSettings"))

    def test_a_dry_run_names_its_own_location(self):
        out = self.folder / "local.appinstaller"
        result = run("write", "--version", "0.1.0", "--bundle", str(bundle(self.folder, "0.1.0.99")),
                     "--bundle-uri", "file:///D:/a/release/b.msixbundle", "--uri", "file:///D:/a/local.appinstaller",
                     "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read(out).get("Uri"), "file:///D:/a/local.appinstaller")

    def test_refuses_a_bundle_of_another_version(self):
        result = run("write", "--version", "0.2.0", "--bundle", str(bundle(self.folder, "0.2.0.0")),
                     "--bundle-uri", "https://example.invalid/b.msixbundle", "--out", str(self.folder / "x.appinstaller"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not 0.2.0.99", result.stderr)

    def test_refuses_what_app_installer_cannot_read(self):
        for publisher in ["CN=Tablé", "CN=A & B", 'CN="Quoted"']:
            with self.subTest(publisher=publisher):
                result = run("write", "--version", "0.2.0",
                             "--bundle", str(bundle(self.folder, "0.2.0.99", publisher.replace("&", "&amp;").replace('"', "&quot;"))),
                             "--bundle-uri", "https://example.invalid/b.msixbundle",
                             "--out", str(self.folder / "x.appinstaller"))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cannot hold", result.stderr)


class ChannelTests(unittest.TestCase):
    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp())
        self.site = self.folder / "site"

    def release(self, version: str) -> pathlib.Path:
        package = appinstaller.package_version(version)[0]
        out = self.folder / f"{version}.appinstaller"
        url = f"https://github.com/TableProApp/TablePro/releases/download/windows-v{version}/TablePro_{package}_x64_arm64.msixbundle"
        result = run("write", "--version", version, "--bundle", str(bundle(self.folder, package)), "--bundle-uri", url,
                     "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        return out

    def publish(self, version: str) -> subprocess.CompletedProcess:
        return run("channels", "--release", str(self.release(version)), "--site", str(self.site))

    def published(self, channel: str) -> tuple[str, str]:
        root = ElementTree.fromstring((self.site / appinstaller.FILES[channel]).read_bytes())
        return root.get("Uri"), root.find(f"{NS}MainBundle").get("Version")

    def test_a_beta_moves_only_the_beta_channel(self):
        self.assertEqual(self.publish("0.2.0-beta.1").returncode, 0)
        self.assertEqual(self.published("beta"), (appinstaller.channel_uri("beta"), "0.2.0.1"))
        self.assertFalse((self.site / "TablePro.appinstaller").exists())

    def test_a_release_moves_both_channels_unless_a_newer_beta_is_out(self):
        self.assertEqual(self.publish("0.2.0").returncode, 0)
        self.assertEqual(self.published("stable"), (appinstaller.channel_uri("stable"), "0.2.0.99"))
        self.assertEqual(self.published("beta"), (appinstaller.channel_uri("beta"), "0.2.0.99"))
        beta = ElementTree.fromstring((self.site / "TablePro-Beta.appinstaller").read_bytes())
        self.assertIsNone(beta.find(f"{NS}UpdateSettings"))
        stable = ElementTree.fromstring((self.site / "TablePro.appinstaller").read_bytes())
        self.assertIsNotNone(stable.find(f"{NS}UpdateSettings/{NS}AutomaticBackgroundTask"))

        self.assertEqual(self.publish("0.3.0-beta.1").returncode, 0)
        result = self.publish("0.2.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.published("stable")[1], "0.2.1.99")
        self.assertEqual(self.published("beta")[1], "0.3.0.1")

    def test_a_channel_never_moves_back(self):
        self.assertEqual(self.publish("0.3.0-beta.2").returncode, 0)
        result = self.publish("0.3.0-beta.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("above 0.3.0.1", result.stderr)
        self.assertEqual(self.published("beta")[1], "0.3.0.2")
        self.assertEqual(self.publish("0.3.0-beta.2").returncode, 0)


if __name__ == "__main__":
    unittest.main()
