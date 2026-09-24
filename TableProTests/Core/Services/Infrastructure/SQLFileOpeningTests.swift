//
//  SQLFileOpeningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor @Suite("Opening a SQL file from Finder or File > Open")
struct SQLFileOpeningTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sql-file-opening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("A file that is not UTF-8 opens with its text, its stamp and the encoding it was read in")
    func opensANonUTF8FileWithItsEncoding() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("japanese.sql")
        let fixture = EncodedSQLFileFixture.shiftJISByAttribute
        try fixture.write(fixture.original, to: url)
        let connectionId = UUID()

        let payload = try await TabRouter.sqlFileTabPayload(for: url, connectionId: connectionId)

        #expect(payload.connectionId == connectionId)
        #expect(payload.tabType == .query)
        #expect(payload.sourceFileURL == url)
        #expect(payload.initialQuery == fixture.original)
        #expect(payload.sourceFileStamp == FileStamp.read(url))
        #expect(payload.sourceFileEncoding?.encoding == .shiftJIS)
        #expect(payload.sourceFileEncoding?.attribute != nil)
    }

    @Test("A file that cannot be read throws the read error instead of opening nothing")
    func unreadableFileThrows() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("locked.sql")
        try Data("SELECT 1;\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        do {
            _ = try await TabRouter.sqlFileTabPayload(for: url, connectionId: UUID())
            Issue.record("An unreadable file produced a tab")
        } catch {
            #expect((error as? CocoaError)?.code == .fileReadNoPermission)
            #expect(error.localizedDescription.contains("locked.sql"))
        }
    }

    @Test("A file that is gone throws the read error")
    func missingFileThrows() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("gone.sql")

        do {
            _ = try await TabRouter.sqlFileTabPayload(for: url, connectionId: UUID())
            Issue.record("A missing file produced a tab")
        } catch {
            #expect((error as? CocoaError)?.code == .fileReadNoSuchFile)
        }
    }
}
