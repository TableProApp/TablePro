//
//  CSVExportOptionsDecodingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Settings are stored as JSON, so a payload written by an older build carries only the keys that
/// build knew. A synthesized `Decodable` throws `keyNotFound` for the rest and never falls back to
/// the property's default, and `PluginSettingsStorage.load` answers a throwing decode with nil, so
/// one added option silently resets every choice the user had already made.
@Suite("CSV export options decoding")
struct CSVExportOptionsDecodingTests {
    @Test("A payload that predates the encoding options keeps the choices it does carry")
    func legacyPayloadKeepsItsValues() throws {
        let stored = Data(#"{"delimiter":";","lineBreak":"\\r\\n","sanitizeFormulas":false}"#.utf8)
        let decoded = try JSONDecoder().decode(CSVExportOptions.self, from: stored)
        #expect(decoded.delimiter == .semicolon)
        #expect(decoded.lineBreak == .crlf)
        #expect(!decoded.sanitizeFormulas)
        #expect(decoded.encoding == .utf8)
        #expect(!decoded.writesByteOrderMark)
    }

    @Test("An absent key takes the default rather than failing the decode")
    func absentKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(CSVExportOptions.self, from: Data("{}".utf8))
        #expect(decoded == CSVExportOptions())
    }

    @Test("A stored false survives the round trip")
    func storedFalseIsNotOverwrittenByTheDefault() throws {
        var options = CSVExportOptions()
        options.convertNullToEmpty = false
        options.includeFieldNames = false
        options.sanitizeFormulas = false
        let restored = try JSONDecoder().decode(CSVExportOptions.self, from: JSONEncoder().encode(options))
        #expect(restored == options)
    }

    @Test("The encoding choice round trips")
    func encodingRoundTrips() throws {
        var options = CSVExportOptions()
        options.encoding = .windowsCP1252
        options.writesByteOrderMark = true
        let restored = try JSONDecoder().decode(CSVExportOptions.self, from: JSONEncoder().encode(options))
        #expect(restored.encoding == .windowsCP1252)
        #expect(restored.writesByteOrderMark)
    }

    @Test("Export writes UTF-8 with no mark until asked otherwise")
    func defaultsAreUnchanged() {
        let options = CSVExportOptions()
        #expect(options.encoding == .utf8)
        #expect(!options.writesByteOrderMark)
    }
}
