import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]
BINARIES = ("tablepro-app", "tablepro-agentd", "tablepro-askpass")

FAKE_CARGO = """#!/bin/bash
set -eu
echo "$*" >> "$CARGO_LOG"
profile=release
while [ $# -gt 0 ]; do
  case "$1" in
    --release) profile=release ;;
    --profile) shift; profile="$1" ;;
  esac
  shift
done
mkdir -p "$CARGO_TARGET_DIR/$profile"
for bin in tablepro-app tablepro-agentd tablepro-askpass; do
  printf '#!/bin/sh\\necho %s\\n' "$profile" > "$CARGO_TARGET_DIR/$profile/$bin"
  chmod +x "$CARGO_TARGET_DIR/$profile/$bin"
done
"""


def _executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def _fake_tools(root: Path) -> dict[str, str]:
    bin_dir = root / "bin"
    bin_dir.mkdir()
    _executable(bin_dir / "cargo", FAKE_CARGO)
    _executable(bin_dir / "dpkg-deb", "#!/bin/sh\nexit 0\n")
    _executable(bin_dir / "strip", "#!/bin/sh\nexit 0\n")
    return {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "CARGO_LOG": str(root / "cargo.log"),
        "CARGO_TARGET_DIR": str(root / "target"),
    }


def _deb_checkout(root: Path) -> Path:
    checkout = root / "checkout"
    shutil.copytree(SOURCE / "scripts", checkout / "scripts")
    for relative in (
        "Cargo.toml",
        "LICENSE.md",
        "apps/linux/flatpak/com.tablepro.linux.desktop",
        "apps/linux/flatpak/com.tablepro.linux.metainfo.xml",
        "apps/linux/flatpak/icons/scalable/com.tablepro.linux.svg",
        "apps/linux/data/com.tablepro.linux.gschema.xml",
        "apps/linux/packaging/policy.example.toml",
    ):
        (checkout / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE / relative, checkout / relative)
    (checkout / "scripts/dev-env.sh").unlink(missing_ok=True)
    _executable(checkout / "scripts/validate-deb-package.sh", "#!/bin/sh\nexit 0\n")
    return checkout


def _build_deb(profile: str | None) -> tuple[subprocess.CompletedProcess, Path]:
    root = Path(tempfile.mkdtemp(prefix="bookie-profile-deb-"))
    env = _fake_tools(root)
    env.pop("BOOKIE_BUILD_PROFILE", None)
    if profile is not None:
        env["BOOKIE_BUILD_PROFILE"] = profile
    env["DEB_OUT"] = str(root / "out")
    env["DEB_VERSION"] = "0.0.0-1"
    checkout = _deb_checkout(root)
    result = subprocess.run(
        ["bash", str(checkout / "scripts/build-deb.sh")], env=env, capture_output=True, text=True
    )
    return result, root


def _staged_profile(root: Path) -> str:
    staged = root / "out/bookie_0.0.0-1_amd64/usr/bin/bookie"
    return staged.read_text().split("echo ", 1)[1].strip()


def _pkgbuild_build(profile: str | None) -> tuple[subprocess.CompletedProcess, Path]:
    root = Path(tempfile.mkdtemp(prefix="bookie-profile-arch-"))
    env = _fake_tools(root)
    env.pop("BOOKIE_BUILD_PROFILE", None)
    if profile is not None:
        env["BOOKIE_BUILD_PROFILE"] = profile
    for name in ("VERSION", "COMMIT", "SHA256", "ARCHIVE", "VENDOR_SHA256", "VENDOR_ARCHIVE", "METADATA", "METADATA_SHA256"):
        env[f"TABLEPRO_RC_{name}"] = "fixture"
    srcdir = root / "src"
    (srcdir / "TablePro-fixture").mkdir(parents=True)
    script = (
        f'source "{SOURCE}/apps/linux/packaging/arch/PKGBUILD"\n'
        f'srcdir="{srcdir}"\n_commit=fixture\n'
        "build\n"
        'printf "%s\\n" "$(_cargo_profile_dir)"\n'
    )
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", script], env=env, capture_output=True, text=True)
    return result, root


def _cargo_calls(root: Path) -> list[str]:
    return (root / "cargo.log").read_text().splitlines()


class PackageBuildProfileTests(unittest.TestCase):
    def test_published_packages_build_with_the_distribution_profile(self) -> None:
        deb, deb_root = _build_deb(None)
        self.addCleanup(shutil.rmtree, deb_root)
        assert deb.returncode == 0, deb.stderr
        assert all("--profile dist" in call for call in _cargo_calls(deb_root))
        assert _staged_profile(deb_root) == "dist"

        arch, arch_root = _pkgbuild_build(None)
        self.addCleanup(shutil.rmtree, arch_root)
        assert arch.returncode == 0, arch.stderr
        assert all("--profile dist" in call for call in _cargo_calls(arch_root))
        assert arch.stdout.strip().endswith("target/dist")


    def test_ci_can_build_packages_with_the_faster_release_profile(self) -> None:
        deb, deb_root = _build_deb("release")
        self.addCleanup(shutil.rmtree, deb_root)
        assert deb.returncode == 0, deb.stderr
        assert all("--profile release" in call for call in _cargo_calls(deb_root))
        assert _staged_profile(deb_root) == "release"

        arch, arch_root = _pkgbuild_build("release")
        self.addCleanup(shutil.rmtree, arch_root)
        assert arch.returncode == 0, arch.stderr
        assert arch.stdout.strip().endswith("target/release")


    def test_an_unknown_build_profile_is_refused(self) -> None:
        deb, deb_root = _build_deb("dev")
        self.addCleanup(shutil.rmtree, deb_root)
        assert deb.returncode != 0
        assert not (deb_root / "cargo.log").exists()

        arch, arch_root = _pkgbuild_build("dev")
        self.addCleanup(shutil.rmtree, arch_root)
        assert arch.returncode != 0
        assert not (arch_root / "cargo.log").exists()


if __name__ == "__main__":
    unittest.main()
