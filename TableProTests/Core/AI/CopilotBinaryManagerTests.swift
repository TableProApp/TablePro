//
//  CopilotBinaryManagerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Copilot binary manager")
struct CopilotBinaryManagerTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-binary-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func installBinary(_ bytes: Data, into dir: URL) throws -> URL {
        let path = dir.appendingPathComponent("copilot-language-server")
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func recordDigestOfInstalledBinary(in dir: URL) throws {
        let binaryPath = dir.appendingPathComponent("copilot-language-server").path
        let digest = try #require(DownloadedBinary.sha256Hex(ofFileAt: binaryPath))
        try digest.write(to: dir.appendingPathComponent("sha256.txt"), atomically: true, encoding: .utf8)
    }

    @Test("A binary matching its recorded digest is intact")
    func matchingDigestIsIntact() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data("copilot stand-in".utf8)
        _ = try installBinary(bytes, into: dir)
        try recordDigestOfInstalledBinary(in: dir)

        let manager = CopilotBinaryManager(baseDirectory: dir)

        #expect(await manager.installedBinaryIsIntact())
    }

    @Test("A binary with no recorded digest is not intact")
    func missingDigestIsNotIntact() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try installBinary(Data("copilot stand-in".utf8), into: dir)

        let manager = CopilotBinaryManager(baseDirectory: dir)

        #expect(!(await manager.installedBinaryIsIntact()))
    }

    @Test("A binary altered after install is not intact")
    func alteredBinaryIsNotIntact() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data("copilot stand-in".utf8)
        let path = try installBinary(bytes, into: dir)
        try recordDigestOfInstalledBinary(in: dir)

        try Data("swapped in later".utf8).write(to: path)

        let manager = CopilotBinaryManager(baseDirectory: dir)

        #expect(!(await manager.installedBinaryIsIntact()))
    }

    @Test("A missing binary is not intact")
    func missingBinaryIsNotIntact() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = CopilotBinaryManager(baseDirectory: dir)

        #expect(!(await manager.installedBinaryIsIntact()))
    }
}
