import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def _stage_package(
    source: Path, root: Path, *, include_aliases: bool, include_schema: bool = True, include_askpass: bool = True
) -> Path:
    stage = root / "stage"
    for directory in (
        stage / "usr/bin",
        stage / "usr/share/applications",
        stage / "usr/share/metainfo",
        stage / "usr/share/icons/hicolor/scalable/apps",
        stage / "usr/share/doc/tablepro",
        stage / "usr/share/glib-2.0/schemas",
        stage / "DEBIAN",
    ):
        directory.mkdir(parents=True)
    _write_executable(stage / "usr/bin/bookie", "#!/bin/sh\nexit 0\n")
    _write_executable(
        stage / "usr/bin/bookie-agentd",
        "#!/bin/sh\necho 'usage: bookie-agentd --policy PATH'\n",
    )
    if include_askpass:
        _write_executable(stage / "usr/bin/tablepro-askpass", "#!/bin/sh\nexit 0\n")
    if include_aliases:
        (stage / "usr/bin/tablepro").symlink_to("bookie")
        (stage / "usr/bin/tablepro-agentd").symlink_to("bookie-agentd")
    (stage / "usr/share/applications/com.tablepro.linux.desktop").write_text(
        (source / "flatpak/com.tablepro.linux.desktop").read_text()
    )
    (stage / "usr/share/metainfo/com.tablepro.linux.metainfo.xml").write_text(
        (source / "flatpak/com.tablepro.linux.metainfo.xml").read_text()
    )
    (stage / "usr/share/icons/hicolor/scalable/apps/com.tablepro.linux.svg").write_text(
        (source / "flatpak/icons/scalable/com.tablepro.linux.svg").read_text()
    )
    if include_schema:
        shutil.copyfile(
            source / "data/com.tablepro.linux.gschema.xml",
            stage / "usr/share/glib-2.0/schemas/com.tablepro.linux.gschema.xml",
        )
    (stage / "usr/share/doc/tablepro/LICENSE.md").write_text((source / "LICENSE.md").read_text())
    (stage / "usr/share/doc/tablepro/policy.example.toml").write_text(
        (source / "packaging/policy.example.toml").read_text()
    )
    (stage / "DEBIAN/control").write_text(
        "Package: tablepro\n"
        "Version: 0.1.5-1\n"
        "Section: database\n"
        "Priority: optional\n"
        "Architecture: amd64\n"
        "Maintainer: TablePro Contributors <noreply@tablepro.app>\n"
        "Description: Native Linux database client\n"
        " BookiE test fixture\n"
    )
    package = root / "tablepro_0.1.5-1_amd64.deb"
    subprocess.run(
        ["dpkg-deb", "--root-owner-group", "--build", str(stage), str(package)],
        check=True,
        capture_output=True,
        text=True,
    )
    return package


def _listing_last_fields(package: Path) -> set[str]:
    listing = subprocess.check_output(["dpkg-deb", "-c", str(package)], text=True)
    return {line.split()[-1] for line in listing.splitlines() if line.strip()}


def check_builder_builds_and_installs_the_askpass_helper(source: Path) -> None:
    builder = (source / "scripts/build-deb.sh").read_text()
    assert "--bin tablepro-askpass" in builder, "build-deb.sh does not build the SSH askpass helper"
    assert "usr/bin/tablepro-askpass" in builder, "build-deb.sh does not install the SSH askpass helper"


def main() -> None:
    check_builder_builds_and_installs_the_askpass_helper(Path(__file__).resolve().parents[2])
    if shutil.which("dpkg-deb") is None:
        print("Debian package validation skipped: dpkg-deb is unavailable")
        return
    source = Path(__file__).resolve().parents[2]
    validator = source / "scripts/validate-deb-package.sh"
    with tempfile.TemporaryDirectory(prefix="bookie-deb-test-") as temporary:
        root = Path(temporary)
        valid = _stage_package(source, root / "valid", include_aliases=True)
        last_fields = _listing_last_fields(valid)
        assert "./usr/bin/tablepro" not in last_fields
        assert "bookie" in last_fields
        subprocess.run(["bash", str(validator), str(valid)], check=True)
        missing = _stage_package(source, root / "missing", include_aliases=False)
        result = subprocess.run(
            ["bash", str(validator), str(missing)],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0
        assert "package is missing /usr/bin/tablepro" in result.stderr, result.stderr
        missing_askpass = _stage_package(source, root / "missing-askpass", include_aliases=True, include_askpass=False)
        result = subprocess.run(["bash", str(validator), str(missing_askpass)], capture_output=True, text=True)
        assert result.returncode != 0
        assert "package is missing /usr/bin/tablepro-askpass" in result.stderr, result.stderr
        missing_schema = _stage_package(source, root / "missing-schema", include_aliases=True, include_schema=False)
        result = subprocess.run(["bash", str(validator), str(missing_schema)], capture_output=True, text=True)
        assert result.returncode != 0
        assert "package is missing /usr/share/glib-2.0/schemas/com.tablepro.linux.gschema.xml" in result.stderr, result.stderr
    print("Debian package symlink validation passed")


if __name__ == "__main__":
    main()
