import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("CommandLineToolInstaller")
struct CommandLineToolInstallerTests {
    private func makeDirectory() throws -> String {
        let path = NSTemporaryDirectory()
            .appending("CommandLineToolInstallerTests.\(UUID().uuidString)")
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
        #expect(contents.contains("open -b com.TablePro"))

        let attributes = try FileManager.default.attributesOfItem(atPath: installer.toolPath)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o755)
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
        let directory = try makeDirectory()
        let installer = CommandLineToolInstaller(directory: directory)
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

    @Test("A read-only directory reports as not writable, which is what /usr/local/bin does without sudo")
    func readOnlyDirectoryIsNotWritable() throws {
        let directory = try makeDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) }

        let installer = CommandLineToolInstaller(directory: directory)

        #expect(throws: CommandLineToolError.directoryNotWritable(directory)) {
            try installer.install()
        }
        #expect(installer.status == .notInstalled)
    }

    @Test("A missing directory reports as not writable instead of crashing")
    func missingDirectoryIsNotWritable() throws {
        let missing = NSTemporaryDirectory().appending("missing.\(UUID().uuidString)")
        let installer = CommandLineToolInstaller(directory: missing)

        #expect(throws: CommandLineToolError.directoryNotWritable(missing)) {
            try installer.install()
        }
    }

    @Test("The manual command installs the same shim the app would write")
    func manualCommandMatchesShim() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())
        let command = installer.manualInstallCommand

        #expect(command.contains("sudo"))
        #expect(command.contains(installer.toolPath))
        #expect(command.contains("open -b com.TablePro"))
    }

    @Test("Both manual commands quote the path they touch")
    func manualCommandsQuoteThePath() throws {
        let installer = CommandLineToolInstaller(directory: try makeDirectory())

        #expect(installer.manualInstallCommand.contains("\"\(installer.toolPath)\""))
        #expect(installer.manualUninstallCommand == "sudo rm \"\(installer.toolPath)\"")
    }

    @Test("Uninstalling a shim the app cannot remove fails loudly instead of silently")
    func uninstallFromReadOnlyDirectoryThrows() throws {
        let directory = try makeDirectory()
        let installer = CommandLineToolInstaller(directory: directory)
        try installer.install()

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) }

        #expect(throws: (any Error).self) {
            try installer.uninstall()
        }
        #expect(FileManager.default.fileExists(atPath: installer.toolPath))
    }
}
