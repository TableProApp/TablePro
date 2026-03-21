//
//  DataGridSettingsTests.swift
//  TableProTests
//
//  Tests for DataGridSettings fields including font and autoShowInspector.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("DataGridSettings")
struct DataGridSettingsTests {
    @Test("autoShowInspector defaults to false")
    func defaultValue() {
        let settings = DataGridSettings.default
        #expect(settings.autoShowInspector == false)
    }

    @Test("autoShowInspector round-trips through Codable")
    func codableRoundTrip() throws {
        var settings = DataGridSettings.default
        settings.autoShowInspector = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)
        #expect(decoded.autoShowInspector == true)
    }

    @Test("decoding without autoShowInspector key defaults to false")
    func backwardsCompatibility() throws {
        let oldJson = """
        {
            "rowHeight": 24,
            "dateFormat": "yyyy-MM-dd HH:mm:ss",
            "nullDisplay": "NULL",
            "defaultPageSize": 1000,
            "showAlternateRows": true
        }
        """
        let data = oldJson.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)
        #expect(decoded.autoShowInspector == false)
    }

    // MARK: - showRowNumbers

    @Test("showRowNumbers defaults to true")
    func showRowNumbersDefault() {
        let settings = DataGridSettings.default
        #expect(settings.showRowNumbers == true)
    }

    @Test("showRowNumbers round-trips through Codable")
    func showRowNumbersCodableRoundTrip() throws {
        var settings = DataGridSettings.default
        settings.showRowNumbers = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)
        #expect(decoded.showRowNumbers == false)
    }

    @Test("decoding without showRowNumbers key defaults to true")
    func showRowNumbersBackwardsCompatibility() throws {
        let oldJson = """
        {
            "rowHeight": 24,
            "dateFormat": "yyyy-MM-dd HH:mm:ss",
            "nullDisplay": "NULL",
            "defaultPageSize": 1000,
            "showAlternateRows": true
        }
        """
        let data = oldJson.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)
        #expect(decoded.showRowNumbers == true)
    }

    // MARK: - Font Settings

    @Test("default font is systemMono at size 13")
    func defaultFont() {
        let settings = DataGridSettings.default
        #expect(settings.fontFamily == .systemMono)
        #expect(settings.fontSize == 13)
    }

    @Test("font settings round-trip through Codable")
    func fontCodableRoundTrip() throws {
        var settings = DataGridSettings.default
        settings.fontFamily = .menlo
        settings.fontSize = 15

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)
        #expect(decoded.fontFamily == .menlo)
        #expect(decoded.fontSize == 15)
    }

    @Test("decoding without font keys defaults to systemMono 13")
    func fontBackwardsCompatibility() throws {
        let oldJson = """
        {
            "rowHeight": 24,
            "dateFormat": "yyyy-MM-dd HH:mm:ss",
            "nullDisplay": "NULL",
            "defaultPageSize": 1000,
            "showAlternateRows": true
        }
        """
        let data = oldJson.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DataGridSettings.self, from: data)
        #expect(decoded.fontFamily == .systemMono)
        #expect(decoded.fontSize == 13)
    }

    @Test("clampedFontSize clamps to 10-18 range",
          arguments: [
              (input: 5, expected: 10),
              (input: 10, expected: 10),
              (input: 13, expected: 13),
              (input: 18, expected: 18),
              (input: 25, expected: 18),
          ])
    func clampedFontSize(input: Int, expected: Int) {
        var settings = DataGridSettings.default
        settings.fontSize = input
        #expect(settings.clampedFontSize == expected)
    }
}

@Suite("DataGridFontCache")
struct DataGridFontCacheTests {
    @MainActor
    @Test("reloadFromSettings produces valid font variants")
    func reloadProducesValidFonts() {
        let settings = DataGridSettings(fontFamily: .systemMono, fontSize: 13)
        DataGridFontCache.reloadFromSettings(settings)

        #expect(DataGridFontCache.regular.pointSize > 0)
        #expect(DataGridFontCache.italic.pointSize > 0)
        #expect(DataGridFontCache.medium.pointSize > 0)
        #expect(DataGridFontCache.rowNumber.pointSize > 0)
        #expect(DataGridFontCache.monoCharWidth > 0)
    }

    @MainActor
    @Test("fonts update when reloadFromSettings called with different settings")
    func fontsUpdateOnReload() {
        DataGridFontCache.reloadFromSettings(DataGridSettings(fontFamily: .systemMono, fontSize: 13))
        let initialSize = DataGridFontCache.regular.pointSize
        let initialCharWidth = DataGridFontCache.monoCharWidth

        DataGridFontCache.reloadFromSettings(DataGridSettings(fontFamily: .systemMono, fontSize: 18))
        #expect(DataGridFontCache.regular.pointSize > initialSize)
        #expect(DataGridFontCache.monoCharWidth >= initialCharWidth)
    }

    @MainActor
    @Test("different font families produce different fonts")
    func differentFamilies() {
        DataGridFontCache.reloadFromSettings(DataGridSettings(fontFamily: .systemMono, fontSize: 13))
        let systemMonoName = DataGridFontCache.regular.fontName

        DataGridFontCache.reloadFromSettings(DataGridSettings(fontFamily: .menlo, fontSize: 13))
        let menloName = DataGridFontCache.regular.fontName

        #expect(systemMonoName != menloName)
    }
}
