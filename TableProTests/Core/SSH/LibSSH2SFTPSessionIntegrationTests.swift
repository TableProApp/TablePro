//
//  LibSSH2SFTPSessionIntegrationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Exercises the SFTP transport against a real OpenSSH server.
///
/// These do not have a unit-test equivalent. Both defects they guard are properties of the wire
/// protocol and of libssh2's own buffering, so a fake that answers the way the API reads would pass
/// every one of them while the shipped code corrupted a database.
///
/// Start the server with `scripts/sftp-test-server.sh up`. Without it every case skips.
///
/// Serialized because every case authenticates against the one server. Run in parallel they arrive
/// as a dozen simultaneous handshakes, sshd's `MaxStartups` drops the overflow, and whichever case
/// lost the race fails in a fraction of a second with a connection error that reads nothing like
/// its subject.
@Suite(
    "SFTP transport against a real server",
    .serialized,
    .enabled(if: SFTPTestServer.isConfigured)
)
struct LibSSH2SFTPSessionIntegrationTests {
    private func withSession<T>(
        _ label: String,
        _ body: (LibSSH2SFTPSession) throws -> T
    ) async throws -> T {
        let session = try await SFTPTestServer.openSession(label: label)
        defer { session.close() }
        return try body(session)
    }

    @Test("A download is byte-exact across a size that forces hundreds of short reads")
    func downloadIsByteExact() async throws {
        let remotePath = SFTPTestServer.scratchPath("download.db")
        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-down-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        try await withSession("download") { session in
            defer { session.remove(remotePath) }
            let expected = try SFTPTestServer.seedRemoteFile(
                session: session, at: remotePath, bytes: 4 * 1_024 * 1_024
            )

            let downloaded = try session.download(remotePath: remotePath, to: downloadURL)
            #expect(downloaded.bytes == 4 * 1_024 * 1_024)
            #expect(downloaded.sha256 == expected)
        }
    }

    @Test("A path with a space and non-ASCII characters is read back correctly")
    func awkwardPathsRead() async throws {
        let remotePath = "\(SFTPTestServer.homeDirectory)/tablepro test \(UUID().uuidString) é 数据.db"
        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-odd-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        try await withSession("awkward") { session in
            defer { session.remove(remotePath) }
            let expected = try SFTPTestServer.seedRemoteFile(
                session: session, at: remotePath, bytes: 2_048
            )
            let downloaded = try session.download(remotePath: remotePath, to: downloadURL)
            #expect(downloaded.sha256 == expected)
        }
    }

    @Test("A missing path reports that it is missing, not a generic failure")
    func missingPathIsNamed() async throws {
        try await withSession("missing") { session in
            let path = SFTPTestServer.scratchPath("definitely-absent.db")
            #expect(!session.exists(path))
            #expect(throws: SFTPError.noSuchFile(path: path)) {
                try session.stat(path)
            }
        }
    }

    @Test("A directory is refused rather than downloaded")
    func directoryIsRefused() async throws {
        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-dir-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        try await withSession("directory") { session in
            #expect(throws: SFTPError.notAFile(path: SFTPTestServer.homeDirectory)) {
                try session.download(remotePath: SFTPTestServer.homeDirectory, to: downloadURL)
            }
        }
    }

    @Test("realPath resolves a relative path to the account's home, which SFTP will not expand")
    func realPathResolvesHome() async throws {
        try await withSession("realpath") { session in
            let resolved = try session.realPath(".")
            #expect(resolved == SFTPTestServer.homeDirectory)
        }
    }

    @Test("A tilde and a relative path resolve against the account's home; an absolute one is left alone")
    func resolvedPathExpandsWhatSFTPWillNot() async throws {
        try await withSession("resolve") { session in
            let home = SFTPTestServer.homeDirectory
            let tilde = try session.resolvedPath("~/app.db")
            let relative = try session.resolvedPath("app.db")
            let bareTilde = try session.resolvedPath("~")
            let absolute = try session.resolvedPath("/srv/app.db")

            #expect(tilde == "\(home)/app.db")
            #expect(relative == "\(home)/app.db")
            #expect(bareTilde == home)
            #expect(absolute == "/srv/app.db")
        }
    }

    @Test("Free space is reported, so a fetch can be refused before it starts")
    func freeSpaceIsReported() async throws {
        try await withSession("statvfs") { session in
            let free = session.freeSpace(atPath: SFTPTestServer.homeDirectory)
            #expect(free != nil)
            #expect((free ?? 0) > 0)
        }
    }

    @Test("Listing a directory returns the entries it holds and omits dot entries")
    func listingOmitsDotEntries() async throws {
        let remotePath = SFTPTestServer.scratchPath("listed.db")

        try await withSession("listdir") { session in
            defer { session.remove(remotePath) }
            _ = try SFTPTestServer.seedRemoteFile(session: session, at: remotePath, bytes: 512)

            let entries = try session.listDirectory(SFTPTestServer.homeDirectory)
            let names = entries.map(\.name)
            #expect(!names.contains("."))
            #expect(!names.contains(".."))
            #expect(names.contains(where: { remotePath.hasSuffix($0) }))
        }
    }

    @Test("A cancelled download stops and reports cancellation rather than a partial file")
    func cancelledDownloadReportsCancellation() async throws {
        let remotePath = SFTPTestServer.scratchPath("cancel.db")
        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-cancel-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        try await withSession("cancel") { session in
            defer { session.remove(remotePath) }
            _ = try SFTPTestServer.seedRemoteFile(
                session: session, at: remotePath, bytes: 2 * 1_024 * 1_024
            )

            #expect(throws: SFTPError.cancelled) {
                try session.download(
                    remotePath: remotePath,
                    to: downloadURL,
                    isCancelled: { true }
                )
            }
        }
    }
}
