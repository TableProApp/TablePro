import os
from pathlib import Path
import shutil
import subprocess
import sys

source, profile, kerberos, gui, agent, askpass = sys.argv[1:]
arguments = ["cargo", "build", "--manifest-path", str(Path(source) / "Cargo.toml"),
             "--locked", "-p", "tablepro-app", "-p", "tablepro-agentd", "-p", "tablepro-ssh", "--bin", "tablepro-app",
             "--bin", "tablepro-agentd", "--bin", "tablepro-askpass"]
if profile == "default":
    arguments.append("--release")
if kerberos == "false":
    arguments.append("--no-default-features")
subprocess.run(arguments, cwd=source, check=True)
built = Path(os.environ["CARGO_TARGET_DIR"]) / ("release" if profile == "default" else "debug")
shutil.copy2(built / "tablepro-app", gui)
shutil.copy2(built / "tablepro-agentd", agent)
shutil.copy2(built / "tablepro-askpass", askpass)
