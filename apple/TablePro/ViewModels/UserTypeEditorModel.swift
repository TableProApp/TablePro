//
//  UserTypeEditorModel.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os
import TableProPluginKit

/// Which changes the connection's driver can make to one loaded type, read from the driver's own
/// statement hooks so the editor never offers a change it has no statement for.
struct UserTypeEditSupport: Equatable {
    var rename = false
    var comment = false
    var addLabel = false
    var placeLabel = false
    var renameLabel = false
    var setDefault = false
    var setNotNull = false
    var addCheck = false
    var addUnvalidatedCheck = false
    var dropConstraint = false
    var validateConstraint = false
    var addField = false
    var dropField = false
    var renameField = false
    var changeFieldType = false

    static let none = UserTypeEditSupport()

    var isEditable: Bool { self != .none }

    @MainActor
    static func of(_ driver: DatabaseDriver?, type: UserDefinedTypeInfo) -> UserTypeEditSupport {
        guard let driver else { return .none }
        func can(_ change: PluginUserDefinedTypeChange) -> Bool {
            driver.alterUserDefinedTypeStatements(type: type, change: change) != nil
        }
        let check = PluginUserDefinedTypeCheck(name: "c", expression: "true")
        let field = PluginUserDefinedTypeField(name: "f", type: "integer")
        return UserTypeEditSupport(
            rename: can(.rename(to: "t")),
            comment: can(.setComment("c")),
            addLabel: can(.addEnumLabel("l", placement: nil)),
            placeLabel: can(.addEnumLabel("l", placement: PluginEnumLabelPlacement(anchor: "a", placesBefore: true))),
            renameLabel: can(.renameEnumLabel(from: "a", to: "b")),
            setDefault: can(.setDefault("0")),
            setNotNull: can(.setNotNull(true)),
            addCheck: can(.addCheck(check, validatesExistingValues: true)),
            addUnvalidatedCheck: can(.addCheck(check, validatesExistingValues: false)),
            dropConstraint: can(.dropConstraint("c")),
            validateConstraint: can(.validateConstraint("c")),
            addField: can(.addField(field)),
            dropField: can(.dropField("f")),
            renameField: can(.renameField(from: "f", to: "g")),
            changeFieldType: can(.changeFieldType(field: "f", type: "bigint"))
        )
    }
}

/// A save built on a copy the server has moved past would name the type as it was.
struct StaleTypeError: LocalizedError {
    var errorDescription: String? {
        String(localized: "The type changed on the server since it was read. Reload it, then save again.")
    }
}

