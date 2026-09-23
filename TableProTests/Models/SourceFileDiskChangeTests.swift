//
//  SourceFileDiskChangeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Source file disk change")
struct SourceFileDiskChangeTests {
    private let baseline = FileStamp(modificationSeconds: 1_000_000, modificationNanoseconds: 0, size: 8, fileNumber: 42)

    @Test("A file that no longer exists is missing, not unchanged")
    func missingFileIsMissing() {
        #expect(SourceFileDiskChange.detect(recorded: baseline, current: nil) == .missing)
    }

    @Test("A missing file is missing even when the tab never learned its baseline")
    func missingFileWithoutBaselineIsMissing() {
        #expect(SourceFileDiskChange.detect(recorded: nil, current: nil) == .missing)
    }

    @Test("The file the tab recorded is unchanged")
    func sameStampIsUnchanged() {
        #expect(SourceFileDiskChange.detect(recorded: baseline, current: baseline) == nil)
    }

    @Test("An older date on the same file is a change")
    func olderDateIsModified() {
        let restored = FileStamp(modificationSeconds: 999_000, modificationNanoseconds: 0, size: 8, fileNumber: 42)

        #expect(SourceFileDiskChange.detect(recorded: baseline, current: restored) == .modified(restored))
    }

    @Test("A write under a second after the recorded one is a change")
    func subsecondWriteIsModified() {
        let written = FileStamp(modificationSeconds: 1_000_000, modificationNanoseconds: 1, size: 8, fileNumber: 42)

        #expect(SourceFileDiskChange.detect(recorded: baseline, current: written) == .modified(written))
    }

    @Test("A replaced file with the same date and size is a change")
    func replacedFileIsModified() {
        let replaced = FileStamp(modificationSeconds: 1_000_000, modificationNanoseconds: 0, size: 8, fileNumber: 43)

        #expect(SourceFileDiskChange.detect(recorded: baseline, current: replaced) == .modified(replaced))
    }

    @Test("An existing file with no baseline to compare against is not a change")
    func existingFileWithoutBaselineIsUnchanged() {
        #expect(SourceFileDiskChange.detect(recorded: nil, current: baseline) == nil)
    }

    @Test("A stamp reports its modification date to the nanosecond")
    func stampCarriesItsDate() {
        let stamp = FileStamp(modificationSeconds: 1_000_000, modificationNanoseconds: 500_000_000, size: 8, fileNumber: 42)

        #expect(stamp.modificationDate == Date(timeIntervalSince1970: 1_000_000.5))
    }
}
