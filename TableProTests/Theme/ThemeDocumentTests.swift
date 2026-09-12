//
//  ThemeDocumentTests.swift
//  TableProTests
//
//  The previous decoder read every key with `decodeIfPresent` and a Default Light fallback, so an
//  empty object and a VS Code theme both decoded "successfully" and rendered as Default Light under
//  the file's own name. These pin the gate that replaced it.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Theme document gate")
struct ThemeDocumentTests {
    private static func json(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func completeTheme(appearance: ThemeAppearance = .dark) -> [String: Any] {
        var root: [String: Any] = [
            "schema": ThemeSchema.current,
            "id": "user.test",
            "name": "Test",
            "author": "Tests",
            "appearance": appearance.rawValue,
        ]

        for slot in ThemeSlot.allCases {
            var cursor = root
            insert(slot.rawValue.components(separatedBy: "."), value: "#112233", into: &cursor)
            root = cursor
        }

        return root
    }

    private static func insert(_ path: [String], value: String, into container: inout [String: Any]) {
        guard let head = path.first else { return }
        guard path.count > 1 else {
            container[head] = value
            return
        }
        var child = container[head] as? [String: Any] ?? [:]
        insert(Array(path.dropFirst()), value: value, into: &child)
        container[head] = child
    }

    @Test("A complete document decodes")
    func completeDocumentDecodes() throws {
        let document = try ThemeDocument(data: Self.json(Self.completeTheme()))
        #expect(document.id == "user.test")
        #expect(document.appearance == .dark)
        #expect(document.colors.count == ThemeSlot.allCases.count)
    }

    @Test("An empty object is rejected")
    func emptyObjectIsRejected() {
        #expect(throws: ThemeLoadError.missingSchema) {
            try ThemeDocument(data: Self.json([:]))
        }
    }

    @Test("A file in the old format is rejected")
    func oldSchemaIsRejected() {
        let old: [String: Any] = [
            "version": 1,
            "id": "user.old",
            "name": "Old",
            "appearance": "dark",
            "editor": ["background": "#000000"],
        ]

        #expect(throws: ThemeLoadError.missingSchema) {
            try ThemeDocument(data: Self.json(old))
        }
    }

    @Test("A schema from a newer TablePro is rejected")
    func newerSchemaIsRejected() {
        var root = Self.completeTheme()
        root["schema"] = ThemeSchema.current + 1

        #expect(throws: ThemeLoadError.schemaTooNew(found: ThemeSchema.current + 1, supported: ThemeSchema.current)) {
            try ThemeDocument(data: Self.json(root))
        }
    }

    @Test("A missing slot is reported, not filled in silently")
    func missingSlotIsRejected() throws {
        var root = Self.completeTheme()
        var content = try #require(root["content"] as? [String: Any])
        var editor = try #require(content["editor"] as? [String: Any])
        editor.removeValue(forKey: "cursor")
        content["editor"] = editor
        root["content"] = content

        #expect(throws: ThemeLoadError.missingSlots([ThemeSlot.editorCursor.rawValue])) {
            try ThemeDocument(data: Self.json(root))
        }
    }

    @Test("A key TablePro does not use is reported")
    func unknownKeyIsRejected() throws {
        var root = Self.completeTheme()
        var content = try #require(root["content"] as? [String: Any])
        content["sidebar"] = ["background": "#000000"]
        root["content"] = content

        #expect(throws: ThemeLoadError.unknownKeys(["content.sidebar.background"])) {
            try ThemeDocument(data: Self.json(root))
        }
    }

    /// A valid prefix used to satisfy the parser, so `#FF79CG` rendered as `#0FF79C` with nothing
    /// logged and nothing shown.
    @Test("A color with a typo in it is rejected")
    func malformedColorIsRejected() throws {
        var root = Self.completeTheme()
        var content = try #require(root["content"] as? [String: Any])
        var editor = try #require(content["editor"] as? [String: Any])
        editor["background"] = "#FF79CG"
        content["editor"] = editor
        root["content"] = content

        #expect(throws: ThemeLoadError.invalidColor("#FF79CG")) {
            try ThemeDocument(data: Self.json(root))
        }
    }

    @Test("An unknown system color name is rejected")
    func unknownSystemColorIsRejected() throws {
        var root = Self.completeTheme()
        var content = try #require(root["content"] as? [String: Any])
        var editor = try #require(content["editor"] as? [String: Any])
        editor["background"] = "system:notARealColor"
        content["editor"] = editor
        root["content"] = content

        #expect(throws: ThemeLoadError.unknownSystemColor("notARealColor")) {
            try ThemeDocument(data: Self.json(root))
        }
    }

    @Test("A system color reference round-trips")
    func systemColorRoundTrips() throws {
        var root = Self.completeTheme()
        var content = try #require(root["content"] as? [String: Any])
        var editor = try #require(content["editor"] as? [String: Any])
        editor["background"] = "system:textBackground"
        content["editor"] = editor
        root["content"] = content

        let theme = try ThemeDocument(data: Self.json(root)).resolved()
        #expect(theme.editor.background == .system(.textBackground))

        let reread = try ThemeDocument(data: ThemeEncoder.data(for: theme)).resolved()
        #expect(reread.editor.background == .system(.textBackground))
    }

    @Test("Every slot round-trips through the encoder")
    func everySlotRoundTrips() throws {
        let theme = try ThemeDocument(data: Self.json(Self.completeTheme())).resolved()
        let reread = try ThemeDocument(data: ThemeEncoder.data(for: theme)).resolved()

        for slot in ThemeSlot.allCases {
            #expect(reread[keyPath: slot.keyPath] == theme[keyPath: slot.keyPath], "\(slot.rawValue)")
        }
    }

    @Test("Hex parsing consumes the whole string")
    func hexParsingIsStrict() {
        #expect(HexColor.canonicalize("#ff79c6") == "#FF79C6")
        #expect(HexColor.canonicalize("#FF79C680") == "#FF79C680")
        #expect(HexColor.canonicalize("#FF79CG") == nil)
        #expect(HexColor.canonicalize("FF79C6") == nil)
        #expect(HexColor.canonicalize("#FFF") == nil)
        #expect(HexColor.canonicalize("") == nil)
    }
}
