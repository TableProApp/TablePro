//
//  EditorSettingsKeyBindingsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// Editor settings sync as one JSON blob, so an older build on another Mac still reads `vimModeEnabled`.
struct EditorSettingsKeyBindingsTests {
    private func decode(_ json: String) throws -> EditorSettings {
        try JSONDecoder().decode(EditorSettings.self, from: Data(json.utf8))
    }

    private func encodedObject(_ settings: EditorSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Vim mode saved by an older build reads as Vim key bindings")
    func legacyVimSwitchMigrates() throws {
        #expect(try decode(#"{"vimModeEnabled": true}"#).keyBindings == .vim)
        #expect(try decode(#"{"vimModeEnabled": false}"#).keyBindings == .standard)
        #expect(try decode("{}").keyBindings == .standard)
    }

    @Test("The key bindings value wins over the legacy switch beside it")
    func newKeyWins() throws {
        #expect(try decode(#"{"keyBindings": "emacs", "vimModeEnabled": false}"#).keyBindings == .emacs)
    }

    @Test("A key bindings value this build does not know falls back to the legacy switch")
    func unknownValueFallsBack() throws {
        #expect(try decode(#"{"keyBindings": "helix", "vimModeEnabled": true}"#).keyBindings == .vim)
    }

    @Test("Encoding writes the key bindings and the Vim switch an older build reads")
    func encodesBothKeys() throws {
        var settings = EditorSettings.default
        settings.keyBindings = .emacs
        let emacs = try encodedObject(settings)
        #expect(emacs["keyBindings"] as? String == "emacs")
        #expect(emacs["vimModeEnabled"] as? Bool == false)

        settings.keyBindings = .vim
        let vim = try encodedObject(settings)
        #expect(vim["keyBindings"] as? String == "vim")
        #expect(vim["vimModeEnabled"] as? Bool == true)
        #expect(try decode(String(decoding: JSONEncoder().encode(settings), as: UTF8.self)).keyBindings == .vim)
    }
}
