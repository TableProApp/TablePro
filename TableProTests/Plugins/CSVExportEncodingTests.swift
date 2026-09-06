//
//  CSVExportEncodingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Plugin text encoder")
struct PluginTextEncoderTests {
    @Test("ASCII reaches the file unchanged in every encoding")
    func asciiIsStable() throws {
        for encoding in PluginTextEncoding.allCases {
            let encoded = try PluginTextEncoder.encode("id,name", as: encoding)
            #expect(encoded.data == Data("id,name".utf8))
            #expect(encoded.unrepresented.isEmpty)
        }
    }

    @Test("UTF-8 represents everything")
    func utf8RepresentsEverything() throws {
        let encoded = try PluginTextEncoder.encode("中東京 😀 café", as: .utf8)
        #expect(encoded.unrepresented.isEmpty)
        #expect(String(data: encoded.data, encoding: .utf8) == "中東京 😀 café")
    }

    /// Foundation substitutes `?` and reports nothing, which is the silence the encoder exists to
    /// break. The substitute still has to reach the file, or the row would lose a field.
    @Test("An unrepresentable character is written as a question mark and named")
    func unrepresentableCharacterIsNamed() throws {
        let encoded = try PluginTextEncoder.encode("a中b", as: .windowsCP1252)
        #expect(encoded.data == Data([0x61, 0x3F, 0x62]))
        #expect(encoded.unrepresented == ["中"])
    }

    @Test("Each distinct character is named once, in the order it was met")
    func charactersAreDistinctAndOrdered() throws {
        let encoded = try PluginTextEncoder.encode("東 中 東 京 中", as: .isoLatin1)
        #expect(encoded.unrepresented == ["東", "中", "京"])
    }

    /// Foundation composes before it converts, so `a` followed by U+0301 encodes to `é` and comes
    /// through intact. A per-scalar check would report U+0301 and name a character the file kept.
    @Test("A combining sequence that composes into the encoding is not reported")
    func composedSequenceIsNotReported() throws {
        let encoded = try PluginTextEncoder.encode("a\u{0301}", as: .isoLatin1)
        #expect(encoded.data == Data([0xE1]))
        #expect(encoded.unrepresented.isEmpty)
    }

    /// The two 8-bit encodings differ over 0x80 to 0x9F, which is where the curly quotes live.
    @Test("Windows-1252 keeps a curly quote that ISO Latin 1 cannot represent")
    func curlyQuoteSeparatesTheEightBitEncodings() throws {
        let cp1252 = try PluginTextEncoder.encode("\u{201C}", as: .windowsCP1252)
        #expect(cp1252.data == Data([0x93]))
        #expect(cp1252.unrepresented.isEmpty)

        let latin1 = try PluginTextEncoder.encode("\u{201C}", as: .isoLatin1)
        #expect(latin1.data == Data([0x3F]))
        #expect(latin1.unrepresented == ["\u{201C}"])
    }

    /// The scan converts a whole encodable run per call, so a stop is not always a failure: the
    /// buffer fills too. A run longer than the buffer must not invent characters.
    @Test("A field longer than the scan buffer reports only the real failure")
    func longFieldReportsOneFailure() throws {
        let long = String(repeating: "the quick brown fox. ", count: 4_000) + "中"
        let encoded = try PluginTextEncoder.encode(long, as: .windowsCP1252)
        #expect(encoded.unrepresented == ["中"])
        #expect(encoded.data.count == long.count)
    }

    @Test("An astral character is reported once and written as the bytes Foundation substitutes")
    func astralCharacterIsReportedOnce() throws {
        let encoded = try PluginTextEncoder.encode("\u{1F600}", as: .windowsCP1252)
        #expect(encoded.unrepresented == ["\u{1F600}"])
        #expect(encoded.data == Data([0x3F, 0x3F]))
    }

    /// The caller turns detection off once it has every character it will name. The bytes must be
    /// identical either way; only the report changes.
    @Test("Detection can be turned off without changing a byte")
    func detectionCanBeTurnedOff() throws {
        let detected = try PluginTextEncoder.encode("a中b", as: .windowsCP1252)
        let skipped = try PluginTextEncoder.encode("a中b", as: .windowsCP1252, detectingUnrepresented: false)
        #expect(detected.data == skipped.data)
        #expect(detected.unrepresented == ["中"])
        #expect(skipped.unrepresented.isEmpty)
    }

