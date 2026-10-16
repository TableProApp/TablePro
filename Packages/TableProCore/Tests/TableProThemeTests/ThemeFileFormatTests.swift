import Foundation
import TableProTheme
import Testing

/// Format 3: every color is optional, a slot left out draws its fallback, and the file is refused for
/// anything that would otherwise load as something its author did not write.
struct ThemeFileFormatTests {
    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func metadata(
        id: String = "user.test",
        appearance: ThemeAppearance = .dark,
        schema: Any = 3
    ) -> [String: Any] {
        ["schema": schema, "id": id, "name": "Test", "appearance": appearance.rawValue]
    }

    private static func decode(_ object: [String: Any]) throws -> ThemeDefinition {
        try ThemeFileFormat.decode(try data(object))
    }

    private static func withColor(_ value: String, at path: [String]) -> [String: Any] {
        var root = metadata()
        insert(value, at: path, into: &root)
        return root
    }

    private static func insert(_ value: Any, at path: [String], into container: inout [String: Any]) {
        guard let head = path.first else { return }
        guard path.count > 1 else {
            container[head] = value
            return
        }
        var child = container[head] as? [String: Any] ?? [:]
        insert(value, at: Array(path.dropFirst()), into: &child)
        container[head] = child
    }

    private static func loads(_ object: [String: Any]) -> Bool {
        (try? decode(object)) != nil
    }

    private static func refusal(_ object: [String: Any]) throws -> ThemeLoadError? {
        try refusal(data(object))
    }

    private static func refusal(_ data: Data) -> ThemeLoadError? {
        do {
            _ = try ThemeFileFormat.decode(data)
            return nil
        } catch {
            return error as? ThemeLoadError
        }
    }

    // MARK: - What loads

    @Test("The current format is 3")
    func currentFormatIsThree() {
        #expect(ThemeSchema.current == 3)
    }

    @Test("A file with only metadata loads and sets nothing")
    func metadataOnlyLoads() throws {
        let theme = try Self.decode(Self.metadata())

        #expect(theme.id == "user.test")
        #expect(theme.name == "Test")
        #expect(theme.author.isEmpty)
        #expect(theme.appearance == .dark)
        #expect(theme.overrides.isEmpty)
        for slot in ThemeSlot.allCases {
            #expect(!theme.hasExplicitColor(slot), "\(slot.rawValue)")
        }
    }

    @Test("A file sets only the slots it names")
    func slotsAreOptional() throws {
        var root = Self.metadata()
        Self.insert("#FF0000", at: ["editor", "syntax", "keyword"], into: &root)
        Self.insert("#00000080", at: ["dataGrid", "selection"], into: &root)

        let colors = try Self.decode(root).overrides.mapValues(\.hex)

        #expect(colors == [.syntaxKeyword: "#FF0000", .gridSelection: "#00000080"])
    }

    @Test("Every slot path is accepted")
    func everySlotPathLoads() throws {
        var root = Self.metadata()
        for slot in ThemeSlot.allCases {
            Self.insert("#123456", at: slot.rawValue.components(separatedBy: "."), into: &root)
        }

        #expect(try Self.decode(root).overrides.count == ThemeSlot.allCases.count)
    }

    @Test("An 8-digit color keeps its alpha on a slot that offers opacity")
    func alphaColorIsAccepted() throws {
        let colors = try Self.decode(Self.withColor("#ff79c680", at: ["editor", "selection"])).overrides
        let color = try #require(colors[.editorSelection])

        #expect(color.hex == "#FF79C680")
        #expect(color.alpha == 0x80)
    }

    @Test("A fill that must be opaque loads without its alpha, and is written without it", arguments: [
        ThemeSlot.windowBackdrop, .editorBackground, .gridBackground, .gridHeaderBackground,
    ])
    func opaqueSlotsDropAlphaOnLoad(slot: ThemeSlot) throws {
        let theme = try Self.decode(Self.withColor("#282A3680", at: slot.rawValue.components(separatedBy: ".")))
        #expect(theme.overrides[slot]?.hex == "#282A36")

        var translucent = theme
        translucent.overrides[slot] = ThemeColor(hex: "#282A3640")
        let reread = try ThemeFileFormat.decode(try ThemeFileFormat.encode(translucent))
        #expect(reread.overrides[slot]?.hex == "#282A36")
    }

    @Test("Name and author are trimmed")
    func nameAndAuthorAreTrimmed() throws {
        var root = Self.metadata()
        root["name"] = "  Ocean  "
        root["author"] = "\tSomeone \n"

        let theme = try Self.decode(root)

        #expect(theme.name == "Ocean")
        #expect(theme.author == "Someone")
    }

    // MARK: - What is refused

