//
//  SFTPDownloadChunkSizeTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct SFTPDownloadChunkSizeTests {
    private static let minimum = 32 * 1_024
    private static let maximum = 2 * 1_024 * 1_024

    @Test("A file under 32 KiB still reads into a 32 KiB buffer")
    func smallFileGetsTheFloor() {
        #expect(LibSSH2SFTPSession.chunkSize(forFileSize: 0) == Self.minimum)
        #expect(LibSSH2SFTPSession.chunkSize(forFileSize: 4_096) == Self.minimum)
    }

    @Test("A file over 2 MiB reads into a 2 MiB buffer, which fills libssh2's 8 MiB read-ahead")
    func largeFileGetsTheCap() {
        #expect(LibSSH2SFTPSession.chunkSize(forFileSize: 500 * 1_024 * 1_024) == Self.maximum)
        #expect(LibSSH2SFTPSession.chunkSize(forFileSize: .max) == Self.maximum)
    }

    @Test("A file between the floor and the cap reads into a buffer of its own size")
    func midSizeFileGetsItsOwnSize() {
        #expect(LibSSH2SFTPSession.chunkSize(forFileSize: UInt64(Self.minimum)) == Self.minimum)
        #expect(LibSSH2SFTPSession.chunkSize(forFileSize: 300_000) == 300_000)
        #expect(LibSSH2SFTPSession.chunkSize(forFileSize: UInt64(Self.maximum)) == Self.maximum)
    }
}
