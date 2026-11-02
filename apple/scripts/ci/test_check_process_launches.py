#!/usr/bin/env python3
"""Fixture tests for check-process-launches.py."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_process_launches", Path(__file__).with_name("check-process-launches.py")
)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

# The Match exec runner as it shipped in 0.83.0.
REPORTED = '''enum SSHMatchExecutor {
    static func evaluate(command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
        return true
    }
}
'''

THROUGH_LAUNCHER = '''import TableProProcess

enum GzipRunner {
    static func run(path: String) throws -> Bool {
        let command = ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c", path], environment: [:])
        let process = try ProcessLauncher.process(for: command)
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        return true
    }
}
'''

REWIRED_AFTER_LAUNCH = '''func run() throws {
    let process = try ProcessLauncher.process(for: command)
    process.environment = nil
    process.launchPath = "/bin/sh"
    try process.run()
}
'''

NOT_A_LAUNCH = '''struct AgentCLILaunch {
    let environment: [String: String]
    init(environment: [String: String]) {
        self.environment = environment
    }
    // A Process() made here would skip the launcher.
    static let note = "Process(\\"x\\") in a string is not code"
    static func isGrantedToCurrentProcess() -> Bool { AgentCLIProcess(label: "x") != nil }
}
'''

BYPASS_FORMS = [
    'try Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", cmd])',
    'let p = Process.launchedProcess(launchPath: "/bin/sh", arguments: [])',
    "let p: Process = .init()",
    "final class Runner: Process {}",
    "typealias Child = Foundation.Process",
    "self.process.environment = nil",
    "runner.process.arguments = []",
    "process?.arguments = []",
    'process.environment?["DYLD_INSERT_LIBRARIES"] = lib',
    "process.arguments?.append(x)",
    "let script = NSAppleScript(source: text)",
    "let task = try NSUserUnixTask(url: url)",
]

SHELL_OUTSIDE_OWNERS = """let process = try ProcessLauncher.process(for: .userShell("tool \\(value)", shell: .sh, environment: [:]))
"""

MEMBERWISE_INIT = """struct Launch {
    let environment: [String: String]
    init(environment: [String: String]) {
        self.environment = environment
    }
}
"""

OTHER_LAUNCHES = '''let task = NSTask()
posix_spawn(&pid, path, nil, nil, argv, envp)
let handle = popen("ls", "r")
let child = Foundation.Process.init()
'''


class CheckProcessLaunchesTests(unittest.TestCase):
    def scan(self, source, relative="TablePro/Core/Example.swift"):
        with tempfile.TemporaryDirectory() as folder:
            apple = Path(folder)
            path = apple / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source, encoding="utf-8")
            return check.violations(path, apple)

    def test_reported_runner_fails(self):
        found = self.scan(REPORTED)
        self.assertEqual(len(found), 3)
        self.assertIn("TablePro/Core/Example.swift:3: makes a Process", found[0])

    def test_launch_through_the_launcher_passes(self):
        self.assertEqual(self.scan(THROUGH_LAUNCHER), [])

    def test_rewiring_a_launched_process_fails(self):
        self.assertEqual(len(self.scan(REWIRED_AFTER_LAUNCH)), 2)

    def test_names_comments_and_strings_pass(self):
        self.assertEqual(self.scan(NOT_A_LAUNCH), [])

    def test_other_launch_calls_fail(self):
        self.assertEqual(len(self.scan(OTHER_LAUNCHES)), 4)

    def test_each_bypass_form_fails(self):
        for form in BYPASS_FORMS:
            with self.subTest(form=form):
                self.assertEqual(len(self.scan(form + "\n")), 1)

    def test_shell_commands_only_in_their_owners(self):
        self.assertEqual(len(self.scan(SHELL_OUTSIDE_OWNERS)), 1)
        owner = next(iter(check.SHELL_CALLERS))
        self.assertEqual(self.scan(SHELL_OUTSIDE_OWNERS, owner), [])

    def test_extending_process_command_fails(self):
        self.assertEqual(len(self.scan("extension ProcessCommand {\n}\n")), 1)

    def test_memberwise_init_passes(self):
        self.assertEqual(self.scan(MEMBERWISE_INIT), [])

    def test_launcher_and_listed_exception_are_allowed(self):
        self.assertEqual(self.scan(REPORTED, check.LAUNCHER), [])
        self.assertEqual(self.scan(REPORTED, next(iter(check.EXCEPTIONS))), [])

    def test_tests_and_probes_are_not_scanned(self):
        apple = Path("/repo/apple")
        self.assertFalse(check.is_scanned(apple / "TableProTests/Core/X.swift", apple))
        self.assertFalse(check.is_scanned(apple / "Packages/TableProCore/Tests/TableProProcessTests/X.swift", apple))
        self.assertFalse(check.is_scanned(apple / "Plugins/FormatPluginTests/X.swift", apple))
        self.assertFalse(check.is_scanned(apple / "scripts/probes/x/main.swift", apple))
        self.assertFalse(check.is_scanned(apple / "Packages/TableProCore/.build/checkouts/x/Sources/X.swift", apple))
        self.assertTrue(check.is_scanned(apple / "Plugins/SQLExportPlugin/SQLExportCompressor.swift", apple))


if __name__ == "__main__":
    unittest.main()
