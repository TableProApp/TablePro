import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncSettingsUnreadOptionsTests {
    private static let zoneID = SyncTestEnvironment.zoneID
    private static let editor = AppSettingsCategory.editor

    private static func encoded(_ settings: EditorSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(settings)
    }

    // The document a newer build writes: this build's options plus one it has no field for.
    private static func newerDocument(_ settings: EditorSettings, futureOption: String = "kept") throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: encoded(settings)) as? [String: Any])
        object["futureOption"] = futureOption
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func document(of record: CKRecord) throws -> [String: Any] {
        let data = try #require(SyncRecordMapper.settingsData(from: record))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func record(_ data: Data) -> CKRecord {
        SyncRecordMapper.toCKRecord(category: editor, settingsData: data, in: zoneID)
    }

    @Test("A push keeps an option a newer build wrote into the record it builds on")
    func pushKeepsAnOptionThisBuildCannotRead() throws {
        let base = Self.record(try Self.newerDocument(.default))

        let edit = SyncRecordMapper.settingsEdit(
            category: Self.editor,
            settingsData: try Self.encoded(EditorSettings(tabWidth: 2)),
            in: Self.zoneID,
            base: base
        )

        let pushed = try Self.document(of: edit.record)
        #expect(pushed["futureOption"] as? String == "kept")
        #expect(pushed["tabWidth"] as? Int == 2)
    }

    @Test("A settings category this build did not change is no edit when the record holds an option it cannot read")
    func unreadOptionAloneIsNoEdit() throws {
        let base = Self.record(try Self.newerDocument(.default))

        let edit = SyncRecordMapper.settingsEdit(
            category: Self.editor,
            settingsData: try Self.encoded(.default),
            in: Self.zoneID,
            base: base
        )

        #expect(edit.changesContent == false)
    }

    @Test("A push merged over another Mac's change keeps the option a newer build wrote")
    func mergedPushKeepsAnOptionThisBuildCannotRead() throws {
        let base = Self.record(try Self.newerDocument(.default))
        let server = try #require(base.copy() as? CKRecord)
        server.fields(AppSettingsSyncField.self)[.settingsJson] = try Self.newerDocument(EditorSettings(wordWrap: true))

        let edit = SyncRecordMapper.settingsEdit(
            category: Self.editor,
            settingsData: try Self.encoded(EditorSettings(tabWidth: 2)),
            in: Self.zoneID,
            base: base
        )

        let merged = try Self.document(of: try #require(edit.rebased(onto: server)))
        #expect(merged["futureOption"] as? String == "kept")
        #expect(merged["tabWidth"] as? Int == 2)
        #expect(merged["wordWrap"] as? Bool == true)
    }

    @Test("A push with no cached record that meets the server's copy keeps the option a newer build wrote there")
    func uncachedPushKeepsTheServersUnreadOption() throws {
        let server = Self.record(try Self.newerDocument(.default, futureOption: "on the server"))

        let edit = SyncRecordMapper.settingsEdit(
            category: Self.editor,
            settingsData: try Self.encoded(EditorSettings(tabWidth: 2)),
            in: Self.zoneID,
            base: nil
        )

        let rebased = try Self.document(of: try #require(edit.rebased(onto: server)))
        #expect(rebased["futureOption"] as? String == "on the server")
        #expect(rebased["tabWidth"] as? Int == 2)
    }

    @Test("An option this build reads takes this Mac's value, not the record's")
    func readableOptionFollowsThisMac() throws {
        let base = Self.record(try Self.newerDocument(EditorSettings(keyBindings: .vim)))

        let edit = SyncRecordMapper.settingsEdit(
            category: Self.editor,
            settingsData: try Self.encoded(EditorSettings(keyBindings: .standard)),
            in: Self.zoneID,
            base: base
        )

        let pushed = try Self.document(of: edit.record)
        #expect(pushed["keyBindings"] as? String == EditorKeyBindings.standard.rawValue)
        #expect(pushed["vimModeEnabled"] as? Bool == false)
    }

    @Test("A sync run sends this Mac's settings change with the option a newer build wrote")
    func syncRunCarriesTheUnreadOption() async throws {
        let environment = try SyncTestEnvironment(label: "sync-settings-unread-options")
        let cached = Self.record(try Self.newerDocument(.default))
        environment.recordCache.store([cached])
        AppSettingsStorage(userDefaults: environment.defaults).saveEditor(EditorSettings(tabWidth: 2))
        environment.tracker.markDirty(.settings, ids: [Self.editor])
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID)

        _ = await environment.makeCoordinator(transport: transport).runSyncCycle()

        let pushed = try #require(await transport.pushedRecords.last { $0.recordID == cached.recordID })
        let document = try Self.document(of: pushed)
        #expect(document["futureOption"] as? String == "kept")
        #expect(document["tabWidth"] as? Int == 2)
    }
}
