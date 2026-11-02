//
//  CopilotBinaryManagerTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
import TableProProcess
import Testing

@testable import TablePro

struct CopilotBinaryManagerTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-binary-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Packs `binary` the way npm ships it, as `package/copilot-language-server` in a gzipped tar.
    private func makeTarball(containing binary: Data) throws -> Data {
        try makeTarball { server in try binary.write(to: server) }
    }

    private func makeTarball(placingServer place: (URL) throws -> Void) throws -> Data {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try place(package.appendingPathComponent("copilot-language-server"))

        let archive = root.appendingPathComponent("package.tgz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["czf", archive.path, "-C", root.path, "package"]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try Data(contentsOf: archive)
    }

    private func pins(tarball: Data, binary: Data) -> [String: CopilotBinaryDigests] {
        let digests = CopilotBinaryDigests(tarballSHA256: hash(tarball), binarySHA256: hash(binary))
        return ["darwin-arm64": digests, "darwin-x64": digests]
    }

    private func install(_ bytes: Data, version: String, into dir: URL) throws {
        let path = dir.appendingPathComponent("copilot-language-server")
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        try version.write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
    }

    @Test("Every architecture has a pinned version and both digests")
    func shippedPinsAreComplete() {
        #expect(!CopilotBinaryManager.pinnedVersion.isEmpty)
        for platform in ["darwin-arm64", "darwin-x64"] {
            let digests = CopilotBinaryManager.defaultPinnedDigests[platform]
            #expect(digests?.tarballSHA256.count == 64)
            #expect(digests?.binarySHA256.count == 64)
        }
    }

    @Test("The download URL names the pinned version, never a moving tag")
    func downloadURLIsPinned() throws {
        let url = try #require(CopilotBinaryManager.tarballURL).absoluteString
        #expect(url.hasSuffix("-\(CopilotBinaryManager.pinnedVersion).tgz"))
        #expect(!url.contains("latest"))
    }

    @Test("A tarball matching its pins installs the binary at the pinned version")
    func matchingPinsInstall() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = Data("copilot stand-in".utf8)
        let tarball = try makeTarball(containing: binary)
        let manager = CopilotBinaryManager(
            baseDirectory: dir,
            pinnedDigests: pins(tarball: tarball, binary: binary),
            fetch: { _ in tarball }
        )

        let path = try await manager.ensureBinary()

        #expect(FileManager.default.isExecutableFile(atPath: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == binary)
        #expect(await manager.installedVersion() == CopilotBinaryManager.pinnedVersion)
    }

    @Test("A tarball that does not match its pin is refused before extraction")
    func mismatchedTarballIsRefused() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = Data("copilot stand-in".utf8)
        let pinned = try makeTarball(containing: binary)
        let served = try makeTarball(containing: Data("something else".utf8))
        let manager = CopilotBinaryManager(
            baseDirectory: dir,
            pinnedDigests: pins(tarball: pinned, binary: binary),
            fetch: { _ in served }
        )

        await #expect(throws: CopilotError.self) {
            _ = try await manager.ensureBinary()
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("copilot-language-server").path))
    }

    @Test("tar takes only the server, named after the end of options, and nothing of the archive's owners or metadata")
    func extractCommandArguments() {
        let command = CopilotBinaryManager.extractCommand(
            archive: URL(fileURLWithPath: "/tmp/staging/download.tgz"),
            into: URL(fileURLWithPath: "/tmp/staging")
        )

        #expect(command.executable.path == "/usr/bin/tar")
        #expect(command.arguments == [
            "-x", "-z", "-f", "/tmp/staging/download.tgz", "-C", "/tmp/staging", "--strip-components=1",
            "--no-same-owner", "--no-xattrs", "--no-acls", "--no-fflags", "--no-mac-metadata",
            "--", "package/copilot-language-server"
        ])
        #expect(Set(command.environment.keys).isSubset(of: ProcessEnvironment.minimalNames))
    }

    @Test("A server that is a symlink in the tarball is refused, even when its target matches the pin")
    func symlinkedServerIsRefused() async throws {
        let dir = try makeTempDirectory()
        let outside = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }

        let binary = Data("copilot stand-in".utf8)
        let planted = outside.appendingPathComponent("planted")
        try binary.write(to: planted)
        let tarball = try makeTarball { server in
            try FileManager.default.createSymbolicLink(at: server, withDestinationURL: planted)
        }
        let manager = CopilotBinaryManager(
            baseDirectory: dir,
            pinnedDigests: pins(tarball: tarball, binary: binary),
            fetch: { _ in tarball }
        )

        await #expect(throws: CopilotError.self) {
            _ = try await manager.ensureBinary()
        }
        let installed = dir.appendingPathComponent("copilot-language-server").path
        #expect((try? FileManager.default.attributesOfItem(atPath: installed)) == nil)
    }

    @Test("A current install does not download again")
    func currentInstallShortCircuits() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = Data("already here".utf8)
        try install(binary, version: CopilotBinaryManager.pinnedVersion, into: dir)
        let fetched = FetchCounter()
        let manager = CopilotBinaryManager(
            baseDirectory: dir,
            pinnedDigests: pins(tarball: Data(), binary: binary),
            fetch: { _ in
                fetched.increment()
                return Data()
            }
        )

        _ = try await manager.ensureBinary()

        #expect(fetched.calls == 0)
    }

    @Test("An install from another version is replaced by the pinned one")
    func otherVersionIsReplaced() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try install(Data("older build".utf8), version: "1.0.0", into: dir)
        let binary = Data("pinned build".utf8)
        let tarball = try makeTarball(containing: binary)
        let manager = CopilotBinaryManager(
            baseDirectory: dir,
            pinnedDigests: pins(tarball: tarball, binary: binary),
            fetch: { _ in tarball }
        )

        #expect(!(await manager.installedBinaryIsCurrent()))
        let path = try await manager.ensureBinary()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == binary)
    }

    @Test("A binary altered after install is not current")
    func alteredBinaryIsNotCurrent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = Data("pinned build".utf8)
        try install(Data("swapped in later".utf8), version: CopilotBinaryManager.pinnedVersion, into: dir)
        let manager = CopilotBinaryManager(baseDirectory: dir, pinnedDigests: pins(tarball: Data(), binary: binary))

        #expect(!(await manager.installedBinaryIsCurrent()))
    }

    @Test("A missing binary is not current")
    func missingBinaryIsNotCurrent() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = CopilotBinaryManager(baseDirectory: dir)

        #expect(!(await manager.installedBinaryIsCurrent()))
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var calls: Int {
        lock.withLock { value }
    }
}