    @Test("A malformed file says where it breaks")
    func malformedJSONCarriesTheLocation() throws {
        let text = "{\n  \"schema\": 3,\n  \"id\": \"user.a\"\n  \"name\": \"x\"\n}"
        let error = try #require(Self.refusal(Data(text.utf8)))

        guard case let .malformedJSON(detail) = error else {
            Issue.record("expected malformedJSON, got \(error)")
            return
        }
        let location = try #require(detail)
        #expect(location.contains("line 4"), "\(location)")
        #expect(location.contains("column"), "\(location)")

        let message = try #require(error.errorDescription)
        #expect(message.hasPrefix("The file is not valid JSON."))
        #expect(message.components(separatedBy: "\n").last == location)
    }

    @Test("Empty data and a comment are refused as malformed JSON")
    func notJSONIsMalformed() {
        for text in ["", "{\"schema\": 3, // note\n}", "not json"] {
            guard case .malformedJSON = Self.refusal(Data(text.utf8)) else {
                Issue.record("\(text.debugDescription) was not refused as malformed JSON")
                continue
            }
        }
    }

    @Test("A JSON value that is not an object declares no format")
    func nonObjectRootIsRefused() {
        #expect(Self.refusal(Data("[1, 2]".utf8)) == .missingSchema)
        #expect(Self.refusal(Data("\"text\"".utf8)) == .missingSchema)
    }

    @Test("A key TablePro does not use is refused, and the message names it")
    func unknownKeyIsRefused() throws {
        var root = Self.metadata()
        Self.insert("#000000", at: ["editor", "sidebar"], into: &root)
        Self.insert("#000000", at: ["panel", "text"], into: &root)

        let error = try Self.refusal(root)

        #expect(error == .unknownKeys(["editor.sidebar", "panel.text"]))
        #expect(error?.localizedDescription.contains("editor.sidebar") == true)
    }

    /// The pane and status groups of format 2 are gone, so a file that still carries them is
    /// refused rather than loaded with those colors dropped.
    @Test("Format 2 slot groups are refused")
    func formerGroupsAreRefused() throws {
        for path in [["panel", "background"], ["status", "warning"], ["content", "editor", "background"]] {
            let error = try Self.refusal(Self.withColor("#000000", at: path))
            #expect(error == .unknownKeys([path.joined(separator: ".")]), "\(path)")
        }
    }

    /// A value that is not a string would otherwise be dropped silently, which loads the slot as
    /// native under a key the author did write.
    @Test("A key whose value is not a color string is refused")
    func nonStringValueIsRefused() {
        var unknownNumber = Self.metadata()
        unknownNumber["version"] = 1
        #expect(!Self.loads(unknownNumber), "an unknown numeric key loaded")

        var numericColor = Self.metadata()
        Self.insert(16_777_215, at: ["editor", "background"], into: &numericColor)
        #expect(!Self.loads(numericColor), "a numeric color loaded")
    }

    @Test("A slot written twice, nested and dotted, is refused")
    func duplicateSlotIsRefused() throws {
        var root = Self.withColor("#000000", at: ["editor", "background"])
        root["editor.background"] = "#FFFFFF"

        #expect(try Self.refusal(root) == .duplicateKey("editor.background"))
    }

    @Test("A color that is not ASCII #RRGGBB or #RRGGBBAA is refused")
    func malformedColorsAreRefused() throws {
        let rejected = ["#FF79CG", "FF0000", "#FFF", "#FF00000", "", "system:label", "#\u{FF26}\u{FF26}0000"]

        for value in rejected {
            let error = try Self.refusal(Self.withColor(value, at: ["editor", "background"]))
            #expect(error == .invalidColor(value), "\(value)")
        }
    }

    @Test("Format 2 and a file with no format are refused")
    func otherFormatsAreRefused() throws {
        #expect(try Self.refusal(Self.metadata(schema: 2)) == .schemaTooOld(found: 2, supported: 3))
        #expect(try Self.refusal(Self.metadata(schema: 4)) == .schemaTooNew(found: 4, supported: 3))
        #expect(try Self.refusal(Self.metadata(schema: "3")) == .missingSchema)

        var unversioned = Self.metadata()
        unversioned.removeValue(forKey: "schema")
        #expect(try Self.refusal(unversioned) == .missingSchema)
        #expect(try Self.refusal([:]) == .missingSchema)

        var legacy = Self.metadata()
        legacy.removeValue(forKey: "schema")
        legacy["version"] = 1
        #expect(try Self.refusal(legacy) == .schemaTooOld(found: 1, supported: 3))
    }

