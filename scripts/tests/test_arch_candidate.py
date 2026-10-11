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
        shutil.copy(source / "scripts/build-arch-rc.sh", scripts)
        (scripts / "validate-arch-package.sh").write_text("#!/bin/sh\ntest -f \"$1\"\n")
        (scripts / "validate-arch-package.sh").chmod(0o755)
        (root / "probe").write_text("candidate bytes")
        for args in [
            ["init", "-q"], ["add", "."],
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"],
        ]:
            subprocess.run(["git", "-C", str(root), *args], check=True)
        sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
        commands = root / "commands"
        commands.mkdir()
        (commands / "makepkg").write_text("""#!/bin/bash
set -eu
if [[ "$1" == --packagelist ]]; then
  printf '%s\n' "$BOOKIE_TEST_PACKAGE" "$BOOKIE_TEST_DEBUG_PACKAGE"
else
  test "$TABLEPRO_RC_VERSION" = 0.1.1
  test -n "${SRCDEST:-}"
  test "$(basename "$TABLEPRO_RC_ARCHIVE")" = bookie-0.1.1.tar.gz
  test -f "$SRCDEST/$(basename "$TABLEPRO_RC_ARCHIVE")"
  test "$(sha256sum "$TABLEPRO_RC_ARCHIVE" | cut -d' ' -f1)" = "$TABLEPRO_RC_SHA256"
  test "$(tar -xOf "$TABLEPRO_RC_ARCHIVE" "TablePro-$TABLEPRO_RC_COMMIT/probe")" = 'candidate bytes'
  touch "$BOOKIE_TEST_PACKAGE" "$BOOKIE_TEST_DEBUG_PACKAGE"
fi
""")
        (commands / "namcap").write_text("#!/bin/sh\nexit 0\n")
        for command in commands.iterdir():
            command.chmod(0o755)
        environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                           TABLEPRO_RC_COMMIT=sha, TABLEPRO_RC_VERSION="0.1.1",
                           BOOKIE_TEST_PACKAGE=str(root / "bookie-0.1.1-1-x86_64.pkg.tar.zst"),
                           BOOKIE_TEST_DEBUG_PACKAGE=str(root / "bookie-debug-0.1.1-1-x86_64.pkg.tar.zst"))
        (root / ".git/info/exclude").write_text("commands/\n*.pkg.tar.zst\n")
        runner = ["bash", str(scripts / "build-arch-rc.sh")]
        subprocess.run(runner, env=environment, check=True)
        for overrides, expected in [
            ({"TABLEPRO_RC_COMMIT": "HEAD"}, "full immutable commit SHA"),
            ({"TABLEPRO_RC_TAG": "linux-v0.1.1"}, "not both"),
            ({"TABLEPRO_RC_VERSION": "../unsafe"}, "invalid candidate version"),
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
