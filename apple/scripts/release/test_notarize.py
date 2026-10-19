#!/usr/bin/env python3

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "notarize.sh"

STUBS = {
    "xcrun": r"""#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
    "notarytool submit") echo '{"status":"Accepted","id":"stub-id","message":"Processing complete"}' ;;
    "notarytool log") echo '{}' ;;
    "stapler staple")
        name="$(basename "$3")"
        echo "staple $name" >> "$STUB_STATE/calls"
        codes="$STUB_STATE/staple-$name"
        [ -s "$codes" ] || exit 0
        code="$(head -n 1 "$codes")"
        tail -n +2 "$codes" > "$codes.rest"
        mv "$codes.rest" "$codes"
        exit "$code"
        ;;
    *) echo "stub xcrun: unexpected $*" >&2; exit 99 ;;
esac
""",
    "plutil": r"""#!/usr/bin/env bash
set -euo pipefail
sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$6"
""",
    "ditto": r"""#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "-c" ]; then
    for last; do :; done
    : > "$last"
else
    cp -R "$1" "$2"
fi
""",
    "spctl": """#!/usr/bin/env bash
echo "source=Notarized Developer ID"
""",
    "sleep": """#!/usr/bin/env bash
echo "sleep $1" >> "$STUB_STATE/calls"
""",
}


class StapleTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin = self.root / "bin"
        self.state = self.root / "state"
        self.bin.mkdir()
        self.state.mkdir()
        for name, body in STUBS.items():
            stub = self.bin / name
            stub.write_text(body, encoding="utf-8")
            stub.chmod(0o755)

    def bundle(self, name, staple_exits=()):
        path = self.root / name
        path.mkdir()
        (self.state / f"staple-{name}").write_text("".join(f"{code}\n" for code in staple_exits), encoding="utf-8")
        return path

    def notarize(self, *paths):
        env = {**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}", "STUB_STATE": str(self.state)}
        return subprocess.run(["bash", str(SCRIPT), *map(str, paths)], env=env, capture_output=True, text=True)

    def calls(self):
        calls = self.state / "calls"
        return calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []

    def test_a_late_ticket_is_stapled_on_a_retry(self):
        late = self.bundle("Late.tableplugin", [65, 68])
        ready = self.bundle("Ready.tableplugin")
        result = self.notarize(late, ready)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [
            "staple Late.tableplugin", "sleep 30",
            "staple Late.tableplugin", "sleep 60",
            "staple Late.tableplugin",
            "staple Ready.tableplugin",
        ])
        self.assertEqual(result.stdout.count("Stapling Late.tableplugin: no ticket yet"), 2)
        self.assertIn("Ready.tableplugin: notarized, stapled and accepted by Gatekeeper", result.stdout)

    def test_a_ticket_missing_after_three_attempts_fails(self):
        missing = self.bundle("Missing.tableplugin", [65, 65, 65])
        result = self.notarize(missing)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), [
            "staple Missing.tableplugin", "sleep 30",
            "staple Missing.tableplugin", "sleep 60",
            "staple Missing.tableplugin",
        ])
        self.assertIn("stapling Missing.tableplugin failed after 3 attempts (stapler exit 65)", result.stderr)

    def test_any_other_stapler_failure_is_final(self):
        unsigned = self.bundle("Unsigned.tableplugin", [66])
        result = self.notarize(unsigned)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.calls(), ["staple Unsigned.tableplugin"])
        self.assertIn("stapling Unsigned.tableplugin failed (stapler exit 66)", result.stderr)


if __name__ == "__main__":
    unittest.main()
