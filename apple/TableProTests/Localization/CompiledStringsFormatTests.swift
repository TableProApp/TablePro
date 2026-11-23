//
//  CompiledStringsFormatTests.swift
//  TableProTests
//

import Foundation
import Testing

/// `STRINGS_FILE_OUTPUT_ENCODING` decides what the strings-catalog compiler writes into each
/// `.lproj`. Linked against the macOS 27.0 SDK, `CFBundle` loads a binary property list one key at
/// a time, parsing the whole table again for each key it has not seen: 25 ms of main thread at
/// launch in English, 49 ms in French. An XML table is parsed once and kept. UTF-8 is the smallest XML form; the UTF-16 default costs
/// about 1.9 MB more across the shipped languages. Every lookup resolves the same in all three
/// forms, so a changed setting in `Configs/Base.xcconfig` shows no symptom but the time and size.
struct CompiledStringsFormatTests {
    @Test("Every shipped language compiles to a UTF-8 XML property list")
    func everyLanguageIsUTF8XML() throws {
        let tables = try Self.compiledStringsTables()
        #expect(!tables.isEmpty, "The app bundle carries no compiled .strings tables to check")

        let offenders = try tables.compactMap { url -> String? in
            let data = try Data(contentsOf: url)
            var format = PropertyListSerialization.PropertyListFormat.binary
            _ = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
            let isUTF8XML = format == .xml
                && data.starts(with: Data("<?xml".utf8))
                && String(data: data, encoding: .utf8) != nil
            guard !isUTF8XML else { return nil }
            return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        }

        #expect(
            offenders.isEmpty,
            """
            A compiled .strings table is not a UTF-8 XML property list. Restore \
            STRINGS_FILE_OUTPUT_ENCODING[sdk=macosx*] = UTF-8 in Configs/Base.xcconfig.
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
