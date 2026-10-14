//
//  TransferDialogStorageTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

struct TransferDialogStorageTests {
    private let suite: EphemeralDefaults
    private var suiteName: String { suite.suiteName }

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeDefaults() throws -> UserDefaults {
        suite.defaults
    }

    @Test("loadLastExportFormatId returns nil when nothing stored")
    func formatIdNilWhenEmpty() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = TransferDialogStorage(userDefaults: defaults)
        #expect(storage.loadLastExportFormatId() == nil)
    }

    @Test("saveLastExportFormatId round-trips")
    func formatIdRoundTrip() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = TransferDialogStorage(userDefaults: defaults)
        storage.saveLastExportFormatId("sql")

        #expect(storage.loadLastExportFormatId() == "sql")
    }

    @Test("saveLastExportFormatId overwrites previous value")
    func formatIdOverwrites() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = TransferDialogStorage(userDefaults: defaults)
        storage.saveLastExportFormatId("csv")
        storage.saveLastExportFormatId("xlsx")

        #expect(storage.loadLastExportFormatId() == "xlsx")
    }

    @Test("loadLastImportEncoding returns utf8 when nothing stored")
    func encodingDefaultsToUTF8() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = TransferDialogStorage(userDefaults: defaults)
        #expect(storage.loadLastImportEncoding() == .utf8)
    }

    @Test("saveLastImportEncoding round-trips all cases", arguments: ImportEncoding.allCases)
    func encodingRoundTrip(encoding: ImportEncoding) throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storage = TransferDialogStorage(userDefaults: defaults)
        storage.saveLastImportEncoding(encoding)

        #expect(storage.loadLastImportEncoding() == encoding)
    }

    @Test("loadLastImportEncoding falls back to utf8 for unknown stored value")
    func encodingFallsBackOnUnknownValue() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("Shift-JIS", forKey: "com.TablePro.import.dialog.lastEncoding")
        let storage = TransferDialogStorage(userDefaults: defaults)

        #expect(storage.loadLastImportEncoding() == .utf8)
    }
}
