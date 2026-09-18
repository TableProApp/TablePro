//
//  CompiledStringsFormatTests.swift
//  TableProTests
//

import Foundation
import Testing

/// `STRINGS_FILE_OUTPUT_ENCODING` decides what the strings-catalog compiler writes into each
/// `.lproj`. The default, UTF-16 XML, costs about 1.9 MB across the shipped languages over the
/// binary property list that `CFBundle` reads natively, and the two are indistinguishable at
/// runtime: every lookup resolves the same, so dropping the setting from `Configs/Base.xcconfig`
/// would put the weight back without a single visible symptom.
@Suite("Compiled localizations ship as binary property lists")
struct CompiledStringsFormatTests {
    @Test("Every shipped language compiles to a binary property list")
    func everyLanguageIsBinary() throws {
        let tables = try Self.compiledStringsTables()
        #expect(!tables.isEmpty, "The app bundle carries no compiled .strings tables to check")

        let offenders = try tables.compactMap { url -> String? in
            var format = PropertyListSerialization.PropertyListFormat.binary
            _ = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: url),
                options: [],
                format: &format
            )
            guard format != .binary else { return nil }
            return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        }

        #expect(
            offenders.isEmpty,
            """
            A compiled .strings table is not a binary property list. Restore \
            STRINGS_FILE_OUTPUT_ENCODING = binary in Configs/Base.xcconfig.
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("Every shipped language still resolves its keys")
    func everyLanguageResolves() throws {
        let offenders = try Self.compiledStringsTables().compactMap { url -> String? in
            let table = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: url),
                options: [],
                format: nil
            ) as? [String: String]
            guard table?.isEmpty == false else {
                return url.deletingLastPathComponent().lastPathComponent
            }
            return nil
        }

        #expect(
            offenders.isEmpty,
            "A compiled .strings table decoded to no usable keys: \(offenders.joined(separator: ", "))"
        )
    }

    private static func compiledStringsTables() throws -> [URL] {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == "lproj" }
            .map { $0.appendingPathComponent("Localizable.strings", isDirectory: false) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }
}
