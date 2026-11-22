//
//  ConnectionEditorEngineEditsTests.swift
//  TableProTests
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorEngineEditsTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func filledSecrets(_ draft: inout ConnectionDraft, _ traits: ConnectionTypeTraits) {
        for field in traits.fields where field.isSecure {
            draft.fieldValues[field.id] = "secret-\(field.id)"
        }
        draft.fieldValues[ConnectionSecretOptions.mongoSessionTokenFieldId] = "session-token"
    }

    @Test("No secure value of the current or the original type reaches the record, for every type and retype")
    func secureValuesNeverReachTheRecord() {
        let types = DatabaseType.allKnownTypes
        let all = Dictionary(uniqueKeysWithValues: types.map { ($0, traits($0)) })
        for type in types {
            guard let current = all[type] else { continue }
            var draft = ConnectionDraft.new(type: type, traits: current)
            filledSecrets(&draft, current)
            let forbidden = ConnectionEditorEngine.secretFieldIds(current, originalTraits: nil)
            let edits = ConnectionEditorEngine.edits(draft, current, originalTraits: nil, EditorContext())
            #expect(Set(edits.additionalFields.keys).isDisjoint(with: forbidden), "\(type.rawValue)")
            #expect(!edits.additionalFields.values.contains { $0.hasPrefix("secret-") || $0 == "session-token" })
        }
        for original in types {
            guard let originalTraits = all[original] else { continue }
            var draft = ConnectionDraft.new(type: original, traits: originalTraits)
            filledSecrets(&draft, originalTraits)
            for target in types where target != original {
                guard let targetTraits = all[target] else { continue }
                let retyped = draft.retyped(to: targetTraits, from: originalTraits).result
                let edits = ConnectionEditorEngine.edits(retyped, targetTraits, originalTraits: originalTraits, EditorContext())
                #expect(
                    !edits.additionalFields.values.contains { $0.hasPrefix("secret-") || $0 == "session-token" },
                    "\(original.rawValue) to \(target.rawValue)"
                )
            }
        }
    }

    @Test("A stored connection loads and writes back unchanged")
    func loadThenEditsRoundTrips() {
        var connection = DatabaseConnection(
            name: "Orders",
            host: "db.example.com",
            port: 6_543,
            database: "orders",
            username: "app",
            type: .postgresql
        )
        connection.color = .green
        connection.tagIds = [UUID()]
        connection.connectTimeoutSeconds = 12
        connection.commitMode = .manual
        connection.additionalFields[ConnectionEnvironment.fieldKey] = ConnectionEnvironment.production.rawValue
        connection.additionalFields["mongoParam_directConnection"] = "true"
        let postgres = traits(.postgresql)
        let draft = ConnectionDraft.loaded(from: connection, secrets: .none, traits: postgres)
        #expect(draft.environment == .production)
        let edits = ConnectionEditorEngine.edits(draft, postgres, originalTraits: postgres, EditorContext())
        let saved = edits.applied(to: connection)
        #expect(saved.name == connection.name)
        #expect(saved.host == connection.host)
        #expect(saved.port == connection.port)
        #expect(saved.database == connection.database)
        #expect(saved.username == connection.username)
        #expect(saved.color == connection.color)
        #expect(saved.tagIds == connection.tagIds)
        #expect(saved.connectTimeoutSeconds == 12)
        #expect(saved.commitMode == .manual)
        #expect(saved.additionalFields["mongoParam_directConnection"] == "true")
        #expect(saved.additionalFields[ConnectionEnvironment.fieldKey] == ConnectionEnvironment.production.rawValue)
    }

    @Test("A record moved to a throwaway id keeps every other stored property")
    func reassignedRecordKeepsEverything() {
        var connection = DatabaseConnection(name: "Orders", type: .postgresql)
        connection.sortOrder = 4
        connection.isFavorite = true
        connection.isSample = true
        connection.aiAlwaysAllowedTools = ["run_query"]
        connection.passwordSource = .env(variable: "PGPASSWORD")
        connection.origin = .imported
        connection.additionalFields["custom"] = "kept"
        let testId = UUID()
        let moved = ConnectionEditorEngine.record(connection, reassignedTo: testId)
        #expect(moved.id == testId)
        let labels = Mirror(reflecting: connection).children.compactMap(\.label).filter { $0 != "id" }
        let original = Dictionary(uniqueKeysWithValues: Mirror(reflecting: connection).children.compactMap { child in
            child.label.map { ($0, String(describing: child.value)) }
        })
        let copy = Dictionary(uniqueKeysWithValues: Mirror(reflecting: moved).children.compactMap { child in
            child.label.map { ($0, String(describing: child.value)) }
        })
        for label in labels {
            #expect(original[label] == copy[label], "\(label)")
        }
    }

    @Test("A name or color edit leaves a test result standing; a host edit does not")
    func testFingerprintCoversOnlyWhatATestTouches() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.host = "db.example.com"
        let tested = ConnectionEditorEngine.testFingerprint(draft, postgres, originalTraits: nil, EditorContext())
        var renamed = draft
        renamed.name = "Renamed"
        renamed.appearance.color = .red
        #expect(ConnectionEditorEngine.testFingerprint(renamed, postgres, originalTraits: nil, EditorContext()) == tested)
        var moved = draft
        moved.host = "other.example.com"
        #expect(ConnectionEditorEngine.testFingerprint(moved, postgres, originalTraits: nil, EditorContext()) != tested)
        var newPassword = draft
        newPassword.credentials.password = "changed"
        #expect(ConnectionEditorEngine.testFingerprint(newPassword, postgres, originalTraits: nil, EditorContext()) != tested)
    }
}
