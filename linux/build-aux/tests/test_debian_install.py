import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RULES = Path(__file__).resolve().parent.parent / "debian" / "rules"
AVAILABLE = all(shutil.which(tool) for tool in ("meson", "ninja", "make", "dpkg-architecture"))
AVAILABLE = AVAILABLE and Path("/usr/share/dpkg/buildopts.mk").is_file()


@unittest.skipUnless(AVAILABLE, "requires Meson and Debian build tools")
class DebianInstallTest(unittest.TestCase):
    def test_install_preserves_built_binaries_without_running_builder(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "debian").mkdir()
            shutil.copyfile(RULES, root / "debian" / "rules")
            source = root / "linux"
            source.mkdir()
            (source / "meson.build").write_text(
                "project('install-regression', version: '1')\n"
                "custom_target('cargo-build', build_always_stale: true, "
                "build_by_default: true, output: ['tablepro', 'tablepro-askpass'], "
                "command: ['sh', files('build.sh'), '@OUTPUT0@', '@OUTPUT1@'], "
                "install: true, install_dir: ['bin', 'libexec'])\n"
                "install_data('data.txt', install_dir: 'share/tablepro')\n"
                "install_data('_tablepro', install_dir: 'share/zsh/site-functions')\n"
            )
            builder = source / "build.sh"
            builder.write_text('printf app > "$1"\nprintf askpass > "$2"\n')
            (source / "data.txt").write_text("package data")
            (source / "_tablepro").write_text("#compdef tablepro")
            triple = subprocess.check_output(["dpkg-architecture", "-qDEB_HOST_GNU_TYPE"], text=True).strip()
            build = root / f"obj-{triple}"
            subprocess.run(["meson", "setup", str(build), str(source), "--prefix=/usr"], check=True)
            subprocess.run(["meson", "compile", "-C", str(build)], check=True)
            builder.write_text("exit 99\n")

            subprocess.run(["make", "-f", "debian/rules", "override_dh_auto_install"], cwd=root, check=True)

            staged = root / "debian" / "tablepro" / "usr"
            self.assertEqual((staged / "bin" / "tablepro").read_text(), "app")
            self.assertEqual((staged / "libexec" / "tablepro-askpass").read_text(), "askpass")
            self.assertEqual((staged / "share" / "tablepro" / "data.txt").read_text(), "package data")
            self.assertEqual(
                (staged / "share" / "zsh" / "vendor-completions" / "_tablepro").read_text(), "#compdef tablepro"
            )
            self.assertFalse((staged / "share" / "zsh" / "site-functions").exists())


if __name__ == "__main__":
    unittest.main()
