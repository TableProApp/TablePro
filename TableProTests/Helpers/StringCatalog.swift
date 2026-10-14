//
//  StringCatalog.swift
//  TableProTests
//

import Foundation

// The build compiles the catalogs to .strings, so translations are read from the checked-in JSON.
struct StringCatalog {
    struct Unit {
        let catalog: String
        let language: String
        let key: String
        let value: String

        var description: String { "\(catalog):\(language): \"\(key)\" -> \"\(value)\"" }
    }

    let name: String
    private let strings: [String: Entry]
    private let sourceLanguage: String

    var translatedUnits: [Unit] {
        strings.sorted { $0.key < $1.key }.flatMap { key, entry -> [Unit] in
            (entry.localizations ?? [:])
                .sorted { $0.key < $1.key }
                .filter { $0.key != sourceLanguage }
                .flatMap { language, localization -> [Unit] in
                    let plain = localization.stringUnit.map { [$0] } ?? []
                    let varied = (localization.variations ?? [:]).values
                        .flatMap(\.values)
                        .compactMap(\.stringUnit)
                    return (plain + varied)
                        .filter { $0.state == "translated" }
                        .map { Unit(catalog: name, language: language, key: key, value: $0.value) }
                }
        }
    }

    static func loadAll() throws -> [StringCatalog] {
        let root = try repoRoot()
        return try [
            ("TablePro", "TablePro/Resources/Localizable.xcstrings"),
            ("TableProMobile", "TableProMobile/TableProMobile/Localizable.xcstrings"),
        ].map { name, path in
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            return StringCatalog(name: name, strings: decoded.strings, sourceLanguage: decoded.sourceLanguage)
        }
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CatalogError.repoRootNotFound
    }

    private struct Payload: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: [String: [String: Variation]]?
    }

    private struct Variation: Decodable {
        let stringUnit: StringUnit?
    }

    private struct StringUnit: Decodable {
        let state: String
        let value: String
    }

    private enum CatalogError: Error {
        case repoRootNotFound
    }
}
