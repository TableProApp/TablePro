//
//  ThemeCatalogTests.swift
//  TableProTests
//
//  A user theme is identified by its JSON id but lives in whatever file it came from. When the
//  catalog wrote and deleted `<id>.json` instead, deleting a theme a user had named themselves
//  removed nothing, and editing it wrote a second file that could win on the next launch.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ThemeCatalogTests {
    private struct Sandbox {
        let root: URL
        var themes: URL { root.appendingPathComponent("Themes", isDirectory: true) }
        var incoming: URL { root.appendingPathComponent("Incoming", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThemeCatalogTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        }

        @MainActor
        func catalog() -> ThemeCatalog {
            ThemeCatalog(userDirectory: themes, bundleDirectory: nil)
        }

        @discardableResult
        func write(_ theme: ThemeDefinition, as fileName: String, in directory: URL? = nil) throws -> URL {
            let url = (directory ?? themes).appendingPathComponent(fileName)
            try ThemeEncoder.data(for: theme).write(to: url)
            return url
        }

        func fileNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: themes.path).sorted()
        }

        func read(_ fileName: String) throws -> ThemeDefinition {
            try ThemeDocument(data: try Data(contentsOf: themes.appendingPathComponent(fileName))).definition()
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func userTheme(
        id: String,
        name: String,
        overrides: [ThemeSlot: String] = [:]
    ) throws -> ThemeDefinition {
        var colors: [ThemeSlot: ThemeColor] = [:]
        for (slot, value) in overrides {
            colors[slot] = try ThemeColor(validating: value)
        }
        return ThemeDefinition(id: id, name: name, author: "Tests", appearance: .dark, overrides: colors)
    }

    private static func copyName(of name: String) -> String {
        String(format: String(localized: "%@ Copy"), name)
    }

    // MARK: - Changed on disk

    @Test("A file edited outside TablePro is not overwritten by a save")
    func saveKeepsAFileChangedOnDisk() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "mine.json")
        let catalog = sandbox.catalog()
        var stale = try #require(catalog.theme(id: "user.mine"))

        try sandbox.write(
            try Self.userTheme(id: "user.mine", name: "Mine", overrides: [.editorBackground: "#112233"]),
            as: "mine.json"
        )
        stale.overrides[.editorText] = try ThemeColor(validating: "#FFFFFF")

        #expect(throws: ThemeLoadError.changedOnDisk("mine.json")) { try catalog.save(stale) }
        #expect(try sandbox.read("mine.json").overrides[.editorBackground]?.hex == "#112233")
        #expect(catalog.theme(id: "user.mine")?.overrides[.editorBackground]?.hex == "#112233")

        var current = try #require(catalog.theme(id: "user.mine"))
        current.overrides[.editorText] = try ThemeColor(validating: "#FFFFFF")
        try catalog.save(current)
        #expect(try sandbox.read("mine.json").overrides[.editorText]?.hex == "#FFFFFF")
    }

    @Test("A file replaced outside TablePro is not deleted")
    func deleteKeepsAFileChangedOnDisk() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "mine.json")
        let catalog = sandbox.catalog()

        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Replaced"), as: "mine.json")

        #expect(throws: ThemeLoadError.changedOnDisk("mine.json")) { try catalog.delete(id: "user.mine") }
        #expect(try sandbox.fileNames() == ["mine.json"])
        #expect(catalog.theme(id: "user.mine")?.name == "Replaced")
    }

    // MARK: - File name differs from id

    @Test("A theme is saved back to the file it was loaded from")
    func saveRewritesTheLoadedFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "My Theme.json")

        let catalog = sandbox.catalog()
        #expect(catalog.fileURL(for: "user.mine")?.lastPathComponent == "My Theme.json")

        var edited = try #require(catalog.theme(id: "user.mine"))
        edited.overrides[.gridBackground] = try ThemeColor(validating: "#123456")
        try catalog.save(edited)

        #expect(try sandbox.fileNames() == ["My Theme.json"])
        #expect(try sandbox.read("My Theme.json").overrides[.gridBackground]?.hex == "#123456")
        #expect(sandbox.catalog().theme(id: "user.mine")?.overrides[.gridBackground]?.hex == "#123456")
    }

    @Test("A theme is deleted from the file it was loaded from")
    func deleteRemovesTheLoadedFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "My Theme.json")

        let catalog = sandbox.catalog()
        try catalog.delete(id: "user.mine")

        #expect(try sandbox.fileNames().isEmpty)
        #expect(catalog.theme(id: "user.mine") == nil)
        #expect(catalog.fileURL(for: "user.mine") == nil)
        #expect(sandbox.catalog().theme(id: "user.mine") == nil)
    }

    @Test("Rename rewrites the same file")
    func renameRewritesTheSameFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.renamed", name: "Before"), as: "Custom Name.json")

        let catalog = sandbox.catalog()
        try catalog.rename(id: "user.renamed", to: "  After  ")

        #expect(try sandbox.fileNames() == ["Custom Name.json"])
        #expect(try sandbox.read("Custom Name.json").name == "After")
        #expect(catalog.theme(id: "user.renamed")?.name == "After")
    }

    // MARK: - Loading

    @Test("Two files with one id: the first by file name loads, the second is listed as not loaded")
    func duplicateIdentifierIsRejected() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.same", name: "First"), as: "a.json")
        try sandbox.write(try Self.userTheme(id: "user.same", name: "Second"), as: "b.json")

        let catalog = sandbox.catalog()
        let expectedReason = ThemeLoadError.duplicateIdentifier("user.same", existingFile: "a.json").localizedDescription

        #expect(catalog.theme(id: "user.same")?.name == "First")
        #expect(catalog.fileURL(for: "user.same")?.lastPathComponent == "a.json")
        #expect(catalog.themes.filter { $0.id == "user.same" }.count == 1)
        #expect(catalog.rejected.map(\.fileName) == ["b.json"])
        #expect(catalog.rejected.first?.reason == expectedReason)
    }

    @Test("A user file with a reserved id is listed as not loaded")
    func reservedIdInUserFileIsRejected() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "tablepro.dracula", name: "Fake Dracula"), as: "dracula.json")
        try sandbox.write(try Self.userTheme(id: BuiltInThemes.defaultDarkId, name: "Fake Dark"), as: "dark.json")

        let catalog = sandbox.catalog()

        #expect(catalog.theme(id: "tablepro.dracula") == nil)
        #expect(catalog.theme(id: BuiltInThemes.defaultDarkId) == BuiltInThemes.dark)
        #expect(catalog.rejected.map(\.fileName).sorted() == ["dark.json", "dracula.json"])
        #expect(catalog.rejected.contains {
            $0.reason == ThemeLoadError.reservedIdentifier("tablepro.dracula").localizedDescription
        })
    }

    @Test("A file in an older format is listed with its reason")
    func olderFormatIsListedWithItsReason() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let old: [String: Any] = ["schema": 2, "id": "user.old", "name": "Old", "appearance": "dark"]
        try JSONSerialization.data(withJSONObject: old).write(to: sandbox.themes.appendingPathComponent("old.json"))

        let catalog = sandbox.catalog()

        #expect(catalog.theme(id: "user.old") == nil)
        #expect(catalog.rejected.first?.reason == ThemeLoadError.schemaTooOld(found: 2, supported: 3).localizedDescription)
    }

    @Test("The bundled themes load after the two defaults")
    func bundledThemesLoad() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let bundle = try ThemeSourceScan.repositoryRoot().appendingPathComponent("TablePro/Resources/Themes")

        let catalog = ThemeCatalog(userDirectory: sandbox.themes, bundleDirectory: bundle)
        let ids = catalog.themes.map(\.id)

        #expect(Array(ids.prefix(2)) == [BuiltInThemes.defaultLightId, BuiltInThemes.defaultDarkId])
        #expect(Set(ids).isSuperset(of: ["tablepro.dracula", "tablepro.nord"]))
        #expect(catalog.rejected.isEmpty)
    }

    // MARK: - Duplicate

    @Test("Duplicate gives a new user id and a Finder-style name")
    func duplicateNamesCopies() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.ocean", name: "Ocean", overrides: [.gridText: "#E0E0E0"]), as: "ocean.json")

        let catalog = sandbox.catalog()
        let source = try #require(catalog.theme(id: "user.ocean"))
        let first = try catalog.duplicate(source)
        let second = try catalog.duplicate(source)

        #expect(first.id.hasPrefix(ThemeDefinition.userPrefix))
        #expect(second.id.hasPrefix(ThemeDefinition.userPrefix))
        #expect(Set([source.id, first.id, second.id]).count == 3)
        #expect(first.name == Self.copyName(of: "Ocean"))
        #expect(second.name == Self.copyName(of: "Ocean") + " 2")
        #expect(first.overrides == source.overrides)
        #expect(first.appearance == source.appearance)
        #expect(first.author.isEmpty)
        #expect(try sandbox.fileNames().count == 3)
        #expect(catalog.fileURL(for: first.id)?.deletingLastPathComponent().lastPathComponent == "Themes")
    }

    @Test("Duplicating a built-in theme gives an editable user theme")
    func duplicateOfBuiltInIsEditable() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let catalog = sandbox.catalog()
        let copy = try catalog.duplicate(BuiltInThemes.dark)

        #expect(copy.isEditable)
        #expect(copy.name == Self.copyName(of: BuiltInThemes.dark.name))
        #expect(copy.overrides == BuiltInThemes.dark.overrides)
        #expect(catalog.theme(id: BuiltInThemes.defaultDarkId) == BuiltInThemes.dark)
    }

    // MARK: - Import

    @Test("Import gives a colliding user id a new id and a unique name")
    func importRegeneratesACollidingId() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let original = try Self.userTheme(id: "user.taken", name: "Taken")
        try sandbox.write(original, as: "taken.json")
        let incoming = try Self.userTheme(id: "user.taken", name: "Taken", overrides: [.syntaxKeyword: "#AA0000"])
        let url = try sandbox.write(incoming, as: "Taken.json", in: sandbox.incoming)

        let catalog = sandbox.catalog()
        let imported = try catalog.importTheme(from: url)

        #expect(imported.id != "user.taken")
        #expect(imported.id.hasPrefix(ThemeDefinition.userPrefix))
        #expect(imported.name == "Taken 2")
        #expect(imported.overrides == incoming.overrides)
        #expect(try sandbox.read("taken.json") == original)
        #expect(catalog.theme(id: "user.taken") == original)
        #expect(try sandbox.fileNames().count == 2)
    }

    @Test("Import gives a built-in id a new id and a unique name")
    func importRegeneratesABuiltInId() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(BuiltInThemes.dark, as: "Default Dark.json", in: sandbox.incoming)

        let catalog = sandbox.catalog()
        let imported = try catalog.importTheme(from: url)

        #expect(imported.id != BuiltInThemes.defaultDarkId)
        #expect(imported.isEditable)
        #expect(imported.name == BuiltInThemes.dark.name + " 2")
        #expect(imported.overrides == BuiltInThemes.dark.overrides)
        #expect(catalog.theme(id: BuiltInThemes.defaultDarkId) == BuiltInThemes.dark)
    }

    @Test("Import keeps an id and a name nothing else uses")
    func importKeepsAFreshIdentity() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(try Self.userTheme(id: "user.fresh", name: "Fresh"), as: "fresh.json", in: sandbox.incoming)

        let imported = try sandbox.catalog().importTheme(from: url)

        #expect(imported.id == "user.fresh")
        #expect(imported.name == "Fresh")
    }

    // MARK: - Built-ins

    @Test("A built-in id cannot be saved or deleted")
    func builtInsAreReadOnly() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let catalog = sandbox.catalog()

        #expect(throws: ThemeLoadError.reservedIdentifier(BuiltInThemes.defaultDarkId)) {
            try catalog.save(BuiltInThemes.dark)
        }
        #expect(throws: ThemeLoadError.reservedIdentifier(BuiltInThemes.defaultLightId)) {
            try catalog.delete(id: BuiltInThemes.defaultLightId)
        }
        #expect(throws: ThemeLoadError.reservedIdentifier("tablepro.dracula")) {
            try catalog.delete(id: "tablepro.dracula")
        }

        #expect(try sandbox.fileNames().isEmpty)
        #expect(catalog.theme(id: BuiltInThemes.defaultLightId) == BuiltInThemes.light)
        #expect(catalog.theme(id: BuiltInThemes.defaultDarkId) == BuiltInThemes.dark)
    }
}
