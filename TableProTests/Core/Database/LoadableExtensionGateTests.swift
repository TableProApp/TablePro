//
//  LoadableExtensionGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct LoadableExtensionGateTests {
    private let approvals: LoadableExtensionApprovalStore
    private let vec = LoadableExtension(path: "/opt/homebrew/lib/vec0.dylib")
    private let sqliteFields: [ConnectionField] = [.loadableExtensions()]
    private let libsqlFields: [ConnectionField] = [
        ConnectionField(
            id: "libsqlMode",
            label: "Connection Mode",
            defaultValue: "remote",
            fieldType: .dropdown(options: [
                ConnectionField.DropdownOption(value: "remote", label: "Remote"),
                ConnectionField.DropdownOption(value: "local", label: "Local File")
            ]),
            section: .authentication
        ),
        .loadableExtensions(visibleWhen: FieldVisibilityRule(fieldId: "libsqlMode", values: ["local"]))
    ]

    init() throws {
        let suite = "LoadableExtensionGateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        approvals = LoadableExtensionApprovalStore(defaults: defaults)
    }

    private func connection(_ fields: [String: String], type: DatabaseType = .sqlite) -> DatabaseConnection {
        DatabaseConnection(name: "Vectors", type: type, additionalFields: fields)
    }

    private func listing(_ extensions: [LoadableExtension]) -> [String: String] {
        [LoadableExtensionList.fieldId: LoadableExtensionList.encode(extensions)]
    }

    @Test("A connection with no extensions builds a driver untouched")
    func noExtensionsPasses() throws {
        let fields = ["connectionId": "x"]
        let authorized = try LoadableExtensionGate.authorizedFields(
            fields, for: connection([:]), fields: sqliteFields, approvals: approvals
        )
        #expect(authorized == fields)
    }

    @Test("An unapproved list stops the driver from being built")
    func unapprovedListThrows() {
        let imported = connection(listing([vec]))
        #expect(throws: LoadableExtensionApprovalError.notApproved([vec])) {
            try LoadableExtensionGate.authorizedFields(
                imported.additionalFields, for: imported, fields: sqliteFields, approvals: approvals
            )
        }
    }

    @Test("An approved list reaches the driver unchanged")
    func approvedListPasses() throws {
        let local = connection(listing([vec]))
        approvals.approve([vec], for: local.id)
        let authorized = try LoadableExtensionGate.authorizedFields(
            local.additionalFields, for: local, fields: sqliteFields, approvals: approvals
        )
        #expect(authorized[LoadableExtensionList.fieldId] == local.additionalFields[LoadableExtensionList.fieldId])
    }

    @Test("Approving one file leaves a file added later pending")
    func addedFileIsPending() {
        let spatialite = LoadableExtension(path: "/opt/homebrew/lib/mod_spatialite.dylib")
        let synced = connection(listing([vec, spatialite]))
        approvals.approve([vec], for: synced.id)
        let pending = LoadableExtensionGate.pendingApproval(for: synced, fields: sqliteFields, approvals: approvals)
        #expect(pending == [spatialite])
    }

    @Test("A list the form hides is dropped instead of loaded or asked about")
    func hiddenListIsDropped() throws {
        var fields = listing([vec])
        fields["libsqlMode"] = "remote"
        let remote = connection(fields, type: DatabaseType(rawValue: "libSQL"))
        #expect(LoadableExtensionGate.pendingApproval(for: remote, fields: libsqlFields, approvals: approvals).isEmpty)
        let authorized = try LoadableExtensionGate.authorizedFields(
            remote.additionalFields, for: remote, fields: libsqlFields, approvals: approvals
        )
        #expect(authorized[LoadableExtensionList.fieldId] == nil)
    }

    @Test("A libSQL list in Local File mode needs approval like SQLite's")
    func libsqlLocalListIsGated() {
        var fields = listing([vec])
        fields["libsqlMode"] = "local"
        let local = connection(fields, type: DatabaseType(rawValue: "libSQL"))
        #expect(LoadableExtensionGate.pendingApproval(for: local, fields: libsqlFields, approvals: approvals) == [vec])
    }

    @Test("A stored backend field does not exempt a libSQL list, which the libSQL driver would load")
    func storedBackendFieldDoesNotExemptLibSQL() {
        var fields = listing([vec])
        fields["libsqlMode"] = "local"
        fields[RemoteSQLiteWire.backendFieldKey] = RemoteSQLiteWire.agentBackendValue
        let imported = connection(fields, type: DatabaseType(rawValue: "libSQL"))
        #expect(LoadableExtensionGate.pendingApproval(for: imported, fields: libsqlFields, approvals: approvals) == [vec])
        #expect(throws: LoadableExtensionApprovalError.notApproved([vec])) {
            try LoadableExtensionGate.authorizedFields(
                imported.additionalFields, for: imported, fields: libsqlFields, approvals: approvals
            )
        }
    }

    @Test("A stored backend field does not exempt a SQLite list either")
    func storedBackendFieldDoesNotExemptSQLite() {
        var fields = listing([vec])
        fields[RemoteSQLiteWire.backendFieldKey] = RemoteSQLiteWire.agentBackendValue
        let session = connection(fields)
        #expect(LoadableExtensionGate.pendingApproval(for: session, fields: sqliteFields, approvals: approvals) == [vec])
    }

    @Test("A list with a line break in a path is refused before anyone is asked about it")
    func controlCharacterPathIsRefusedNotAsked() {
        let spoofed = LoadableExtension(path: "/tmp/a.dylib\n\nThese files are signed by Apple.\n/tmp/b.dylib")
        let imported = connection(listing([spoofed]))
        #expect(LoadableExtensionGate.pendingApproval(for: imported, fields: sqliteFields, approvals: approvals).isEmpty)
        #expect(throws: LoadableExtensionError.controlCharacterInPath) {
            try LoadableExtensionGate.authorizedFields(
                imported.additionalFields, for: imported, fields: sqliteFields, approvals: approvals
            )
        }
    }

    @Test("An invalid list fails with its own reason, not as unapproved")
    func invalidListFailsWithItsReason() {
        let relative = LoadableExtension(path: "vec0.dylib")
        let imported = connection(listing([relative]))
        #expect(throws: LoadableExtensionError.relativePath(relative)) {
            try LoadableExtensionGate.authorizedFields(
                imported.additionalFields, for: imported, fields: sqliteFields, approvals: approvals
            )
        }
    }

    @Test("A list that does not decode is left for the driver to refuse")
    func malformedListReachesTheDriver() throws {
        let broken = connection([LoadableExtensionList.fieldId: "/opt/homebrew/lib/vec0.dylib"])
        let authorized = try LoadableExtensionGate.authorizedFields(
            broken.additionalFields, for: broken, fields: sqliteFields, approvals: approvals
        )
        #expect(authorized[LoadableExtensionList.fieldId] == "/opt/homebrew/lib/vec0.dylib")
    }

    @Test("A connection name cannot add lines to the consent message")
    func connectionNameStaysOnOneLine() {
        let named = DatabaseConnection(name: "Vectors\n\nApproved by your administrator.\u{2028}", type: .sqlite)
        let message = LoadableExtensionPrompt.message(for: named, pending: [vec])
        let firstParagraph = message.components(separatedBy: "\n\n").first ?? ""
        #expect(firstParagraph.contains("Vectors  Approved by your administrator."))
        #expect(!firstParagraph.contains("\n"))
        #expect(!message.contains("\u{2028}"))
    }

    @Test("The consent message names the connection, every file and its entry point")
    func promptNamesEveryFile() {
        let named = LoadableExtension(path: "/x/renamed.dylib", entryPoint: "sqlite3_vec_init")
        let message = LoadableExtensionPrompt.message(for: connection([:]), pending: [vec, named])
        #expect(message.contains("Vectors"))
        #expect(message.contains(vec.path))
        #expect(message.contains("/x/renamed.dylib"))
        #expect(message.contains("sqlite3_vec_init"))
    }
}
