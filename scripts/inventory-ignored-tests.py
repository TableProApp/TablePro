#!/usr/bin/env python3
"""Print the ignored-test ledger from Rust declarations; no files are modified."""
from pathlib import Path
import re
import json
import io
import sys
import tomllib
from collections import Counter

root = Path(__file__).resolve().parents[1]
registry = json.loads((root / "scripts/isolated-tests.json").read_text())
POSTGRES_RELEASE_RUNNER = "scripts/test-postgres-release.sh"


def workspace_packages():
    manifest = tomllib.loads((root / "Cargo.toml").read_text())
    packages = {}
    for member in manifest["workspace"]["members"]:
        crate_dir = (root / member).resolve()
        name = tomllib.loads((crate_dir / "Cargo.toml").read_text())["package"]["name"]
        packages[crate_dir] = name
    return packages


def package_owning(path, packages):
    current = path.resolve().parent
    while current != current.parent:
        name = packages.get(current)
        if name:
            return name
        if current == root:
            break
        current = current.parent
    raise RuntimeError(f"no workspace package owns {path}")


def docker_activation(path, name, packages):
    package = package_owning(path, packages)
    relative = path.relative_to(root)
    if package == "tablepro-app" and relative.parts[-3:-1] == ("tests", "support"):
        # Included through #[path] from a cfg(test) app module, rather than a
        # Cargo integration-test crate. Keep its activation command on --lib.
        selector = f"--lib {name}"
    elif relative.parts[-2].endswith("_parts"):
        module = relative.parts[-2][:-6]
        tests_dir = path.parents[2]
        integration = tests_dir / "integration.rs"
        if not integration.is_file() or f"mod {module};" not in integration.read_text():
            raise RuntimeError(f"included Docker test source has no integration module: {relative}")
        selector = "--test integration"
    elif relative.parts[-2] == "tests":
        selector = f"--test {path.stem}"
    elif "src" in relative.parts:
        selector = f"--lib {name}"
    else:
        tests_dir = path.parent
        while tests_dir.name != "tests":
            tests_dir = tests_dir.parent
            if tests_dir == root:
                raise RuntimeError(f"docker ignored test is outside src and tests: {relative}")
        integration = tests_dir / "integration.rs"
        if not integration.is_file() or f"mod {path.stem};" not in integration.read_text():
            raise RuntimeError(f"docker ignored test is not an integration module: {relative}")
        selector = "--test integration"
    return (
        f"Docker plus cargo test -p {package} {selector} "
        "-- --include-ignored --test-threads=1"
    )


packages = workspace_packages()
mapped = {entry[2].split("::")[-1] for entries in registry.values() for entry in entries}
output = io.StringIO()
original_stdout = sys.stdout
sys.stdout = output
rows = []
for path in sorted((root / "crates").rglob("*.rs")):
    source = path.read_text()
    for match in re.finditer(r'#\[ignore(?:\s*=\s*"([^"\n]*)")?\]', source):
        function = re.search(r'\b(?:async\s+)?fn\s+(\w+)', source[match.end():])
        if not function:
            raise RuntimeError(f"ignore without function: {path}")
        name = function.group(1)
        reason = match.group(1) or "subprocess helper; invoked by its parent test"
        relative = path.relative_to(root).as_posix()
        if "subprocess" in name or not match.group(1):
            tier, enable = "Helper", "Run parent unit/sandbox test; do not enable globally"
        elif "mssql_kerberos.rs" in relative:
            tier, enable = "MSSQL Kerberos", "scripts/test-mssql-kerberos.sh"
        elif "driver-tls-tests" in relative:
            tier, enable = "TLS", "scripts/test-driver-tls.sh"
        elif "release-tests" in relative:
            tier, enable = "Release", POSTGRES_RELEASE_RUNNER
        elif "postgres release fixture" in reason.lower():
            tier, enable = "Release", POSTGRES_RELEASE_RUNNER
        elif relative == "crates/agentd/tests/mtls.rs":
            tier, enable = "Release", POSTGRES_RELEASE_RUNNER
        elif "socket" in relative:
            tier, enable = "Socket", "scripts/test-postgres-socket.sh"
        elif "smoke_local" in relative:
            tier, enable = "Smoke", "scripts/smoke-postgres.sh against disposable DB"
        elif "Secret Service" in reason or "secret" in relative:
            if name not in mapped:
                raise RuntimeError(f"unmapped keyring test: {name}")
            tier, enable = "Keyring", "scripts/test-secret-service.sh in isolated session"
        elif "isolated GTK display" in reason:
            if name not in mapped:
                raise RuntimeError(f"unmapped GTK test: {name}")
            tier, enable = "GTK", "scripts/test-gtk-widgets.sh"
        elif "docker" in reason.lower() and relative.startswith("crates/ssh/"):
            targets = re.findall(r"--test\s+([\w-]+)", (root / "scripts/test-ssh.sh").read_text())
            if path.stem not in targets:
                raise RuntimeError(f"unmapped Docker SSH target: {path.stem}")
            tier, enable = "Driver", "bash scripts/test-ssh.sh (CI integration)"
        elif "docker" in reason.lower() and relative.startswith("crates/app/"):
            if name not in mapped:
                raise RuntimeError(f"unowned app Docker contract: {name}")
            tier, enable = "App server", "scripts/run-test-layer.py app-server"
        elif "docker" in reason.lower():
            tier, enable = "Driver", docker_activation(path, name, packages)
        else:
            raise RuntimeError(f"unmapped ignored test: {relative}: {name}")
        rows.append((relative, name, tier, reason, enable))
print("# Ignored-test inventory\n")
print("Generated by `python3 scripts/inventory-ignored-tests.py` from the working tree.\n")
print("These attributes select an execution environment; helper attributes are not missing coverage. Keep fixture tests ignored in the ordinary unit tier. Enable them through their runner once its prerequisites exist.\n")
print(f"Total: {len(rows)} declarations. " + "; ".join(f"{k}: {v}" for k, v in sorted(Counter(r[2] for r in rows).items())) + ".\n")
print("| Test | Tier | Reason | Activation condition / runner |\n|---|---|---|---|")
for path, name, tier, reason, enable in rows:
    print(f"| [{name}](../{path}) | {tier} | {reason} | `{enable}` |")
sys.stdout = original_stdout
for name in mapped:
    if not any(row[1] == name for row in rows):
        raise RuntimeError(f"stale isolated-test registration: {name}")
if "--check" in sys.argv:
    if (root / "docs/ignored-tests.md").read_text() != output.getvalue():
        raise SystemExit("ignored-test inventory stale: regenerate scripts/inventory-ignored-tests.py")
    print("ignored-test inventory and isolated registrations: OK")
else:
    print(output.getvalue(), end="")
