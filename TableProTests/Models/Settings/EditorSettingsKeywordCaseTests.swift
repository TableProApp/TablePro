//
//  EditorSettingsKeywordCaseTests.swift
//  TableProTests
//
//  Pins the wire format of the keyword case setting, which replaced the
//  `uppercaseKeywords` boolean. Editor settings sync as one JSON blob, so both
//  keys have to keep working: the new one this build reads, and the legacy one
//  an older build on another device still reads.
//

import Foundation
@testable import TablePro
import Testing

struct EditorSettingsKeywordCaseTests {
    private func decode(_ json: String) throws -> EditorSettings {
        try JSONDecoder().decode(EditorSettings.self, from: Data(json.utf8))
    }

    private func encodedObject(_ settings: EditorSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The legacy boolean set to true migrates to always-uppercase")
    func legacyTrueMigrates() throws {
        #expect(try decode(#"{"uppercaseKeywords": true}"#).keywordCase == .upper)
    }

    @Test("The legacy boolean set to false migrates to the typed-case default")
    func legacyFalseMigrates() throws {
        #expect(try decode(#"{"uppercaseKeywords": false}"#).keywordCase == .matchTypedElseUpper)
    }

    @Test("Settings written before either key existed take the default")
    func absentKeyTakesDefault() throws {
        #expect(try decode("{}").keywordCase == .default)
    }

    @Test("The new key wins over a stale legacy boolean beside it")
    func newKeyWinsOverLegacy() throws {
        let settings = try decode(#"{"keywordCase": "lower", "uppercaseKeywords": true}"#)
        #expect(settings.keywordCase == .lower)
    }

    @Test("An unrecognised stored value falls back to the default rather than failing to decode")
    func unknownValueFallsBack() throws {
        #expect(throws: Never.self) {
            _ = try self.decode(#"{"keywordCase": "sentenceCase"}"#)
        }
    }

    @Test("Encoding writes both the new key and the legacy one")
    func encodesBothKeys() throws {
        var settings = EditorSettings.default
        settings.keywordCase = .upper
        let upper = try encodedObject(settings)
        #expect(upper["keywordCase"] as? String == "upper")
        #expect(upper["uppercaseKeywords"] as? Bool == true)

        settings.keywordCase = .matchTypedElseLower
        let matching = try encodedObject(settings)
        #expect(matching["keywordCase"] as? String == "matchTypedElseLower")
        #expect(matching["uppercaseKeywords"] as? Bool == false)
    }

    @Test("Every value round-trips")
    func roundTrips() throws {
        for keywordCase in SQLKeywordCase.allCases {
            var settings = EditorSettings.default
            settings.keywordCase = keywordCase
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(EditorSettings.self, from: data)
            #expect(decoded.keywordCase == keywordCase)
            #expect(decoded == settings)
        }
    }

    @Test("The shipped default leaves keyword rewriting off, as the old toggle did")
    func defaultDoesNotRewriteTypedText() {
        #expect(EditorSettings.default.keywordCase == .matchTypedElseUpper)
        #expect(!EditorSettings.default.keywordCase.rewritesTypedText)
    }

    @Test("The other editor settings still decode alongside the new key")
    func siblingSettingsUnaffected() throws {
        let settings = try decode(#"{"keywordCase": "lower", "tabWidth": 2, "wordWrap": true}"#)
        #expect(settings.keywordCase == .lower)
        #expect(settings.tabWidth == 2)
        #expect(settings.wordWrap)
        #expect(settings.showLineNumbers)
    }
}
