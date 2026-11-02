#!/usr/bin/env python3
"""Fail when app, package or plugin code starts a child process outside ProcessLauncher.

`ProcessLauncher.process(for:)` (TableProProcess) is the one place outside PluginKit that makes a
`Process`: it refuses a NUL and a relative executable, refuses a shell for an app-authored command,
and makes every launch name its environment. Only the files in SHELL_CALLERS may build a command that
runs a shell, so a reviewer finds every place shell text is put together. Tests and probes may start
tools for their fixtures and are not scanned.

Usage:
    check-process-launches.py [path...]    # default: the production sources under apple/
"""

import re
import sys
from pathlib import Path

APPLE = Path(__file__).resolve().parents[2]

DEFAULT_PATHS = [
    APPLE / "TablePro",
    APPLE / "Plugins",
    APPLE / "Packages",
    APPLE / "TableProMobile",
]

LAUNCHER = "Packages/TableProCore/Sources/TableProProcess/ProcessLauncher.swift"

# TableProPluginKit is a framework, which cannot link a package product (PluginSQLQuoting.swift says
# why). Its one launch runs the credential_process the user put in ~/.aws/config.
EXCEPTIONS = {
    "Plugins/TableProPluginKit/AWS/AWSCredentialResolver.swift",
}

# The commands a user wrote: a password command, connect scripts, a custom tunnel command and the
# Match exec lines of ~/.ssh/config.
SHELL_CALLERS = {
    "TablePro/Core/Utilities/Connection/PasswordSourceResolver.swift",
    "TablePro/Core/Services/Infrastructure/ConnectionScriptRunner.swift",
    "TablePro/Core/TunnelCommand/TunnelCommandManager.swift",
    "Packages/TableProMacCore/Sources/TableProSSHConfig/SSHMatchExecutor.swift",
}

PROCESS = r"(?:Foundation\s*\.\s*)?Process"

FORBIDDEN = [
    (
        re.compile(r"\bProcess\s*(?:\(|\.\s*(?:self\s*\.\s*)?(?:init\b|run\s*\(|launchedProcess\b))"),
        "makes a Process",
    ),
    (re.compile(r":\s*" + PROCESS + r"\s*=\s*\.\s*init\b"), "makes a Process"),
    (
        re.compile(
            r"\b(?:class|struct)\s+\w+\s*:\s*" + PROCESS + r"\b|\bextension\s+" + PROCESS
            + r"\b|\btypealias\s+\w+\s*=\s*" + PROCESS + r"\b"
        ),
        "subclasses, extends or renames Process",
    ),
    (
        re.compile(r"\bNSTask\b|\bNSAppleScript\b|\bNSUser(?:Unix|AppleScript|Automator)?Task\b|\bOSAScript\b"),
        "makes a task or script",
    ),
    (re.compile(r"\bposix_spawnp?\s*\("), "calls posix_spawn"),
    (re.compile(r"\bpopen\s*\("), "calls popen"),
    (re.compile(r"\bexec(?:[lv]p?e?|vP)\s*\("), "calls exec"),
    (
        re.compile(r"\.\s*(?:executableURL|launchPath|currentDirectoryURL|currentDirectoryPath)\s*=(?!=)"),
        "sets a Process's executable or folder",
    ),
    (
        re.compile(
            r"\.\s*(?:environment|arguments)\s*(?:[?!](?!=)\s*)?(?:\[[^\]]*\]\s*)?"
            r"(?:=(?!=)|\+=|\.\s*(?:append|insert|merge|remove\w*|updateValue)\b)"
        ),
        "sets a Process's environment or arguments",
    ),
]

SHELL_COMMAND = re.compile(r"\.\s*(?:userAuthored|userShell)\s*\(|\bextension\s+ProcessCommand\b")

# A memberwise initializer storing its own parameter, which is not a Process.
MEMBERWISE = re.compile(r"^\s*self\.(environment|arguments)\s*=\s*\1\s*$")


def is_scanned(path, apple):
    relative = path.relative_to(apple).as_posix()
    parts = relative.split("/")
    if any(part.endswith("Tests") or part.endswith("TestSupport") for part in parts[:-1]):
        return False
    if parts[-1].endswith("Tests.swift"):
        return False
    if "/Libs/" in f"/{relative}" or "/.build/" in f"/{relative}" or relative.startswith("scripts/"):
        return False
    return True


def code_lines(source):
    """Yield (line number, text) with comments and string literal contents blanked."""
    in_block = 0
    in_multiline = False
    for number, line in enumerate(source.splitlines(), start=1):
        out = []
        i = 0
        in_string = False
        while i < len(line):
            if in_block:
                if line.startswith("*/", i):
                    in_block -= 1
                    i += 2
                elif line.startswith("/*", i):
                    in_block += 1
                    i += 2
                else:
                    i += 1
                continue
            if in_multiline:
                if line.startswith('"""', i):
                    in_multiline = False
                    out.append('"""')
                    i += 3
                else:
                    i += 1
                continue
            if in_string:
                if line[i] == "\\":
                    i += 2
                elif line[i] == '"':
                    in_string = False
                    out.append('"')
                    i += 1
                else:
                    i += 1
                continue
            if line.startswith("//", i):
                break
            if line.startswith("/*", i):
                in_block += 1
                i += 2
            elif line.startswith('"""', i):
                in_multiline = True
                out.append('"""')
                i += 3
            elif line[i] == '"':
                in_string = True
                out.append('"')
                i += 1
            else:
                out.append(line[i])
                i += 1
        yield number, "".join(out)


def violations(path, apple):
    relative = path.relative_to(apple).as_posix()
    if relative == LAUNCHER or relative in EXCEPTIONS:
        return []
    found = []
    for number, text in code_lines(path.read_text(encoding="utf-8")):
        if MEMBERWISE.match(text):
            continue
        for pattern, reason in FORBIDDEN:
            if pattern.search(text):
                found.append(f"{relative}:{number}: {reason} outside ProcessLauncher.process(for:)")
        if relative not in SHELL_CALLERS and SHELL_COMMAND.search(text):
            found.append(f"{relative}:{number}: builds a shell command outside the files that run what a user wrote")
    return found


def main(argv):
    roots = [Path(arg).resolve() for arg in argv] or DEFAULT_PATHS
    found = []
    seen = set()
    for root in roots:
        files = [root] if root.is_file() else sorted(root.rglob("*.swift"))
        # TableProCore links PluginKit's folder in as a symlink, so a file is judged by where it lives.
        for path in (file.resolve() for file in files):
            if path in seen or not is_scanned(path, APPLE):
                continue
            seen.add(path)
            found.extend(violations(path, APPLE))
    for line in found:
        print(line)
    if found:
        print(f"{len(found)} launch(es) outside the launcher. Build a ProcessCommand and call ProcessLauncher.process(for:).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
