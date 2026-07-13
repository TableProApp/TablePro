import Foundation
@testable import TablePro
import Testing

@MainActor
private final class ExecutingShell: PrivilegedShellRunning {
    private(set) var commands: [String] = []

    func run(_ command: String) throws {
        commands.append(command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PrivilegedShellError.failed("exit \(process.terminationStatus)")
        }
    }
}

@MainActor
private final class CancellingShell: PrivilegedShellRunning {
    private(set) var callCount = 0

    func run(_ command: String) throws {
        callCount += 1
        throw PrivilegedShellError.cancelled
    }
}

@MainActor
@Suite("CommandLineToolInstaller")
struct CommandLineToolInstallerTests {
    private func makeDirectory(named name: String = UUID().uuidString) throws -> String {
        let path = NSTemporaryDirectory().appending("CommandLineToolInstallerTests.\(name)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("Reports not installed on a clean directory")
    func notInstalledByDefault() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())
        #expect(installer.status == .notInstalled)
    }

    @Test("Install writes an executable shim that opens TablePro by bundle id")
    func installWritesExecutableShim() throws {
        let directory = try makeDirectory()
        let installer = CommandLineToolInstaller(directory: directory)

        try installer.install()

        #expect(installer.status == .installed)
        let contents = try String(contentsOfFile: installer.toolPath, encoding: .utf8)
        #expect(contents.contains("exec open -b com.TablePro"))

        let attributes = try FileManager.default.attributesOfItem(atPath: installer.toolPath)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o755)
    }

    @Test("A writable directory never asks for an administrator password")
    func writableDirectoryDoesNotEscalate() throws {
        let shell = CancellingShell()
        let installer = CommandLineToolInstaller(directory: try makeDirectory(), privilegedShell: shell)

        try installer.install()

        #expect(installer.status == .installed)
        #expect(shell.callCount == 0)
    }

    @Test("Uninstall removes the shim")
    func uninstallRemovesShim() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())
        try installer.install()

        try installer.uninstall()

        #expect(installer.status == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: installer.toolPath) == false)
    }

    @Test("Uninstalling when nothing is installed is a no-op")
    func uninstallWithoutInstallIsNoOp() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())
        try installer.uninstall()
        #expect(installer.status == .notInstalled)
    }

    @Test("A foreign file at the same path is reported as a conflict and never overwritten")
    func foreignFileConflicts() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())
        try "#!/bin/sh\necho not ours\n".write(toFile: installer.toolPath, atomically: true, encoding: .utf8)

        #expect(installer.status == .conflict)
        #expect(throws: CommandLineToolError.conflict(installer.toolPath)) {
            try installer.install()
        }

        let contents = try String(contentsOfFile: installer.toolPath, encoding: .utf8)
        #expect(contents.contains("not ours"))
    }

    @Test("A foreign file is never removed by uninstall")
    func foreignFileSurvivesUninstall() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())
        try "echo not ours\n".write(toFile: installer.toolPath, atomically: true, encoding: .utf8)

        #expect(throws: CommandLineToolError.conflict(installer.toolPath)) {
            try installer.uninstall()
        }
        #expect(FileManager.default.fileExists(atPath: installer.toolPath))
    }

    @Test("A missing directory escalates to an administrator prompt")
    func missingDirectoryEscalates() throws {
        let missing = NSTemporaryDirectory().appending("missing.\(UUID().uuidString)/bin")
        let shell = ExecutingShell()
        let installer = CommandLineToolInstaller(directory: missing, privilegedShell: shell)

        try installer.install()

        #expect(shell.commands.count == 1)
        #expect(installer.status == .installed)
    }

    @Test("Cancelling the password prompt cancels the install and writes nothing")
    func cancellingThePromptCancelsInstall() throws {
        let missing = NSTemporaryDirectory().appending("missing.\(UUID().uuidString)/bin")
        let shell = CancellingShell()
        let installer = CommandLineToolInstaller(directory: missing, privilegedShell: shell)

        #expect(throws: CommandLineToolError.cancelled) {
            try installer.install()
        }
        #expect(shell.callCount == 1)
        #expect(installer.status == .notInstalled)
    }

    @Test("The privileged install command builds a working shim, even in a path with spaces and quotes")
    func privilegedCommandSurvivesHostileDirectoryNames() throws {
        let directory = try makeDirectory(named: "we ird's dir")
        let installer = CommandLineToolInstaller(directory: directory)
        let shell = ExecutingShell()

        try shell.run(installer.installCommand)

        #expect(installer.status == .installed)
        let contents = try String(contentsOfFile: installer.toolPath, encoding: .utf8)
        #expect(contents.hasPrefix("#!/bin/sh\n"))
        #expect(contents.contains("exec open -b com.TablePro \"$@\""))

        try shell.run(installer.uninstallCommand)
        #expect(installer.status == .notInstalled)
    }

    @Test("A directory name cannot inject a second command into the privileged shell")
    func directoryNameCannotInjectCommands() throws {
        let canary = NSTemporaryDirectory().appending("canary.\(UUID().uuidString)")
        let hostile = try makeDirectory(named: "x'; touch \(canary); echo '")
        let installer = CommandLineToolInstaller(directory: hostile)
        let shell = ExecutingShell()

        try shell.run(installer.installCommand)

        #expect(FileManager.default.fileExists(atPath: canary) == false)
        #expect(installer.status == .installed)
    }

    @Test("The AppleScript wrapper escapes quotes and backslashes")
    func appleScriptEscaping() {
        let script = OSAScriptPrivilegedShell.appleScript(for: #"printf 'a"b\c' > 'x'"#)

        #expect(script.hasPrefix("do shell script \""))
        #expect(script.hasSuffix("\" with administrator privileges"))
        #expect(script.contains(#"a\"b\\c"#))
    }

    @Test("Both manual commands run the same thing the app would run")
    func manualCommandsMirrorTheAppCommands() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())

        #expect(installer.manualInstallCommand.hasPrefix("sudo sh -c "))
        #expect(installer.manualInstallCommand.contains("open -b com.TablePro"))
        #expect(installer.manualUninstallCommand.hasPrefix("sudo sh -c "))
        #expect(installer.manualUninstallCommand.contains(installer.toolPath))
    }
}
