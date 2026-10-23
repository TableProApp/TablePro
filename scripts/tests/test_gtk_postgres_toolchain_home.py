import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


class GtkPostgresToolchainHomeTests(unittest.TestCase):
    def _homes_seen_by_the_session(self, extra_env: dict[str, str]) -> dict[str, str]:
        with tempfile.TemporaryDirectory(prefix="bookie-toolchain-home-") as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            session = bin_dir / "dbus-run-session"
            session.write_text('#!/bin/sh\nprintf "%s\\n%s\\n%s\\n" "$HOME" "$CARGO_HOME" "$RUSTUP_HOME"\n')
            session.chmod(session.stat().st_mode | stat.S_IEXEC)
            home = root / "home"
            home.mkdir()
            env = {
                key: value
                for key, value in os.environ.items()
                if key not in {"CARGO_HOME", "RUSTUP_HOME", "TABLEPRO_GTK_POSTGRES_DBUS_ACTIVE"}
            }
            env.update({"PATH": f"{bin_dir}:{env['PATH']}", "HOME": str(home), "TMPDIR": str(root), **extra_env})
            result = subprocess.run(
                ["bash", str(SOURCE / "scripts/test-gtk-postgres.sh")],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
                check=True,
            )
            session_home, cargo_home, rustup_home = result.stdout.splitlines()
            return {"home": session_home, "cargo": cargo_home, "rustup": rustup_home, "real_home": str(home)}

    def test_the_isolated_session_keeps_the_callers_toolchain_and_crate_cache(self) -> None:
        seen = self._homes_seen_by_the_session({})
        self.assertNotEqual(seen["home"], seen["real_home"])
        self.assertEqual(seen["cargo"], f"{seen['real_home']}/.cargo")
        self.assertEqual(seen["rustup"], f"{seen['real_home']}/.rustup")

    def test_explicit_toolchain_homes_are_kept(self) -> None:
        seen = self._homes_seen_by_the_session({"CARGO_HOME": "/opt/cargo", "RUSTUP_HOME": "/opt/rustup"})
        self.assertEqual(seen["cargo"], "/opt/cargo")
        self.assertEqual(seen["rustup"], "/opt/rustup")


if __name__ == "__main__":
    unittest.main()