    @Test("Missing metadata is refused by name")
    func missingMetadataIsRefused() throws {
        for key in ["id", "name", "appearance"] {
            var root = Self.metadata()
            root.removeValue(forKey: key)
            #expect(try Self.refusal(root) == .missingField(key), "\(key)")
        }

        var blankName = Self.metadata()
        blankName["name"] = "   "
        #expect(try Self.refusal(blankName) == .missingField("name"))

        var unknownAppearance = Self.metadata()
        unknownAppearance["appearance"] = "sepia"
        #expect(try Self.refusal(unknownAppearance) == .missingField("appearance"))
    }

    @Test("A name or author on more than one line, with a control character, or too long is refused")
    func nameAndAuthorLimits() throws {
        let long = String(repeating: "a", count: ThemeFileFormat.maximumTextLength + 1)
        let fits = String(repeating: "a", count: ThemeFileFormat.maximumTextLength)

        for bad in ["Two\nLines", "Tab\u{0009}Inside", "Bell\u{0007}", "Line\u{2028}Separator", long] {
            var name = Self.metadata()
            name["name"] = bad
            #expect(try Self.refusal(name) == .invalidName, "\(bad.debugDescription)")

            var author = Self.metadata()
            author["author"] = bad
            #expect(try Self.refusal(author) == .invalidAuthor, "\(bad.debugDescription)")
        }

        var longest = Self.metadata()
        longest["name"] = fits
        longest["author"] = fits
        #expect(try Self.decode(longest).name == fits)
    }

    @Test("A repaired decode folds a name or author onto one line and cuts it at the cap, and the result encodes")
    func repairedDecodeFitsTheCap() throws {
        let cap = ThemeFileFormat.maximumTextLength
        let cases: [(raw: String, repaired: String)] = [
            (String(repeating: "N", count: cap + 50), String(repeating: "N", count: cap)),
            ("Two\nLines", "Two Lines"),
            ("Tab\u{0009}Inside  and\u{2028}Separator", "Tab Inside and Separator"),
            ("Bell\u{0007}", "Bell"),
            (String(repeating: "ab ", count: cap), String(repeating: "ab ", count: cap / 3) + "a"),
            ("  Kept  as  is  ", "Kept  as  is"),
        ]

        for (raw, expected) in cases {
            var root = Self.metadata()
            root["name"] = raw
            root["author"] = raw
            let data = try Self.data(root)

            let theme = try ThemeFileFormat.decode(data, text: .repaired)

            #expect(theme.name == expected, "\(raw.debugDescription)")
            #expect(theme.author == expected, "\(raw.debugDescription)")
            #expect(try ThemeFileFormat.decode(try ThemeFileFormat.encode(theme)) == theme, "\(raw.debugDescription)")
        }
    }

    @Test("A repaired decode still refuses a name with nothing left to show")
    func repairedDecodeRefusesAnEmptyName() throws {
        var root = Self.metadata()
        root["name"] = "\u{0007}\u{0008}"

        #expect(throws: ThemeLoadError.invalidName) { try ThemeFileFormat.decode(try Self.data(root), text: .repaired) }
    }

    @Test("An id that is not a plain file-safe name is refused")
    func invalidIdIsRefused() throws {
        let long = "user." + String(repeating: "a", count: ThemeIdentifier.maximumLength)
        for id in ["user/evil", "../escape", "user..x", "user x", "user.\u{00E9}", long] {
            #expect(try Self.refusal(Self.metadata(id: id)) == .invalidIdentifier(id), "\(id)")
        }
    }

    // MARK: - Identifiers

    @Test("An id is capped at 128 characters")
    func identifierCap() {
        let fits = String(repeating: "a", count: ThemeIdentifier.maximumLength)
        #expect(ThemeIdentifier.maximumLength == 128)
        #expect(ThemeIdentifier.isValid(fits))
        #expect(!ThemeIdentifier.isValid(fits + "a"))
    }

    @Test("A generated id is a valid user id, different each time")
    func generatedIdentifiers() {
        let first = ThemeIdentifier.generated()
        let second = ThemeIdentifier.generated()

        #expect(first != second)
        #expect(first.hasPrefix(ThemeDefinition.userPrefix))
        #expect(ThemeIdentifier.isValid(first))
    }

    // MARK: - Encoder

    @Test("The encoder writes metadata and the colors set, nothing else")
    func encoderWritesOnlyOverrides() throws {
        let theme = ThemeDefinition(
            id: "user.sparse",
            name: "Sparse",
            author: "Tests",
            appearance: .light,
            overrides: [
                .syntaxKeyword: try ThemeColor(validating: "#AA0000"),
                .gridBackground: try ThemeColor(validating: "#FAFAFA"),
            ]
        )

        let object = try JSONSerialization.jsonObject(with: try ThemeFileFormat.encode(theme))
        let root = try #require(object as? [String: Any])
        let editor = try #require(root["editor"] as? [String: Any])
        let syntax = try #require(editor["syntax"] as? [String: String])
        let grid = try #require(root["dataGrid"] as? [String: String])

        #expect(Set(root.keys) == ["schema", "id", "name", "author", "appearance", "editor", "dataGrid"])
        #expect(Set(editor.keys) == ["syntax"])
        #expect(syntax == ["keyword": "#AA0000"])
        #expect(grid == ["background": "#FAFAFA"])
        #expect(root["schema"] as? Int == 3)
    }

