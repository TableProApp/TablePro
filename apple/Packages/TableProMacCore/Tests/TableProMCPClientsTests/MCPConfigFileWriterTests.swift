import Foundation
@testable import TableProMCPClients
import Testing

struct MCPConfigFileWriterTests {
    private let fileManager = FileManager.default
    private let writer = MCPConfigFileWriter()

    private func mode(_ url: URL) throws -> Int {
        try #require((try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test("A new file is created at 0600 with its folders, and the transform sees nil")
    func createsNewFile() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a/b/mcp.json")
        var seen: [String?] = []
        let result = try writer.update(url) { text in
            seen.append(text)
            return "{}\n"
        }
        #expect(seen == [nil])
        #expect(result == MCPConfigWriteResult(backupURL: nil, created: true))
        #expect(try contents(url) == "{}\n")
        #expect(try mode(url) == 0o600)
    }

    @Test("Replacing keeps the file's mode and leaves the old bytes in a sibling backup")
    func replacesWithBackup() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        try "old".write(to: url, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        var seen: [String?] = []
        let result = try writer.update(url) { text in
            seen.append(text)
            return "new"
        }
        #expect(seen == ["old"])
        #expect(!result.created)
        let backup = try #require(result.backupURL)
        #expect(backup.lastPathComponent == "mcp.json.tablepro-backup")
        #expect(try contents(url) == "new")
        #expect(try contents(backup) == "old")
        #expect(try mode(url) == 0o640)
        #expect(try fileManager.contentsOfDirectory(atPath: directory.path).sorted() == ["mcp.json", "mcp.json.tablepro-backup"])

        _ = try writer.update(url) { _ in "newer" }
        #expect(try contents(backup) == "new")
    }

    @Test("An unchanged result writes nothing")
    func unchangedSkipsWrite() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        try "same".write(to: url, atomically: false, encoding: .utf8)
        let result = try writer.update(url) { $0 ?? "" }
        #expect(result == MCPConfigWriteResult(backupURL: nil, created: false))
        #expect(try fileManager.contentsOfDirectory(atPath: directory.path) == ["mcp.json"])
    }

    @Test("Writing through a symlink replaces its target and keeps the link")
    func keepsSymlink() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let dotfiles = directory.appendingPathComponent("dotfiles", isDirectory: true)
        try fileManager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("settings.json")
        try "old".write(to: real, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = directory.appendingPathComponent("settings.json")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/settings.json")

        let result = try writer.update(link) { _ in "new" }
        #expect(try fileManager.destinationOfSymbolicLink(atPath: link.path) == "dotfiles/settings.json")
        #expect(try contents(real) == "new")
        #expect(try contents(link) == "new")
        #expect(try mode(real) == 0o600)
        let backup = try #require(result.backupURL)
        #expect(backup.deletingLastPathComponent().lastPathComponent == "dotfiles")
        #expect(try contents(dotfiles.appendingPathComponent("settings.json.tablepro-backup")) == "old")
    }

    @Test("A change made while the edit was computed is read again and the edit redone once")
    func redoesOnce() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        try "first".write(to: url, atomically: false, encoding: .utf8)

        var seen: [String?] = []
        _ = try writer.update(url) { text in
            seen.append(text)
            if seen.count == 1 {
                try "concurrent".write(to: url, atomically: false, encoding: .utf8)
            }
            return (text ?? "") + "+edit"
        }
        #expect(seen == ["first", "concurrent"])
        #expect(try contents(url) == "concurrent+edit")
    }

    @Test("A file that keeps changing is refused")
    func changingFileRefused() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        try "0".write(to: url, atomically: false, encoding: .utf8)
        var calls = 0
        #expect(throws: MCPConfigWriteError.changedDuringWrite) {
            try writer.update(url) { _ in
                calls += 1
                try String(calls).write(to: url, atomically: false, encoding: .utf8)
                return "edit"
            }
        }
        #expect(try contents(url) == "2")
    }

    @Test("A file that appears while a new one is prepared is redone against it")
    func appearsDuringCreate() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        var seen: [String?] = []
        let result = try writer.update(url) { text in
            seen.append(text)
            if text == nil {
                try "theirs".write(to: url, atomically: false, encoding: .utf8)
            }
            return (text ?? "") + "+ours"
        }
        #expect(seen == [nil, "theirs"])
        #expect(!result.created)
        #expect(try contents(url) == "theirs+ours")
    }

    @Test("A transform error leaves the file alone")
    func transformError() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        try "keep".write(to: url, atomically: false, encoding: .utf8)
        #expect(throws: MCPConfigEditError.duplicateKey(["mcpServers"])) {
            try writer.update(url) { _ in throw MCPConfigEditError.duplicateKey(["mcpServers"]) }
        }
        #expect(try contents(url) == "keep")
        #expect(try fileManager.contentsOfDirectory(atPath: directory.path) == ["mcp.json"])
    }

    @Test("Bytes that are not UTF-8 are refused")
    func notUTF8() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mcp.json")
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        #expect(throws: MCPConfigWriteError.io("notUTF8")) {
            try writer.update(url) { _ in "x" }
        }
    }

    @Test("Upserting through the writer keeps a JSONC file's comments")
    func endToEnd() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try "// Zed\n{\n  \"theme\": \"One Dark\"\n}\n".write(to: url, atomically: false, encoding: .utf8)
        _ = try writer.update(url) { text in
            try JSONCMemberEditor.upserting("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["context_servers"], in: text ?? "")
        }
        let written = try contents(url)
        #expect(written.hasPrefix("// Zed\n{\n  \"theme\": \"One Dark\",\n  \"context_servers\": {"))
        #expect(try JSONCMemberEditor.member("tablepro", at: ["context_servers"], in: written) == MCPClientsFixtures.stdioEntry)
    }

    @Test("A write the folder refuses carries the system's reason, not only its code")
    func refusedWriteNamesReason() throws {
        let directory = try MCPClientsFixtures.temporaryDirectory()
        let url = directory.appendingPathComponent("mcp.json")
        try "old".write(to: url, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }
        do {
            _ = try writer.update(url) { _ in "new" }
            Issue.record("The write went through a read-only folder")
        } catch MCPConfigWriteError.io(let detail) {
            #expect(detail.contains("(NSCocoaErrorDomain "))
            #expect(!detail.hasPrefix("NSCocoaErrorDomain"))
        }
        #expect(try contents(url) == "old")
    }
}
