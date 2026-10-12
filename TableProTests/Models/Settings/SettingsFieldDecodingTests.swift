//
//  SettingsFieldDecodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SettingsFieldDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("A bad General value falls back alone and the rest of General loads")
    func generalKeepsOtherFields() throws {
        let settings = try decode(
            GeneralSettings.self,
            #"{"startupBehavior":"showWelcome","language":"xx","queryTimeoutSeconds":"ninety","showObjectIcons":false}"#
        )
        #expect(settings.language == .system)
        #expect(settings.queryTimeoutSeconds == GeneralSettings.default.queryTimeoutSeconds)
        #expect(settings.startupBehavior == .showWelcome)
        #expect(settings.showObjectIcons == false)
    }

    @Test("General without the startup key still loads the rest")
    func generalWithoutStartupBehavior() throws {
        let settings = try decode(GeneralSettings.self, #"{"queryTimeoutSeconds":120}"#)
        #expect(settings.startupBehavior == GeneralSettings.default.startupBehavior)
        #expect(settings.queryTimeoutSeconds == 120)
    }

    @Test("A bad Editor value falls back alone")
    func editorKeepsOtherFields() throws {
        let settings = try decode(
            EditorSettings.self,
            #"{"tabWidth":"four","wordWrap":true,"vimModeEnabled":true,"jsonViewerPreferredMode":"graph"}"#
        )
        #expect(settings.tabWidth == EditorSettings.default.tabWidth)
        #expect(settings.jsonViewerPreferredMode == EditorSettings.default.jsonViewerPreferredMode)
        #expect(settings.wordWrap == true)
        #expect(settings.vimModeEnabled == true)
    }

    @Test("A bad Data Grid value falls back alone")
    func dataGridKeepsOtherFields() throws {
        let settings = try decode(DataGridSettings.self, #"{"rowHeight":99,"nullDisplay":"(null)","showRowNumbers":false}"#)
        #expect(settings.rowHeight == DataGridSettings.default.rowHeight)
        #expect(settings.nullDisplay == "(null)")
        #expect(settings.showRowNumbers == false)
    }

    @Test("A bad MCP value falls back alone and keeps the secure default")
    func mcpKeepsOtherFields() throws {
        let settings = try decode(
            MCPSettings.self,
            #"{"enabled":true,"port":24000,"requireAuthentication":"no","connectionApproval":"whenever"}"#
        )
        #expect(settings.enabled == true)
        #expect(settings.port == 24_000)
        #expect(settings.requireAuthentication == true)
        #expect(settings.connectionApproval == MCPSettings.default.connectionApproval)
    }

    @Test("Sync settings missing a field load the fields they have")
    func syncKeepsOtherFields() throws {
        let settings = try decode(SyncSettings.self, #"{"enabled":true,"syncPasswords":true}"#)
        #expect(settings.enabled == true)
        #expect(settings.syncPasswords == true)
        #expect(settings.syncConnections == SyncSettings.default.syncConnections)
    }

    @Test("A bad notification kind entry is dropped and the rest are kept")
    func notificationsDropBadKindEntry() throws {
        let settings = try decode(
            NotificationSettings.self,
            #"{"isEnabled":false,"thresholdSeconds":45,"disabledKindIds":["export",7,"import"]}"#
        )
        #expect(settings.isEnabled == false)
        #expect(settings.thresholdSeconds == 45)
        #expect(settings.disabledKindIds == ["export", "import"])
    }

    @Test("A bad shortcut entry is dropped and the other shortcuts are kept")
    func keyboardDropsBadEntry() throws {
        let json = """
        {"shortcuts":{
            "saveChanges":{"keyCode":1,"command":true,"shift":false,"option":false,"control":false},
            "refresh":{"keyCode":"F5"}
        }}
        """
        let settings = try decode(KeyboardSettings.self, json)
        #expect(settings.shortcuts.count == 1)
        #expect(settings.shortcuts[ShortcutAction.saveChanges.rawValue] == BoundKey(keyCode: 1, command: true))
    }

    @Test("A blob that is not an object still fails, so storage and sync can report it")
    func nonObjectBlobStillFails() {
        #expect(throws: DecodingError.self) {
            _ = try decode(AISettings.self, #"["not","settings"]"#)
        }
    }
}

struct AISettingsProviderDecodingTests {
    private let keptID = UUID()
    private let otherID = UUID()

    private func decode(_ json: String) throws -> AISettings {
        try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
    }

    @Test("A provider row of a type this build does not know is dropped and the rest load")
    func unknownProviderTypeIsDropped() throws {
        let json = """
        {
            "enabled": false,
            "activeProviderID": "\(keptID.uuidString)",
            "maxSchemaTables": 42,
            "providers": [
                {"id": "\(UUID().uuidString)", "type": "someRemovedProvider", "name": "Gone"},
                {"id": "\(keptID.uuidString)", "type": "claude", "name": "Work", "model": "m1"},
                {"id": "\(otherID.uuidString)", "type": "openAI"}
            ]
        }
        """
        let settings = try decode(json)
        #expect(settings.providers.map(\.id) == [keptID, otherID])
        #expect(settings.activeProvider?.name == "Work")
        #expect(settings.activeProvider?.model == "m1")
        #expect(settings.enabled == false)
        #expect(settings.maxSchemaTables == 42)
    }

    @Test("A stored Cursor provider row is dropped and the rest of AI settings load")
    func removedCursorRowIsDropped() throws {
        let json = """
        {
            "inlineSuggestionsEnabled": true,
            "activeProviderID": "\(otherID.uuidString)",
            "providers": [
                {"id": "\(otherID.uuidString)", "type": "cursor", "name": "Cursor"},
                {"id": "\(keptID.uuidString)", "type": "xai"}
            ]
        }
        """
        let settings = try decode(json)
        #expect(settings.providers.map(\.id) == [keptID])
        #expect(settings.providers.first?.type == .xai)
        #expect(settings.activeProvider == nil)
        #expect(settings.inlineSuggestionsEnabled == true)
    }

    @Test("A provider row without an id is dropped")
    func rowWithoutIDIsDropped() throws {
        let json = """
        {"providers": [{"type": "claude"}, {"id": "\(keptID.uuidString)", "type": "gemini"}]}
        """
        #expect(try decode(json).providers.map(\.id) == [keptID])
    }

    @Test("A bad optional field keeps its provider row")
    func badOptionalFieldKeepsRow() throws {
        let json = """
        {"providers": [{"id": "\(keptID.uuidString)", "type": "openAI", "reasoningEffort": "extreme", "maxOutputTokens": "lots"}]}
        """
        let provider = try #require(try decode(json).providers.first)
        #expect(provider.id == keptID)
        #expect(provider.reasoningEffort == nil)
        #expect(provider.maxOutputTokens == nil)
        #expect(provider.endpoint == AIProviderType.openAI.defaultEndpoint)
    }

    @Test("A bad AI value falls back alone")
    func badAIValueKeepsOtherFields() throws {
        let settings = try decode(#"{"chatMode":"autopilot","includeQueryResults":true,"providers":"none"}"#)
        #expect(settings.chatMode == AISettings.default.chatMode)
        #expect(settings.includeQueryResults == true)
        #expect(settings.providers.isEmpty)
    }

    @Test("Storage loads the AI category around an unknown provider row")
    func storageLoadsAroundUnknownRow() throws {
        let defaults = try #require(UserDefaults(suiteName: "settings-decode-\(UUID().uuidString)"))
        let storage = AppSettingsStorage(userDefaults: defaults)
        var stored = AISettings.default
        stored.enabled = false
        stored.providers = [AIProviderConfig(id: keptID, name: "Kept", type: .claude)]
        stored.activeProviderID = keptID
        storage.saveAI(stored)

        let key = "com.TablePro.settings.ai"
        let blob = try #require(defaults.data(forKey: key))
        var object = try #require(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
        var providers = try #require(object["providers"] as? [[String: Any]])
        providers.insert(["id": UUID().uuidString, "type": "someRemovedProvider"], at: 0)
        object["providers"] = providers
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)

        let loaded = storage.loadAI()
        #expect(loaded.enabled == false)
        #expect(loaded.providers.map(\.id) == [keptID])
        #expect(loaded.activeProviderID == keptID)
    }
}
