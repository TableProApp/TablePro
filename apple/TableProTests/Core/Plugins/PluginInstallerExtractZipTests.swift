import Darwin
import Foundation
@testable import TablePro
import TableProProcess
import Testing

struct PluginInstallerExtractZipTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginInstallerExtractZipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("ditto gets the zip and the folder after the end of options, with a minimal environment")
    func extractZipCommandArguments() {
        let command = PluginInstaller.extractZipCommand(
            at: URL(fileURLWithPath: "/tmp/staging/Driver.zip"),
            into: URL(fileURLWithPath: "/tmp/staging")
        )

        #expect(command.executable.path == "/usr/bin/ditto")
        #expect(command.arguments == ["-x", "-k", "--noqtn", "--", "/tmp/staging/Driver.zip", "/tmp/staging"])
        #expect(Set(command.environment.keys).isSubset(of: ProcessEnvironment.minimalNames))
    }

    @Test("A quarantined zip extracts without passing quarantine to the plugin's files")
    func extractionLeavesQuarantineOnTheZip() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let contents = root.appendingPathComponent("source/Driver.tableplugin/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))

        let zip = root.appendingPathComponent("Driver.zip")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", contents.deletingLastPathComponent().path, zip.path]
        try pack.run()
        pack.waitUntilExit()
        try #require(pack.terminationStatus == 0)

        let quarantine = Array("0081;00000000;TableProTests;".utf8)
        try #require(setxattr(zip.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)

        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try PluginInstaller.extractZip(at: zip, into: destination)

        let extracted = destination.appendingPathComponent("Driver.tableplugin/Contents/Info.plist")
        #expect(FileManager.default.fileExists(atPath: extracted.path))
        #expect(getxattr(extracted.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    }
}
