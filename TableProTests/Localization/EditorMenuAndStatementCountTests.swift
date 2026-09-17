//
//  EditorMenuAndStatementCountTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

/// Two strings the user reads constantly: the editor's own context menu, and the statement count on
/// a review sheet. One was English in every language because the menu was built from literals; the
/// other chose between two whole keys in Swift, which is the shape that cannot survive a language
/// with more than two plural categories.
@Suite("Editor menu and statement count")
struct EditorMenuAndStatementCountTests {
    /// Measured on this toolchain: `String(localized:)` hands back the key verbatim,
    /// `(^[1 statement](inflect: true))`, so a counted noun that has to end up in a `String` still
    /// needs two keys. Agreement is applied on the attributed path, which is the one `Text` uses,
    /// so a SwiftUI label gets it and a formatted string does not.
    @Test("A statement count agrees with its number in a label")
    func statementCountAgreesWithItsNumber() {
        let one = String(AttributedString(localized: "(^[\(1) statement](inflect: true))").characters)
        let many = String(AttributedString(localized: "(^[\(4) statement](inflect: true))").characters)

        #expect(one == "(1 statement)", "one measured as \(one)")
        #expect(many == "(4 statements)", "many measured as \(many)")
    }

    @Test("A counted noun bound for a plain String keeps its two keys")
    func plainStringCountKeepsTwoKeys() {
        let viaLocalized = String(localized: "(^[\(1) statement](inflect: true))")

        #expect(viaLocalized == "(^[1 statement](inflect: true))", "measured as \(viaLocalized)")
    }

    @Test("The statement count is translated into every language the app ships")
    func statementCountIsTranslatedEverywhere() throws {
        let catalog = try catalogEntries()
        let entry = try #require(catalog["(^[%lld statement](inflect: true))"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])

        for language in Self.shippedLanguages {
            #expect(localizations[language] != nil, "\(language) has no translation for the statement count")
        }
    }

    @Test("The editor's context menu titles come from the catalog, not from literals")
    func editorContextMenuIsLocalized() throws {
        let source = try String(contentsOf: editorMenuSource(), encoding: .utf8)

        for title in ["Cut", "Copy", "Paste"] {
            #expect(
                !source.contains("NSMenuItem(title: \"\(title)\""),
                """
                The editor's context menu builds \(title) from a literal, so it stays English while \
                the Edit menu shows the translation the catalog already carries.
                """
            )
            #expect(source.contains("String(localized: \"\(title)\")"))
        }
    }

    private static let shippedLanguages = ["ko", "tr", "vi", "zh-Hans", "zh-Hant"]

    private func catalogEntries() throws -> [String: Any] {
        let url = try repositoryRoot().appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try #require(json as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private func editorMenuSource() throws -> URL {
        try repositoryRoot().appendingPathComponent(
            "Packages/TableProEditor/Sources/TableProTextEngine/TextView/TextView+Menu.swift"
        )
    }

    private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CatalogTestError.repositoryRootNotFound
    }

    private enum CatalogTestError: Error {
        case repositoryRootNotFound
    }
}
