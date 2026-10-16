import Foundation
import TableProTheme
import Testing

struct ThemeFileImporterTests {
    private struct Folder {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThemeFileImporterTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func write(_ data: Data, as name: String) throws -> URL {
            let file = url.appendingPathComponent(name)
            try data.write(to: file)
            return file
        }

        func write(_ text: String, as name: String) throws -> URL {
            try write(Data(text.utf8), as: name)
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let ocean = ThemeDefinition(
        id: "user.ocean",
        name: "Ocean",
        author: "Someone",
        appearance: .dark,
        overrides: [.editorBackground: ThemeColor(red: 0x10, green: 0x20, blue: 0x30)]
    )

    private static func refusal(importing url: URL) -> ThemeLoadError? {
        do {
            _ = try ThemeFileImporter.importTheme(at: url)
            return nil
        } catch {
            return error as? ThemeLoadError
        }
    }

    @Test("Import reads a TablePro theme and gives it a new id every time")
    func importMintsAFreshId() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let url = try folder.write(try ThemeFileFormat.encode(Self.ocean), as: "Ocean.json")

        let first = try ThemeFileImporter.importTheme(at: url)
        let second = try ThemeFileImporter.importTheme(at: url)

        #expect(first.id != Self.ocean.id)
        #expect(second.id != first.id)
        #expect(first.id.hasPrefix(ThemeDefinition.userPrefix))
        #expect(ThemeIdentifier.isValid(first.id))
        #expect(first.name == "Ocean")
        #expect(first.author == "Someone")
        #expect(first.appearance == .dark)
        #expect(first.overrides == Self.ocean.overrides)
    }

    @Test("A built-in theme file imports as an editable user theme")
    func builtInImportsAsUserTheme() throws {
        let folder = try Folder()
        defer { folder.remove() }
        var builtIn = Self.ocean
        builtIn.id = "tablepro.ocean"
        let url = try folder.write(try ThemeFileFormat.encode(builtIn), as: "tablepro.ocean.json")

        let imported = try ThemeFileImporter.importTheme(at: url)

        #expect(imported.isEditable)
    }

    @Test("A file over the size cap is refused before it is read")
    func sizeCap() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let fits = try folder.write(Data(count: ThemeFileImporter.maximumFileSize), as: "fits.json")
        let over = try folder.write(Data(count: ThemeFileImporter.maximumFileSize + 1), as: "over.json")

        #expect(ThemeFileImporter.maximumFileSize == 2 * 1_024 * 1_024)
        #expect(Self.refusal(importing: over) == .fileTooLarge(limit: ThemeFileImporter.maximumFileSize))
        #expect(Self.refusal(importing: fits) != .fileTooLarge(limit: ThemeFileImporter.maximumFileSize))
    }

    @Test("A file that is not a theme in any known format says so")
    func notATheme() throws {
        let folder = try Folder()
        defer { folder.remove() }

        for (index, text) in ["hello", "[1, 2]", "", "{\"name\": \"x\", \"editor\": {}}"].enumerated() {
            let url = try folder.write(text, as: "file\(index).json")
            #expect(Self.refusal(importing: url) == .notATheme, "\(text.debugDescription)")
        }
    }

    @Test("A TablePro theme with a syntax error reports where it breaks")
    func malformedTheme() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let url = try folder.write("{\n  \"schema\": 3,\n  \"id\": \"user.a\"\n  \"name\": \"x\"\n}", as: "broken.json")

        guard case let .malformedJSON(detail) = Self.refusal(importing: url) else {
            Issue.record("expected malformedJSON")
            return
        }
        #expect(detail?.contains("line 4") == true, "\(detail ?? "nil")")
    }

    @Test("A TablePro theme in an old format keeps its format error")
    func oldFormatKeepsItsError() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let url = try folder.write("{\"version\": 1, \"id\": \"user.a\", \"name\": \"x\"}", as: "old.json")

        #expect(Self.refusal(importing: url) == .schemaTooOld(found: 1, supported: ThemeSchema.current))
    }

    @Test("A missing file throws the file system's error")
    func missingFile() throws {
        let folder = try Folder()
        defer { folder.remove() }

        #expect(throws: (any Error).self) {
            try ThemeFileImporter.importTheme(at: folder.url.appendingPathComponent("absent.json"))
        }
    }
}
