import io
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "packaging" / "build-rpm.sh"

# Mock keeps the configuration of every call and builds an empty package.
MOCK = """#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$MOCK_CALLS"
result=""
while [ $# -gt 0 ]; do
    case "$1" in
    -r) cp "$2" "$MOCK_CONFIG" ;;
    --resultdir) result="$2"; shift ;;
    --rebuild)
        mkdir -p "$result"
        touch "$result/tablepro-0.1.0-1.fc44.x86_64.rpm"
        printf 'mock build log\\n' > "$result/build.log"
        ;;
    esac
    shift
done
"""

RPMBUILD = """#!/bin/sh
set -eu
build_top=${2#_topdir }
mkdir -p "$build_top/SRPMS"
touch "$build_top/SRPMS/tablepro.src.rpm"
"""


class BuildRpmTest(unittest.TestCase):
    def test_every_mock_call_builds_through_ccache_in_the_stock_chroot(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            tools = work / "bin"
            tools.mkdir()
            for name, script in {
                "mock": MOCK,
                "rpmbuild": RPMBUILD,
                "dnf": "#!/bin/sh\nexit 0\n",
                "rpmlint": "#!/bin/sh\nexit 0\n",
                "rpm": "#!/bin/sh\necho 44\n",
                "uname": "#!/bin/sh\necho x86_64\n",
                "ip": "#!/bin/sh\nexit 0\n",
                "unshare": "#!/bin/sh\nshift\nexec \"$@\"\n",
            }.items():
                tool = tools / name
                tool.write_text(script)
                tool.chmod(0o755)
            source = work / "tablepro-0.1.0.tar.xz"
            vendor = work / "tablepro-0.1.0-vendor.tar.xz"
            with tarfile.open(source, "w:xz") as archive:
                spec = b"Name: tablepro\n"
                entry = tarfile.TarInfo("tablepro-0.1.0/linux/build-aux/rpm/tablepro.spec")
                entry.size = len(spec)
                archive.addfile(entry, io.BytesIO(spec))
            vendor.touch()
            calls = work / "calls"
            config = work / "mock.cfg"
            environment = dict(
                os.environ,
                PATH=f"{tools}:{os.environ['PATH']}",
                MOCK_CALLS=str(calls),
                MOCK_CONFIG=str(config),
            )

            result = subprocess.run(
                ["sh", str(SCRIPT), str(source), str(vendor), str(work / "output")],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            mock_calls = calls.read_text().splitlines()
            self.assertEqual(len(mock_calls), 3)
            self.assertTrue(all(call.startswith("-r ") and ".cfg " in call for call in mock_calls))
            lines = config.read_text().splitlines()
            self.assertEqual(lines[0], "include('fedora-44-x86_64.cfg')")
            self.assertIn("config_opts['plugin_conf']['ccache_enable'] = True", lines)
            self.assertIn(
                "config_opts['environment']['PATH'] = '/usr/lib64/ccache:' + config_opts['environment']['PATH']",
                lines,
            )


if __name__ == "__main__":
    unittest.main()