/// The queued changes of one type's tab. Kept by the coordinator per tab, so they outlive the view,
/// a tab switch and a connection switch, and the close prompt can see and save them.
@MainActor
final class UserTypeEditorModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "UserTypeEditor")

    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var serverType: UserDefinedTypeInfo?
    @Published private(set) var changes: [StagedTypeChange] = []
    /// What the server answered for a change, by change id. Cleared when that change is edited.
    @Published private(set) var serverErrors: [UUID: String] = [:]
    /// Said beside the queue after a save that stopped partway.
    @Published private(set) var saveSummary: String?
    @Published private(set) var isSaving = false
    /// A save landed but the type could not be read back, so the copy on screen is older than the
    /// server's. Editing waits for a reload: a change compared against it could be dropped as a no-op.
    @Published private(set) var needsReload = false
    @Published private(set) var support: UserTypeEditSupport = .none
    @Published private(set) var objectRef: DatabaseObjectRef
    /// Kept here rather than in the view, which a tab switch recreates.
    @Published var section: UserTypeEditorSection = .general

    let connection: DatabaseConnection
    private let metadata: any ScopedMetadataProviding
    private let driverLookup: @MainActor (UUID) -> DatabaseDriver?
    private let gate: any ExecutionGate
    /// Bumped by every read, so a read that finishes after a newer one never overwrites it.
    private var loadGeneration = 0

    /// Told the type's new name once a rename has run, so the tab can follow it.
    var onRenamed: ((DatabaseObjectRef) -> Void)?

    init(
        objectRef: DatabaseObjectRef,
        connection: DatabaseConnection,
        metadata: any ScopedMetadataProviding = DatabaseManager.shared,
        driverLookup: @escaping @MainActor (UUID) -> DatabaseDriver? = { DatabaseManager.shared.driver(for: $0) },
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) {
        self.objectRef = objectRef
        self.connection = connection
        self.metadata = metadata
        self.driverLookup = driverLookup
        self.gate = gate
    }

    var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: objectRef.database, schema: objectRef.schema)
    }

    var hasChanges: Bool { !changes.isEmpty }

    var projection: UserTypeDraft.Projection? {
        serverType.map { UserTypeDraft.project($0, changes: changes) }
    }

    var kind: UserDefinedTypeInfo.Kind { serverType?.kind ?? objectRef.typeKind ?? .other }

    func message(for change: StagedTypeChange) -> String? {
        serverErrors[change.id] ?? projection?.issues[change.id]
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        if loadState == .loaded { return }
        await load()
    }

    /// A reload keeps what is on screen when it fails, and keeps the queue: the queued changes are
    /// replayed over whatever the server now holds, and any that no longer fit say so.
    @discardableResult
    func load() async -> Bool {
        if serverType == nil { loadState = .loading }
        guard let reference = objectRef.userType else {
            loadState = .failed(PluginObjectSourceError.unsupported(objectRef.name).localizedDescription)
            return false
        }
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let fetched = try await metadata.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchUserDefinedType(reference)
            }
            guard generation == loadGeneration else { return false }
            serverType = fetched
            support = UserTypeEditSupport.of(driverLookup(connection.id), type: fetched)
            loadState = .loaded
            needsReload = false
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == loadGeneration else { return false }
            Self.logger.error("Type load failed: \(error.publicLogShape, privacy: .public)")
            if serverType == nil { loadState = .failed(error.localizedDescription) }
            return false
        }
    }

    // MARK: - Queue

    /// Queues a change. A name, comment, default or NOT NULL edit replaces the one already queued
    /// for that property, and one that puts the property back as the server has it removes it. A
    /// rename stays last, because every other statement names the type as the server knows it.
    func stage(_ change: PluginUserDefinedTypeChange) {
        guard !needsReload else { return }
        let staged = StagedTypeChange(change: change)
        var next = changes
        if let property = staged.property {
            for replaced in next where replaced.property == property {
                serverErrors.removeValue(forKey: replaced.id)
            }
            next.removeAll { $0.property == property }
            guard !restoresServerValue(change) else {
                changes = next
                return
            }
        }
        if staged.property == .name {
            next.append(staged)
        } else if let renameIndex = next.firstIndex(where: { $0.property == .name }) {
            next.insert(staged, at: renameIndex)
        } else {
            next.append(staged)
        }
        changes = next
        saveSummary = nil
    }

    func remove(_ changeId: UUID) {
        changes.removeAll { $0.id == changeId }
        serverErrors.removeValue(forKey: changeId)
        saveSummary = nil
    }

    func discardChanges() {
        changes = []
        serverErrors = [:]
        saveSummary = nil
    }

    /// The name a queued rename asks for, kept as typed even when it is not valid yet, so the field
    /// shows what the user typed rather than the projection's last valid name.
    var queuedName: String? {
        for staged in changes {
            if case .rename(let name) = staged.change { return name }
        }
        return nil
    }

    func problem(staging candidates: [PluginUserDefinedTypeChange]) -> String? {
        guard let serverType, !candidates.isEmpty else { return nil }
        let staged = candidates.map { StagedTypeChange(change: $0) }
        let projection = UserTypeDraft.project(serverType, changes: changes + staged)
        return staged.lazy.compactMap { projection.issues[$0.id] }.first
    }

    private func restoresServerValue(_ change: PluginUserDefinedTypeChange) -> Bool {
        guard let serverType else { return false }
        switch change {
        case .rename(let name):
            return name == serverType.name
        case .setComment(let comment):
            return UserTypeDraft.nonEmpty(comment) == UserTypeDraft.nonEmpty(serverType.comment)
        case .setDefault(let value):
            return UserTypeDraft.nonEmpty(value) == UserTypeDraft.nonEmpty(serverType.defaultValue)
        case .setNotNull(let value):
            return value == serverType.isNotNull
        default:
            return false
        }
    }

    // MARK: - Preview and Save

    func previewStatements() throws -> [String] {
        try plan().statements
    }

    private func plan() throws -> UserTypeChangePlan {
        guard !needsReload else { throw StaleTypeError() }
        guard let serverType, let driver = driverLookup(connection.id) else {
            throw DatabaseObjectCommandError.notConnected
        }
        return try UserTypeChangePlan.build(type: serverType, changes: changes, driver: driver)
    }

    /// Applies the queue. `.refused` and `.failed` leave the work queued, which is what stands a
    /// close down.
    func save(window: NSWindow?) async -> StructureSaveOutcome {
        guard !changes.isEmpty else { return .nothingToApply }
        guard !isSaving else { return .refused }
        if let projection, !projection.issues.isEmpty {
            AlertHelper.showErrorSheet(
                title: String(localized: "Some Changes Are Incomplete"),
                message: changes.compactMap { projection.issues[$0.id] }.joined(separator: "\n"),
                window: window
            )
            return .refused
        }

        let plan: UserTypeChangePlan
        do {
            plan = try self.plan()
        } catch {
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: window
            )
            return .failed(error.localizedDescription)
        }

        let renamed = changes.compactMap { staged -> String? in
            if case .rename(let name) = staged.change { return name }
            return nil
        }.last

        isSaving = true
        serverErrors = [:]
        saveSummary = nil
        loadGeneration += 1
        defer { isSaving = false }

        let outcome: UserTypeSaveOutcome
        do {
            outcome = try await UserTypeChangeRunner.run(plan, in: scope, connection: connection, gate: gate)
        } catch {
            let failure = StructureApplyFailure(error)
            if let message = failure.message {
                AlertHelper.showErrorSheet(
                    title: String(localized: "Error Applying Changes"),
                    message: message,
                    window: window
                )
            }
            return failure.outcome
        }

        switch outcome {
        case .applied:
            changes = []
            if let renamed { adoptRename(to: renamed) }
            MainContentCoordinator.refreshTableDefinitions(connectionId: connection.id, database: scope.database)
            if !(await load()) { needsReload = true }
            return .applied
        case .failed(let changeId, let message, let applied):
            serverErrors[changeId] = message
            changes.removeAll { applied.contains($0.id) }
            saveSummary = applied.isEmpty
                ? String(localized: "The server refused a change, so nothing was saved.")
                : String(localized: "The server refused a change. The changes before it were saved.")
            if !applied.isEmpty {
                MainContentCoordinator.refreshTableDefinitions(connectionId: connection.id, database: scope.database)
                if !(await load()) { needsReload = true }
            }
            return .failed(message)
        }
    }

    private func adoptRename(to newName: String) {
        let renamed = DatabaseObjectRef(
            kind: objectRef.kind,
            name: newName,
            database: objectRef.database,
            schema: objectRef.schema,
            identity: objectRef.identity,
            typeKind: objectRef.typeKind,
            attributes: objectRef.attributes
        )
        objectRef = renamed
        onRenamed?(renamed)
    }

    /// Follows a rename made outside this tab, from the sidebar. The queue's statements name the
    /// type as the server knows it, so the type is read again before the next save.
    func adoptExternalRename(_ renamed: DatabaseObjectRef) async {
        objectRef = renamed
        if !(await load()) { needsReload = true }
    }
}
