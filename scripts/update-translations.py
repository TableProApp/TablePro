#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
files = sorted(path for path in (root / "crates/app/src").rglob("*.rs") if "tr!" in path.read_text())
with tempfile.TemporaryDirectory(prefix="bookie-gettext-") as temporary:
    stage = Path(temporary)
    for path in files:
        target = stage / path.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(path.read_text().replace("crate::tr!", "tr!"))
    subprocess.run([
        "xgettext", "--language=Rust", "--keyword=tr!", "--keyword=tr", "--from-code=UTF-8",
        "--package-name=BookiE", "--package-version=0.1.6-dev",
        "--copyright-holder=BookiE contributors and TablePro Authors",
        "--msgid-bugs-address=https://github.com/cozyGarage/TablePro/issues",
        "--output=" + str(root / "po/tablepro.pot"),
        *[str(path.relative_to(root)) for path in files],
    ], cwd=stage, check=True)
(root / "po/POTFILES.in").write_text("\n".join(str(path.relative_to(root)) for path in files) + "\n")