    @Test("A default theme encodes as metadata only")
    func defaultThemeEncodesNoColors() throws {
        let object = try JSONSerialization.jsonObject(with: try ThemeFileFormat.encode(.defaultLight))
        let root = try #require(object as? [String: Any])

        #expect(Set(root.keys) == ["schema", "id", "name", "author", "appearance"])
    }

    @Test("The encoder refuses what the decoder would refuse")
    func encoderRefusesInvalidMetadata() throws {
        var theme = ThemeDefinition(id: "user.ok", name: "Ok", author: "", appearance: .dark, overrides: [:])

        theme.name = "Two\nLines"
        #expect(throws: ThemeLoadError.invalidName) { try ThemeFileFormat.encode(theme) }
        theme.name = "   "
        #expect(throws: ThemeLoadError.invalidName) { try ThemeFileFormat.encode(theme) }
        theme.name = "Ok"
        theme.author = "Bell\u{0007}"
        #expect(throws: ThemeLoadError.invalidAuthor) { try ThemeFileFormat.encode(theme) }
        theme.author = ""
        theme.id = "../escape"
        #expect(throws: ThemeLoadError.invalidIdentifier("../escape")) { try ThemeFileFormat.encode(theme) }
    }

    @Test("The window background loads from the window group and round-trips")
    func windowBackgroundRoundTrips() throws {
        let theme = try Self.decode(Self.withColor("#282a36", at: ["window", "background"]))
        #expect(theme.overrides.mapValues(\.hex) == [.windowBackdrop: "#282A36"])

        let object = try JSONSerialization.jsonObject(with: try ThemeFileFormat.encode(theme))
        let root = try #require(object as? [String: Any])
        #expect(root["window"] as? [String: String] == ["background": "#282A36"])
        #expect(root["editor"] == nil)

        #expect(try ThemeFileFormat.decode(try ThemeFileFormat.encode(theme)) == theme)
    }

    @Test("A theme round-trips through the encoder")
    func encoderRoundTrips() throws {
        var overrides: [ThemeSlot: ThemeColor] = [:]
        for (index, slot) in ThemeSlot.allCases.enumerated() {
            overrides[slot] = try ThemeColor(validating: String(format: "#%02X%02X%02X", index, 255 - index, index * 3))
        }
        let full = ThemeDefinition(id: "user.full", name: "Full", author: "Tests", appearance: .dark, overrides: overrides)
        let sparse = ThemeDefinition(
            id: "user.sparse",
            name: "Sparse",
            author: "",
            appearance: .light,
            overrides: [.editorCursor: try ThemeColor(validating: "#11223344")]
        )

        for theme in [full, sparse, .defaultLight, .defaultDark] {
            #expect(try ThemeFileFormat.decode(try ThemeFileFormat.encode(theme)) == theme, "\(theme.id)")
        }
    }

    // MARK: - Messages

    @Test("Every error has a message, and the ones with an argument name it")
    func errorMessages() {
        let errors: [ThemeLoadError] = [
            .malformedJSON(detail: nil), .missingSchema, .schemaTooOld(found: 2, supported: 3),
            .schemaTooNew(found: 4, supported: 3), .missingField("name"), .invalidName, .invalidAuthor,
            .invalidColor("#XYZ"), .unknownKeys(["a.b"]), .duplicateKey("a.b"), .reservedIdentifier("tablepro.x"),
            .invalidIdentifier("x/y"), .duplicateIdentifier("user.a", existingFile: "a.json"),
            .changedOnDisk("a.json"), .deletedOnDisk("a.json"), .nameTaken("Ocean"),
            .fileTooLarge(limit: ThemeFileImporter.maximumFileSize), .notATheme,
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty, "\(error)")
        }
        #expect(ThemeLoadError.malformedJSON(detail: nil).errorDescription == "The file is not valid JSON.")
        #expect(ThemeLoadError.deletedOnDisk("Ocean.json").errorDescription == "Ocean.json was deleted outside TablePro.")
        #expect(ThemeLoadError.nameTaken("Ocean").errorDescription == "A theme named “Ocean” already exists.")
        #expect(ThemeLoadError.notATheme.errorDescription == "This file is not a TablePro theme or a VS Code color theme.")
        #expect(ThemeLoadError.invalidName.errorDescription?.contains("100") == true)
        #expect(ThemeLoadError.fileTooLarge(limit: ThemeFileImporter.maximumFileSize).errorDescription?.contains("2") == true)
    }
}
