//
//  ThemeDocumentTests.swift
//  TableProTests
//
//  Format 3: every color is optional, a slot left out draws native, and the file is refused for
//  anything that would otherwise load as something its author did not write.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

struct ThemeDocumentTests {
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

    private static func document(_ object: [String: Any]) throws -> ThemeDocument {
        try ThemeDocument(data: try data(object))
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
        (try? document(object)) != nil
    }

    private static func refusal(_ object: [String: Any]) throws -> ThemeLoadError? {
        do {
            _ = try document(object)
            return nil
        } catch let error as ThemeLoadError {
            return error
        }
    }

    // MARK: - What loads

    @Test("The current format is 3")
    func currentFormatIsThree() {
        #expect(ThemeSchema.current == 3)
    }

    @Test("A file with only metadata loads and overrides nothing")
    func metadataOnlyLoads() throws {
        let document = try Self.document(Self.metadata())

        #expect(document.id == "user.test")
        #expect(document.name == "Test")
        #expect(document.author.isEmpty)
        #expect(document.appearance == .dark)
        #expect(document.colors.isEmpty)

        let definition = document.definition()
        for slot in ThemeSlot.allCases {
            #expect(!definition.isOverridden(slot), "\(slot.rawValue)")
        }
    }

    @Test("A file sets only the slots it names")
    func slotsAreOptional() throws {
        var root = Self.metadata()
        Self.insert("#FF0000", at: ["editor", "syntax", "keyword"], into: &root)
        Self.insert("#00000080", at: ["dataGrid", "background"], into: &root)

        let colors = try Self.document(root).colors.mapValues { $0.hex }

        #expect(colors == [.syntaxKeyword: "#FF0000", .gridBackground: "#00000080"])
    }

    @Test("Every slot path is accepted")
    func everySlotPathLoads() throws {
        var root = Self.metadata()
        for slot in ThemeSlot.allCases {
            Self.insert("#123456", at: slot.rawValue.components(separatedBy: "."), into: &root)
        }

        #expect(try Self.document(root).colors.count == ThemeSlot.allCases.count)
    }

    // MARK: - What is refused

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
        let rejected = [
            "#FF79CG",
            "FF0000",
            "#FFF",
            "#FF00000",
            "",
            "system:label",
            "#\u{FF26}\u{FF26}0000",
        ]

        for value in rejected {
            let error = try Self.refusal(Self.withColor(value, at: ["editor", "background"]))
            #expect(error == .invalidColor(value), "\(value)")
        }
    }

    @Test("An 8-digit color keeps its alpha")
    func alphaColorIsAccepted() throws {
        let colors = try Self.document(Self.withColor("#ff79c680", at: ["editor", "selection"])).colors
        let color = try #require(colors[.editorSelection])

        #expect(color.hex == "#FF79C680")
        #expect(abs(color.nsColor.alphaComponent - CGFloat(0x80) / 255) < 0.001)
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
    }

    @Test("Missing metadata is refused by name")
    func missingMetadataIsRefused() throws {
        for key in ["id", "name", "appearance"] {
            var root = Self.metadata()
            root.removeValue(forKey: key)
            #expect(try Self.refusal(root) == .missingField(key), "\(key)")
        }

        var unknownAppearance = Self.metadata()
        unknownAppearance["appearance"] = "sepia"
        #expect(try Self.refusal(unknownAppearance) == .missingField("appearance"))
    }

    @Test("An id that is not a plain file-safe name is refused")
    func invalidIdIsRefused() throws {
        for id in ["user/evil", "../escape", "user..x", "user x", "user.\u{00E9}"] {
            #expect(try Self.refusal(Self.metadata(id: id)) == .invalidIdentifier(id), "\(id)")
        }
    }

    // MARK: - Encoder

    @Test("The encoder writes metadata and the overrides, nothing else")
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

        let object = try JSONSerialization.jsonObject(with: try ThemeEncoder.data(for: theme))
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

    @Test("A default theme encodes as syntax only")
    func defaultThemeEncodesSyntaxOnly() throws {
        let object = try JSONSerialization.jsonObject(with: try ThemeEncoder.data(for: BuiltInThemes.light))
        let root = try #require(object as? [String: Any])
        let editor = try #require(root["editor"] as? [String: Any])

        #expect(root["dataGrid"] == nil)
        #expect(Set(editor.keys) == ["syntax"])
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

        for theme in [full, sparse, BuiltInThemes.light, BuiltInThemes.dark] {
            let reread = try ThemeDocument(data: try ThemeEncoder.data(for: theme)).definition()
            #expect(reread == theme, "\(theme.id)")
        }
    }
}
