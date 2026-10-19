import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    source = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="bookie-candidate-test-") as temporary:
        root = Path(temporary)
        scripts = root / "scripts"
        scripts.mkdir(parents=True)
        (root / "apps/linux/packaging/arch").mkdir(parents=True)
        (root / "apps/linux/app").mkdir(parents=True)
        (root / "crates/agentd").mkdir(parents=True)
        (root / "apps/linux/packaging/arch/PKGBUILD").write_text(
            "pkgname=bookie\ndepends=('gtk4')\nmakedepends=('rust')\ncheckdepends=('appstream')\n"
        )
        (root / "apps/linux/app/Cargo.toml").write_text('[package]\nname = "tablepro-app"\nversion = "0.1.1"\n')
        (root / "crates/agentd/Cargo.toml").write_text('[package]\nname = "tablepro-agentd"\nversion = "0.1.1"\n')
        shutil.copy(source / "scripts/build-arch-rc.sh", scripts)
        (scripts / "validate-arch-package.sh").write_text("#!/bin/sh\ntest -f \"$1\"\n")
        (scripts / "validate-arch-package.sh").chmod(0o755)
        (root / "probe").write_text("candidate bytes")
        for args in [
            ["init", "-q"], ["add", "."],
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
        ]:
            subprocess.run(["git", "-C", str(root), *args], check=True)
        initial_sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        sha = initial_sha
        commands = root / "commands"
        commands.mkdir()
        (commands / "cargo").write_text("""#!/bin/bash
set -eu
case "$1" in
  --version) echo 'cargo 1.98.0';;
  fetch) exit 0;;
  vendor)
    for arg in "$@"; do destination="$arg"; done
    mkdir -p "$destination"
    printf 'vendor fixture\n' > "$destination/fixture.crate"
    printf '[source.crates-io]\nreplace-with = "vendored-sources"\n[source.vendored-sources]\ndirectory = "%s"\n' "$destination"
    ;;
  *) exit 2;;
esac
""")
        (commands / "rustc").write_text("#!/bin/sh\necho 'rustc 1.98.0'\n")
        (commands / "makepkg").write_text("""#!/bin/bash
set -eu
if [[ "$1" == --packagelist ]]; then
  printf '%s\n' "$BOOKIE_TEST_PACKAGE" "$BOOKIE_TEST_DEBUG_PACKAGE"
else
  test "$TABLEPRO_RC_VERSION" = 0.1.1
  test "$TABLEPRO_RC_DATE" = 2026-10-19
  test -n "${SRCDEST:-}"
  test "$(basename "$TABLEPRO_RC_ARCHIVE")" = "bookie-0.1.1-$TABLEPRO_RC_COMMIT.tar.gz"
  test -f "$TABLEPRO_RC_ARCHIVE"
  test "$(sha256sum "$TABLEPRO_RC_ARCHIVE" | cut -d' ' -f1)" = "$TABLEPRO_RC_SHA256"
  test "$(tar -xOf "$TABLEPRO_RC_ARCHIVE" "TablePro-$TABLEPRO_RC_COMMIT/probe")" = 'candidate bytes'
  test -f "$TABLEPRO_RC_VENDOR_ARCHIVE"
  test "$(sha256sum "$TABLEPRO_RC_VENDOR_ARCHIVE" | cut -d' ' -f1)" = "$TABLEPRO_RC_VENDOR_SHA256"
  test "$(sha256sum "$TABLEPRO_RC_METADATA" | cut -d' ' -f1)" = "$TABLEPRO_RC_METADATA_SHA256"
  tar -tzf "$TABLEPRO_RC_VENDOR_ARCHIVE" | grep -Fq "TablePro-$TABLEPRO_RC_COMMIT/cargo-vendor/fixture.crate"
  tar -xOf "$TABLEPRO_RC_VENDOR_ARCHIVE" "TablePro-$TABLEPRO_RC_COMMIT/.cargo/config.toml" | grep -Fxq 'directory = "cargo-vendor"'
  python3 - "$TABLEPRO_RC_METADATA" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["commit"] == __import__("os").environ["TABLEPRO_RC_COMMIT"]
assert data["package_version"] == data["source_version"] == "0.1.1"
assert data["release_date"] == "2026-10-19"
assert data["tag"] == (__import__("os").environ.get("TABLEPRO_RC_TAG") or None)
assert data["native_build_inputs"] == {
    "depends": ["gtk4"], "makedepends": ["rust"], "checkdepends": ["appstream"]
}
assert len(data["vendor_archive_sha256"]) == 64
PY
  touch "$BOOKIE_TEST_PACKAGE" "$BOOKIE_TEST_DEBUG_PACKAGE"
fi
""")
        (commands / "namcap").write_text("#!/bin/sh\nexit 0\n")
        for command in commands.iterdir():
            command.chmod(0o755)
        environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                           TABLEPRO_RC_COMMIT=sha, TABLEPRO_RC_VERSION="0.1.1",
                           TABLEPRO_RC_DATE="2026-10-19", CARCH="x86_64",
                           TABLEPRO_RC_OUTPUT_DIR=str(root / "target/arch-release-inputs"),
                           BOOKIE_TEST_PACKAGE=str(root / "bookie-0.1.1-1-x86_64.pkg.tar.zst"),
                           BOOKIE_TEST_DEBUG_PACKAGE=str(root / "bookie-debug-0.1.1-1-x86_64.pkg.tar.zst"))
        (root / ".git/info/exclude").write_text("commands/\ntarget/\nremote.git/\n*.pkg.tar.zst\n")
        runner = ["bash", str(scripts / "build-arch-rc.sh")]
        subprocess.run(runner, env=environment, check=True)
        (root / "tag-anchor").write_text("tag fixture\n")
        subprocess.run(["git", "-C", str(root), "add", "tag-anchor"], check=True)
        subprocess.run([
            "git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "-qm", "tag anchor",
        ], check=True)
        sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        environment["TABLEPRO_RC_COMMIT"] = sha
        remote = root / "remote.git"
        subprocess.run(["git", "clone", "--bare", str(root), str(remote)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(root), "tag", "linux-v0.1.1"], check=True)
        subprocess.run(["git", "-C", str(root), "push", str(remote), "linux-v0.1.1"], check=True, capture_output=True)
        tag_environment = dict(environment, TABLEPRO_RC_COMMIT="", TABLEPRO_RC_TAG="linux-v0.1.1",
                              TABLEPRO_RC_REMOTE=str(remote))
        subprocess.run(runner, env=tag_environment, check=True)
        subprocess.run(["git", "-C", str(root), "tag", "wrong-remote-tag"], check=True)
        subprocess.run(["git", "-C", str(root), "push", str(remote), "wrong-remote-tag"], check=True,
                       capture_output=True)
        subprocess.run(["git", "-C", str(remote), "update-ref", "refs/tags/wrong-remote-tag", initial_sha],
                       check=True)
        for overrides, expected in [
            ({"TABLEPRO_RC_COMMIT": "HEAD"}, "full immutable commit SHA"),
            ({"TABLEPRO_RC_TAG": "linux-v0.1.1"}, "not both"),
            ({"TABLEPRO_RC_VERSION": "../unsafe"}, "invalid candidate version"),
            ({"TABLEPRO_RC_VERSION": "0.1.2"}, "does not match app and agentd source version"),
            ({"TABLEPRO_RC_DATE": "2026-02-30"}, "invalid candidate release date"),
            ({"TABLEPRO_RC_COMMIT": "", "TABLEPRO_RC_TAG": "wrong-remote-tag",
              "TABLEPRO_RC_REMOTE": str(remote)}, "does not resolve to local commit"),
        ]:
            result = subprocess.run(runner, env=dict(environment, **overrides), capture_output=True, text=True)
            assert result.returncode != 0, result.stderr
            assert expected in result.stderr, result.stderr
        (root / "probe").write_text("uncommitted bytes")
        result = subprocess.run(runner, env=environment, capture_output=True, text=True)
        assert result.returncode != 0, result.stderr
        assert "dirty tree" in result.stderr, result.stderr
    print("candidate archive and rejection checks passed")


if __name__ == "__main__":
    main()
