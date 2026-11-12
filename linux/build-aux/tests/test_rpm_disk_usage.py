import csv
import io
import os
import subprocess
import tempfile
import tarfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "packaging" / "build-rpm.sh"


class RpmDiskUsageTest(unittest.TestCase):
    def test_a_failed_build_keeps_its_exit_code_and_stops_the_sampler(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            tools = work / "bin"
            tools.mkdir()
            dnf = tools / "dnf"
            dnf.write_text("#!/bin/sh\nexit 0\n")
            dnf.chmod(0o755)
            rpmbuild = tools / "rpmbuild"
            rpmbuild.write_text("""#!/bin/sh
set -eu
build_top=${2#_topdir }
mkdir -p "$build_top/SRPMS"
touch "$build_top/SRPMS/tablepro.src.rpm"
""")
            rpmbuild.chmod(0o755)
            mock_root = work / "mock root"
            mock = tools / "mock"
            # Mock removes a failed build's chroot unless told to keep it.
            mock.write_text(f"""#!/bin/sh
set -eu
keep=no
result=""
while [ $# -gt 0 ]; do
    case "$1" in
    --print-root-path) echo '{mock_root}'; exit 0 ;;
    --config-opts=cleanup_on_failure=False) keep=yes ;;
    --resultdir) result="$2"; shift ;;
    --rebuild)
        mkdir -p '{mock_root}/builddir/build/BUILD/failed/meson-logs' "$result"
        printf 'package test failed\\n' > '{mock_root}/builddir/build/BUILD/failed/meson-logs/testlog.txt'
        printf 'mock build log\\n' > "$result/build.log"
        sleep 2
        if [ "$keep" = no ]; then
            rm -rf '{mock_root}'
        fi
        exit 37
        ;;
    esac
    shift
done
""")
            mock.chmod(0o755)
            for name, script in {
                "rpm": "#!/bin/sh\necho 44\n",
                "ip": "#!/bin/sh\nexit 0\n",
                "unshare": "#!/bin/sh\nshift\nexec \"$@\"\n",
            }.items():
                tool = tools / name
                tool.write_text(script)
                tool.chmod(0o755)
            temporary = work / "temporary"
            temporary.mkdir()
            source = work / "tablepro-0.1.0.tar.xz"
            vendor = work / "tablepro-0.1.0-vendor.tar.xz"
            with tarfile.open(source, "w:xz") as archive:
                spec = b"Name: tablepro\n"
                entry = tarfile.TarInfo("tablepro-0.1.0/linux/build-aux/rpm/tablepro.spec")
                entry.size = len(spec)
                archive.addfile(entry, io.BytesIO(spec))
            vendor.touch()
            output = work / "output"
            environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", TMPDIR=str(temporary))

            # An orphan sampler holds the captured pipes open after the build exits.
            result = subprocess.run(
                ["sh", str(SCRIPT), str(source), str(vendor), str(output)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 37, result.stderr)
            self.assertEqual(list(temporary.iterdir()), [])
            self.assertEqual((output / "testlog.txt").read_text(), "package test failed\n")
            self.assertEqual((output / "build.log").read_text(), "mock build log\n")
            with (output / "disk-usage.tsv").open() as samples:
                rows = list(csv.DictReader(samples, delimiter="\t"))
            self.assertGreaterEqual(len(rows), 3)
            self.assertTrue(all(int(row["size_kib"]) > 0 for row in rows))
            self.assertTrue(all(int(row["available_kib"]) >= 0 for row in rows))
            summary = (output / "disk-usage.txt").read_text()
            self.assertIn("sampled every 1 second", summary)
            self.assertIn(summary, result.stdout)
            measurements = dict(line.split("\t") for line in summary.splitlines()[1:])
            self.assertEqual(int(measurements["start_available"]), int(rows[0]["available_kib"]))
            self.assertEqual(int(measurements["minimum_available"]), min(int(row["available_kib"]) for row in rows))
            self.assertEqual(int(measurements["peak_used"]), max(int(row["used_kib"]) for row in rows))


if __name__ == "__main__":
    unittest.main()