    @Test("Only UTF-8 carries a byte order mark")
    func onlyUTF8CarriesAMark() {
        #expect(PluginTextEncoding.utf8.byteOrderMark == [0xEF, 0xBB, 0xBF])
        #expect(PluginTextEncoding.utf8.supportsByteOrderMark)
        #expect(PluginTextEncoding.isoLatin1.byteOrderMark.isEmpty)
        #expect(!PluginTextEncoding.isoLatin1.supportsByteOrderMark)
        #expect(PluginTextEncoding.windowsCP1252.byteOrderMark.isEmpty)
        #expect(!PluginTextEncoding.windowsCP1252.supportsByteOrderMark)
    }

    @Test("Encoding names match what the CSV import picker spells")
    func namesMatchImport() {
        #expect(PluginTextEncoding.utf8.displayName == "UTF-8")
        #expect(PluginTextEncoding.isoLatin1.displayName == "ISO Latin 1")
        #expect(PluginTextEncoding.windowsCP1252.displayName == "Windows-1252")
    }
}

@Suite("CSV encoding report")
struct CSVEncodingReportTests {
    @Test("A clean export warns about nothing")
    func cleanExportIsSilent() {
        let report = CSVEncodingReport()
        #expect(report.warnings(for: .windowsCP1252).isEmpty)
    }

    @Test("The warning names the character and the encoding")
    func warningNamesTheCharacter() throws {
        var report = CSVEncodingReport()
        report.record(["中"])
        let warnings = report.warnings(for: .windowsCP1252)
        let warning = try #require(warnings.first)
        #expect(warnings.count == 1)
        #expect(warning.contains("Windows-1252"))
        #expect(warning.contains("中"))
    }

    @Test("Repeated records keep one entry per character")
    func repeatedRecordsDeduplicate() {
        var report = CSVEncodingReport()
        report.record(["中", "東"])
        report.record(["中", "京"])
        #expect(report.characters == ["中", "東", "京"])
    }

    /// The warning goes into an alert's informative text, so the list has to stop somewhere. It
    /// says the list is partial rather than counting, because the only number available is a count
    /// of distinct characters and a reader takes that for a count of values.
    @Test("A long list is capped and says there were others")
    func longListIsCapped() throws {
        var report = CSVEncodingReport()
        report.record(Array("一二三四五六七八九十百千万億兆"))
        let warning = try #require(report.warnings(for: .isoLatin1).first)
        #expect(warning.contains("other characters"))
        #expect(warning.contains("千"))
        #expect(!warning.contains("億"))
    }

    /// Exactly the listed number of characters is not a partial list, so it must not claim others.
    @Test("A full list that hides nothing does not claim there were others")
    func fullListWithNothingHiddenSaysSo() throws {
        var report = CSVEncodingReport()
        report.record(Array("一二三四五六七八九十百千"))
        #expect(report.characters.count == CSVEncodingReport.maxListedCharacters)
        #expect(!report.isSaturated)
        let warning = try #require(report.warnings(for: .isoLatin1).first)
        #expect(!warning.contains("other characters"))
        #expect(warning.contains("千"))
    }

    /// Scanning every row of a large table for characters already named costs minutes, so the
    /// report stops asking once its list is full and one over.
    @Test("The report saturates one past the list so scanning can stop")
    func reportSaturatesOnePastTheList() {
        var report = CSVEncodingReport()
        report.record(Array("一二三四五六七八九十百千万"))
        #expect(report.isSaturated)
        report.record(["億"])
        #expect(!report.characters.contains("億"))
    }

    /// A control character has no glyph, so printing it would end the warning at the colon.
    @Test("An unprintable character is named by code point")
    func unprintableCharacterIsNamedByCodePoint() throws {
        var report = CSVEncodingReport()
        report.record(["\u{0081}"])
        let warning = try #require(report.warnings(for: .isoLatin1).first)
        #expect(warning.contains("U+0081"))
    }
}
