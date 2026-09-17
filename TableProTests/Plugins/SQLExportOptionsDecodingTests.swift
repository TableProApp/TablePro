//
//  SQLExportOptionsDecodingTests.swift
//  TableProTests
//

import Foundation
import Testing

/// Settings are stored as JSON, so a payload written by an older build carries only the keys that
/// build knew. A synthesized `Decodable` throws `keyNotFound` for the rest and never falls back to
/// the property's default, and `PluginSettingsStorage.load` answers a throwing decode with nil, so
/// one added option silently resets every choice the user had already made.
@Suite("SQL export options decoding")
struct SQLExportOptionsDecodingTests {
    @Test("A payload that predates the exclusions keeps the choices it does carry")
    func legacyPayloadKeepsItsValues() throws {
        let stored = Data(#"{"batchSize":1000,"compressWithGzip":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SQLExportOptions.self, from: stored)
        #expect(decoded.batchSize == 1_000)
        #expect(decoded.compressWithGzip)
        #expect(decoded.excludeAutoIncrementValue)
        #expect(decoded.excludeDefiner)
    }

    @Test("An absent key takes the default rather than failing the decode")
    func absentKeysTakeDefaults() throws {
        let decoded = try JSONDecoder().decode(SQLExportOptions.self, from: Data("{}".utf8))
        #expect(decoded == SQLExportOptions())
    }

    @Test("A stored false survives the round trip")
    func storedFalseIsNotOverwrittenByTheDefault() throws {
        var options = SQLExportOptions()
        options.excludeAutoIncrementValue = false
        options.excludeDefiner = false
        let restored = try JSONDecoder().decode(SQLExportOptions.self, from: JSONEncoder().encode(options))
        #expect(restored == options)
    }

    @Test("Both exclusions start on")
    func exclusionsDefaultToOn() {
        let options = SQLExportOptions()
        #expect(options.excludeAutoIncrementValue)
        #expect(options.excludeDefiner)
    }

    /// A profile saved before the size limit existed has to come back with the limit on, or the
    /// user who already had wide-row tables keeps writing dumps their server rejects.
    @Test("A payload that predates the size limit takes its default rather than none")
    func legacyPayloadGainsTheStatementSizeDefault() throws {
        let stored = Data(#"{"batchSize":500,"splitSizeMegabytes":8}"#.utf8)
        let decoded = try JSONDecoder().decode(SQLExportOptions.self, from: stored)
        #expect(decoded.maxStatementBytes == 1_048_576)
        #expect(decoded.splitSizeMegabytes == 8)
    }

    @Test("No limit survives the round trip rather than reverting to the default")
    func storedZeroIsNotOverwrittenByTheDefault() throws {
        var options = SQLExportOptions()
        options.maxStatementBytes = 0
        let restored = try JSONDecoder().decode(SQLExportOptions.self, from: JSONEncoder().encode(options))
        #expect(restored.maxStatementBytes == 0)
        #expect(restored == options)
    }

    /// A mebibyte, which is under every `max_allowed_packet` MySQL or MariaDB has shipped this
    /// decade, and what `mysqldump` and HeidiSQL both settle on.
    @Test("The size limit starts at one mebibyte")
    func statementSizeDefaultsToOneMebibyte() {
        #expect(SQLExportOptions().maxStatementBytes == 1_048_576)
    }
}
