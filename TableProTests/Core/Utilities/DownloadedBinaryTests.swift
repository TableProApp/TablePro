//
//  DownloadedBinaryTests.swift
//  TableProTests
//

import CryptoKit
import Darwin
import Foundation
import Testing

@testable import TablePro

@Suite("Downloaded binary")
struct DownloadedBinaryTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloaded-binary-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reference(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("The digest matches CryptoKit over the whole file")
    func digestMatchesReference() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("payload")
        let bytes = Data("cloud-sql-proxy stand-in".utf8)
        try bytes.write(to: file)

        #expect(DownloadedBinary.sha256Hex(ofFileAt: file.path) == reference(bytes))
    }

    @Test("A file larger than one read chunk hashes correctly")
    func digestSpansChunks() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("large")
        var bytes = Data(count: 3 * (1 << 20) + 17)
        for index in stride(from: 0, to: bytes.count, by: 4_093) {
            bytes[index] = UInt8(index % 251)
        }
        try bytes.write(to: file)

        #expect(DownloadedBinary.sha256Hex(ofFileAt: file.path) == reference(bytes))
    }

    @Test("An empty file hashes to the empty digest rather than returning nil")
    func digestOfEmptyFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("empty")
        try Data().write(to: file)

        #expect(DownloadedBinary.sha256Hex(ofFileAt: file.path) == reference(Data()))
    }

    @Test("A missing file has no digest")
    func digestOfMissingFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(DownloadedBinary.sha256Hex(ofFileAt: dir.appendingPathComponent("absent").path) == nil)
    }

    @Test("Changing one byte changes the digest")
    func digestDetectsAlteration() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("payload")
        try Data("original".utf8).write(to: file)
        let before = DownloadedBinary.sha256Hex(ofFileAt: file.path)

        try Data("originaL".utf8).write(to: file)
        let after = DownloadedBinary.sha256Hex(ofFileAt: file.path)

        #expect(before != after)
    }

    @Test("Stripping quarantine twice does not raise")
    func stripQuarantineIsIdempotent() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("payload")
        try Data("payload".utf8).write(to: file)

        DownloadedBinary.stripQuarantine(at: file)
        DownloadedBinary.stripQuarantine(at: file)

        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// `ditto -xk` flags every extracted file, so clearing the bundle root alone leaves the
    /// executable inside `Contents/MacOS` quarantined and Gatekeeper refuses to load it.
    @Test("Stripping quarantine reaches every file inside a bundle, not just its root")
    func stripQuarantineIsRecursive() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = dir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent("Driver")
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        try Data("binary".utf8).write(to: executable)
        try Data("plist".utf8).write(to: plist)

        let quarantined = [bundle, bundle.appendingPathComponent("Contents"), macOS, executable, plist]
        for url in quarantined {
            try setQuarantine(at: url)
            #expect(hasQuarantine(at: url), "the fixture failed to set the xattr on \(url.lastPathComponent)")
        }

        DownloadedBinary.stripQuarantine(at: bundle)

        for url in quarantined {
            #expect(!hasQuarantine(at: url), "\(url.lastPathComponent) is still quarantined")
        }
    }

    private func setQuarantine(at url: URL) throws {
        let value = "0083;00000000;TableProTests;"
        let result = value.withCString { bytes in
            url.path.withCString { path in
                setxattr(path, "com.apple.quarantine", bytes, strlen(bytes), 0, XATTR_NOFOLLOW)
            }
        }
        #expect(result == 0, "setxattr failed with errno \(errno)")
    }

    private func hasQuarantine(at url: URL) -> Bool {
        url.path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) } >= 0
    }
}
