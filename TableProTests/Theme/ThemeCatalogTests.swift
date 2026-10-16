//
//  ThemeCatalogTests.swift
//  TableProTests
//
//  A user theme is identified by its JSON id but lives in whatever file it came from. When the
//  catalog wrote and deleted `<id>.json` instead, deleting a theme a user had named themselves
//  removed nothing, and editing it wrote a second file that could win on the next launch.
//  A file removed outside TablePro is a conflict too: a save must never bring it back.
//

import AppKit
import Foundation
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ThemeCatalogTests {
    private struct Sandbox {
        let root: URL
        let center = NotificationCenter()
        var themes: URL { root.appendingPathComponent("Themes", isDirectory: true) }
        var incoming: URL { root.appendingPathComponent("Incoming", isDirectory: true) }
        var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThemeCatalogTests-\(UUID().uuidString)", isDirectory: true)
            for folder in [themes, incoming, trash] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        /// A trash inside the sandbox, so a test never puts a file in the user's own Trash.
        var fileTrash: ThemeFileTrash {
            let trash = trash
            return ThemeFileTrash { url in
                let destination = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        }

        @MainActor
        func catalog() -> ThemeCatalog {
            ThemeCatalog(userDirectory: themes, bundleDirectory: nil, notificationCenter: center, fileTrash: fileTrash)
        }

        @discardableResult
        func write(_ theme: ThemeDefinition, as fileName: String, in directory: URL? = nil) throws -> URL {
            let url = (directory ?? themes).appendingPathComponent(fileName)
            try ThemeFileFormat.encode(theme).write(to: url)
            return url
        }

        func fileNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: themes.path).sorted()
        }

        func trashedNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: trash.path).sorted()
        }

        func read(_ fileName: String) throws -> ThemeDefinition {
            try ThemeFileFormat.decode(try Data(contentsOf: themes.appendingPathComponent(fileName)))
        }

        func delete(_ fileName: String) throws {
            try FileManager.default.removeItem(at: themes.appendingPathComponent(fileName))
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

    @Test("A file replaced outside TablePro is not moved to the Trash")
    func trashKeepsAFileChangedOnDisk() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "mine.json")
        let catalog = sandbox.catalog()

        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Replaced"), as: "mine.json")

        #expect(throws: ThemeLoadError.changedOnDisk("mine.json")) { try catalog.trash(id: "user.mine") }
        #expect(try sandbox.fileNames() == ["mine.json"])
        #expect(try sandbox.trashedNames().isEmpty)
        #expect(catalog.theme(id: "user.mine")?.name == "Replaced")
    }

    // MARK: - Deleted on disk

    /// The file is gone, so writing it again would bring back a theme deleted in Finder or on
    /// another Mac.
    @Test("A save of a theme whose file was deleted outside TablePro is refused and recreates nothing")
    func saveRefusesAFileDeletedOnDisk() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "Mine.json")
        let catalog = sandbox.catalog()
        var stale = try #require(catalog.theme(id: "user.mine"))

        try sandbox.delete("Mine.json")
        stale.overrides[.editorText] = try ThemeColor(validating: "#FFFFFF")

        #expect(throws: ThemeLoadError.deletedOnDisk("Mine.json")) { try catalog.save(stale) }
        #expect(try sandbox.fileNames().isEmpty)
        #expect(catalog.theme(id: "user.mine") == nil)

        #expect(throws: ThemeLoadError.deletedOnDisk("Mine.json")) { try catalog.save(stale) }
        #expect(try sandbox.fileNames().isEmpty)
    }

    @Test("After an activation reload drops a deleted theme, a stale save is still refused")
    func saveAfterReloadRefusesADeletedTheme() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "Mine.json")
        let catalog = sandbox.catalog()
        let stale = try #require(catalog.theme(id: "user.mine"))

        try sandbox.delete("Mine.json")
        sandbox.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(catalog.theme(id: "user.mine") == nil)

        #expect(throws: ThemeLoadError.deletedOnDisk("Mine.json")) { try catalog.save(stale) }
        #expect(try sandbox.fileNames().isEmpty)
    }

    /// A file edited into one that no longer loads keeps its name, so a stale save would otherwise
    /// write `<id>-2.json` and leave two files with one id once the first is fixed.
    @Test("A save of a theme whose file no longer loads is refused, and writes no second file")
    func saveRefusesAFileThatNoLongerLoads() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "user.mine.json")
        let catalog = sandbox.catalog()
        let stale = try #require(catalog.theme(id: "user.mine"))

        try Data("{ broken".utf8).write(to: sandbox.themes.appendingPathComponent("user.mine.json"))
        #expect(throws: ThemeLoadError.changedOnDisk("user.mine.json")) { try catalog.save(stale) }
        #expect(catalog.rejected.map(\.fileName) == ["user.mine.json"])

        #expect(throws: ThemeLoadError.changedOnDisk("user.mine.json")) { try catalog.save(stale) }
        #expect(try sandbox.fileNames() == ["user.mine.json"])
    }

    @Test("Moving a theme deleted outside TablePro to the Trash reports it and drops it")
    func trashOfADeletedFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "Mine.json")
        let catalog = sandbox.catalog()

        try sandbox.delete("Mine.json")

        #expect(throws: ThemeLoadError.deletedOnDisk("Mine.json")) { try catalog.trash(id: "user.mine") }
        #expect(catalog.theme(id: "user.mine") == nil)
    }

    // MARK: - Activation

    @Test("The catalog reloads when TablePro becomes active")
    func reloadsOnActivation() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let catalog = sandbox.catalog()
        #expect(catalog.theme(id: "user.dropped") == nil)

        try sandbox.write(try Self.userTheme(id: "user.dropped", name: "Dropped"), as: "Dropped.json")
        #expect(catalog.theme(id: "user.dropped") == nil)

        sandbox.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(catalog.theme(id: "user.dropped")?.name == "Dropped")
    }

    // MARK: - Trash

    @Test("Move to Trash moves the file it was loaded from, and restore brings it back")
    func trashAndRestore() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let original = try Self.userTheme(id: "user.mine", name: "Mine", overrides: [.gridBackground: "#123456"])
        try sandbox.write(original, as: "My Theme.json")
        let catalog = sandbox.catalog()

        let receipt = try catalog.trash(id: "user.mine")

        #expect(receipt.themeId == "user.mine")
        #expect(receipt.originalURL.lastPathComponent == "My Theme.json")
        #expect(try sandbox.fileNames().isEmpty)
        #expect(try sandbox.trashedNames().count == 1)
        #expect(catalog.theme(id: "user.mine") == nil)
        #expect(catalog.fileURL(for: "user.mine") == nil)

        try catalog.restore(receipt)

        #expect(try sandbox.fileNames() == ["My Theme.json"])
        #expect(try sandbox.trashedNames().isEmpty)
        #expect(catalog.theme(id: "user.mine") == original)
        #expect(catalog.fileURL(for: "user.mine")?.lastPathComponent == "My Theme.json")

        var edited = try #require(catalog.theme(id: "user.mine"))
        edited.name = "Edited"
        try catalog.save(edited)
        #expect(try sandbox.read("My Theme.json").name == "Edited")
    }

    @Test("A theme moved to the Trash is not recreated by a stale save")
    func trashedThemeIsNotResurrected() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "Mine.json")
        let catalog = sandbox.catalog()
        let stale = try #require(catalog.theme(id: "user.mine"))

        try catalog.trash(id: "user.mine")

        #expect(throws: ThemeLoadError.deletedOnDisk("Mine.json")) { try catalog.save(stale) }
        #expect(try sandbox.fileNames().isEmpty)
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

    @Test("A theme moved to the Trash leaves no file behind for the next launch")
    func trashRemovesTheLoadedFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "My Theme.json")

        let catalog = sandbox.catalog()
        try catalog.trash(id: "user.mine")

        #expect(try sandbox.fileNames().isEmpty)
        #expect(catalog.theme(id: "user.mine") == nil)
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

    @Test("Rename to another theme's name is refused, whatever the case or surrounding space")
    func renameRefusesATakenName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.ocean", name: "Ocean"), as: "ocean.json")
        try sandbox.write(try Self.userTheme(id: "user.other", name: "Other"), as: "other.json")
        let catalog = sandbox.catalog()

        #expect(throws: ThemeLoadError.nameTaken("ocean")) { try catalog.rename(id: "user.other", to: " ocean ") }
        #expect(throws: ThemeLoadError.nameTaken(BuiltInThemes.dark.name)) {
            try catalog.rename(id: "user.other", to: BuiltInThemes.dark.name)
        }
        #expect(catalog.theme(id: "user.other")?.name == "Other")
        #expect(try sandbox.read("other.json").name == "Other")

        try catalog.rename(id: "user.ocean", to: "OCEAN")
        #expect(catalog.theme(id: "user.ocean")?.name == "OCEAN")
    }

    @Test("Rename compares with the name the file holds, not the one shown to tell two themes apart")
    func renameUsesTheStoredName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.a", name: "Ocean"), as: "a.json")
        let second = try sandbox.write(try Self.userTheme(id: "user.b", name: "Ocean"), as: "b.json")
        let catalog = sandbox.catalog()
        let before = try Data(contentsOf: second)
        #expect(catalog.theme(id: "user.b")?.name == "Ocean 2")

        try catalog.rename(id: "user.b", to: "Ocean")
        #expect(try Data(contentsOf: second) == before)

        try catalog.rename(id: "user.b", to: "Ocean 2")
        #expect(try sandbox.read("b.json").name == "Ocean 2")
        #expect(catalog.storedTheme(id: "user.b")?.name == "Ocean 2")
        #expect(catalog.theme(id: "user.b")?.name == "Ocean 2")
        #expect(try sandbox.read("a.json").name == "Ocean")
    }

    @Test("Rename to a name the format refuses writes nothing")
    func renameRefusesAnInvalidName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.mine", name: "Mine"), as: "mine.json")
        let catalog = sandbox.catalog()

        #expect(throws: ThemeLoadError.invalidName) { try catalog.rename(id: "user.mine", to: "   ") }
        #expect(throws: ThemeLoadError.invalidName) { try catalog.rename(id: "user.mine", to: "Two\nLines") }
        #expect(try sandbox.read("mine.json").name == "Mine")
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

    @Test("A theme 0.81 saved with a long or multi-line name or author loads, and its next save writes the repaired text")
    func legacyLongNameLoadsAndIsRepairedOnSave() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let cap = ThemeFileFormat.maximumTextLength
        let legacy: [String: Any] = [
            "schema": 3,
            "id": "user.legacy",
            "name": String(repeating: "N", count: 150),
            "author": "Someone\non two lines",
            "appearance": "dark",
            "editor": ["background": "#102030"],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        let url = sandbox.themes.appendingPathComponent("legacy.json")
        try bytes.write(to: url)

        let catalog = sandbox.catalog()
        var theme = try #require(catalog.storedTheme(id: "user.legacy"))

        #expect(catalog.rejected.isEmpty)
        #expect(theme.name == String(repeating: "N", count: cap))
        #expect(theme.author == "Someone on two lines")
        #expect(theme.overrides[.editorBackground]?.hex == "#102030")
        #expect(try Data(contentsOf: url) == bytes)

        theme.overrides[.editorText] = try ThemeColor(validating: "#FFFFFF")
        try catalog.save(theme)

        let saved = try sandbox.read("legacy.json")
        #expect(saved.name == String(repeating: "N", count: cap))
        #expect(saved.author == "Someone on two lines")

        let picked = sandbox.incoming.appendingPathComponent("legacy.json")
        try bytes.write(to: picked)
        #expect(throws: ThemeLoadError.invalidName) { try catalog.importTheme(from: picked) }
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

    @Test("The bundled themes load after the two defaults, in the shared order")
    func bundledThemesLoad() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write(try Self.userTheme(id: "user.aardvark", name: "Aardvark"), as: "aardvark.json")
        let bundle = try #require(Bundle.main.resourceURL)

        let catalog = ThemeCatalog(userDirectory: sandbox.themes, bundleDirectory: bundle, notificationCenter: sandbox.center)
        let ids = catalog.themes.map(\.id)

        #expect(Array(ids.prefix(2)) == [BuiltInThemes.defaultLightId, BuiltInThemes.defaultDarkId])
        #expect(Set(ids).isSuperset(of: ["tablepro.dracula", "tablepro.nord"]))
        #expect(ids.last == "user.aardvark")
        #expect(catalog.themes == ThemeOrdering.sorted(catalog.themes))
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

    @Test("A copied or numbered name is shortened to stay within the format's cap, so its save succeeds")
    func longNamesStayWithinTheCap() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let cap = ThemeFileFormat.maximumTextLength
        let longName = String(repeating: "N", count: cap)
        try sandbox.write(try Self.userTheme(id: "user.long", name: longName), as: "long.json")
        let incoming = try sandbox.write(try Self.userTheme(id: "user.long", name: longName), as: "long.json", in: sandbox.incoming)
        let catalog = sandbox.catalog()
        let source = try #require(catalog.theme(id: "user.long"))

        let copy = try catalog.duplicate(source)
        let secondCopy = try catalog.duplicate(source)
        let imported = try catalog.importTheme(from: incoming)

        let overhead = Self.copyName(of: "").count
        #expect(copy.name == Self.copyName(of: String(repeating: "N", count: cap - overhead)))
        #expect(secondCopy.name == Self.copyName(of: String(repeating: "N", count: cap - overhead - 2)) + " 2")
        #expect(imported.name == String(repeating: "N", count: cap - 2) + " 2")
        #expect([copy, secondCopy, imported].allSatisfy { $0.name.count <= cap })
        #expect(try sandbox.fileNames().count == 4)
        #expect(Set(catalog.themes.map(\.name)).count == catalog.themes.count)
    }

    @Test("Duplicating a built-in theme gives an editable user theme")
    func duplicateOfBuiltInIsEditable() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }

        let catalog = sandbox.catalog()
        let copy = try catalog.duplicate(BuiltInThemes.dark)

        #expect(copy.isEditable)
        #expect(copy.name == Self.copyName(of: BuiltInThemes.dark.name))
        #expect(copy.overrides.isEmpty)
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

    /// The id in a file says nothing about which theme on this Mac it is: the same file imported
    /// twice, or on two Macs, would otherwise collide in sync.
    @Test("Import mints a new id even when the file's id is free, and keeps a free name")
    func importMintsAFreshId() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(try Self.userTheme(id: "user.fresh", name: "Fresh"), as: "fresh.json", in: sandbox.incoming)
        let catalog = sandbox.catalog()

        let first = try catalog.importTheme(from: url)
        let second = try catalog.importTheme(from: url)

        #expect(first.id != "user.fresh")
        #expect(first.id.hasPrefix(ThemeDefinition.userPrefix))
        #expect(second.id != first.id)
        #expect(first.name == "Fresh")
        #expect(second.name == "Fresh 2")
        #expect(catalog.theme(id: first.id) == first)
        #expect(try sandbox.fileNames() == ["\(first.id).json", "\(second.id).json"].sorted())
    }

    @Test("Import refuses a file over the size cap and writes nothing")
    func importRefusesAnOversizedFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = sandbox.incoming.appendingPathComponent("huge.json")
        try Data(count: ThemeFileImporter.maximumFileSize + 1).write(to: url)

        #expect(throws: ThemeLoadError.fileTooLarge(limit: ThemeFileImporter.maximumFileSize)) {
            try sandbox.catalog().importTheme(from: url)
        }
        #expect(try sandbox.fileNames().isEmpty)
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
            try catalog.trash(id: BuiltInThemes.defaultLightId)
        }
        #expect(throws: ThemeLoadError.reservedIdentifier("tablepro.dracula")) {
            try catalog.trash(id: "tablepro.dracula")
        }

        #expect(try sandbox.fileNames().isEmpty)
        #expect(catalog.theme(id: BuiltInThemes.defaultLightId) == BuiltInThemes.light)
        #expect(catalog.theme(id: BuiltInThemes.defaultDarkId) == BuiltInThemes.dark)
    }
}
