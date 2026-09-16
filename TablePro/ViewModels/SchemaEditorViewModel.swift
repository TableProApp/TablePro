//
//  SchemaEditorViewModel.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Drives the Create Schema and Edit Schema sheets: what the schema is now, what the user wants it
/// to be, and the statements between the two.
///
/// The statements are the driver's, generated rather than executed, so the preview the sheet shows
/// is the text the gate authorizes and the server runs. The current state is read immediately
/// before the plan is built, which is what keeps the privilege diff from revoking a grant another
/// session added while the sheet was open.
@MainActor @Observable
final class SchemaEditorViewModel {
    nonisolated static let logger = Logger(subsystem: "com.TablePro", category: "SchemaEditor")

    enum Mode: Equatable {
        case create
        case edit(String)

        var existingName: String? {
            guard case .edit(let name) = self else { return nil }
            return name
        }
    }

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let mode: Mode
    let connectionId: UUID
    let databaseType: DatabaseType
    let database: String?

    private(set) var loadState: LoadState = .loading
    private(set) var current: PluginSchemaDetails?
    private(set) var ownerCandidates: [String] = []
    private(set) var privileges: [PluginPrivilegeDescriptor] = []
    private(set) var existingSchemas: [String] = []
    private(set) var isApplying = false
    private(set) var failure: String?

    var name = "" {
        didSet { touch(.name, changedFrom: oldValue, to: name) }
    }

    var owner = "" {
        didSet { touch(.owner, changedFrom: oldValue, to: owner) }
    }

    var comment = "" {
        didSet { touch(.comment, changedFrom: oldValue, to: comment) }
    }

    private(set) var granteeRows: [SchemaGranteeRow] = []

    /// Which facets the user actually edited.
    ///
    /// `apply()` re-reads the schema so the diff is against the server, and that re-read is only
    /// worth doing if the untouched facets come from it rather than from the copy the sheet loaded.
    /// Sending the whole form back reverts anything another session changed in the meantime, which
    /// is the blanket-revoke defect this design exists to avoid.
    private enum Facet: Hashable {
        case name
        case owner
        case comment
        case privilege(grantee: String, privilege: String)
    }

    private var touched: Set<Facet> = []
    private var isLoadingForm = false

    private let services: AppServices

    init(
        mode: Mode,
        connectionId: UUID,
        databaseType: DatabaseType,
        database: String?,
        services: AppServices
    ) {
        self.mode = mode
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.database = database
        self.services = services
        self.name = mode.existingName ?? ""
    }

    var supportsOwner: Bool { services.pluginManager.supportsSchemaOwner(for: databaseType) }
    var supportsPrivileges: Bool { services.pluginManager.supportsSchemaPrivileges(for: databaseType) }
    var supportsRename: Bool { services.pluginManager.supportsRenameSchema(for: databaseType) }

    /// The name field is editable on create always, and on edit only where the engine renames a
    /// schema. Showing it disabled rather than hiding it keeps the sheet's shape the same and
    /// still says what the schema is called.
    var isNameEditable: Bool {
        switch mode {
        case .create: true
        case .edit: supportsRename
        }
    }

    var nameProblem: SchemaFormRules.NameProblem? {
        SchemaFormRules.problem(with: name, existing: existingSchemas, ignoring: mode.existingName)
    }

    var target: PluginSchemaDefinition {
        PluginSchemaDefinition(
            name: SchemaFormRules.normalized(name),
            owner: supportsOwner ? owner.nilIfEmpty : nil,
            comment: comment.nilIfEmpty,
            grants: supportsPrivileges ? SchemaFormRules.grants(from: granteeRows) : []
        )
    }

    /// The statements as they stand, for the preview. Recomputed rather than cached because every
    /// keystroke in the sheet can change them, and generating them is string building.
    var plannedStatements: [String] {
        guard nameProblem == nil else { return [] }
        guard let driver = services.databaseManager.driver(for: connectionId) else { return [] }
        switch mode {
        case .create:
            return driver.createSchemaStatements(target) ?? []
        case .edit:
            guard let current else { return [] }
            return driver.alterSchemaStatements(from: current, to: target) ?? []
        }
    }

    var canApply: Bool {
        guard !isApplying, loadState == .ready, nameProblem == nil else { return false }
        switch mode {
        case .create:
            return !plannedStatements.isEmpty
        case .edit:
            guard let current else { return false }
            return SchemaFormRules.hasChanges(from: current, to: target) && !plannedStatements.isEmpty
        }
    }

    func load() async {
        loadState = .loading
        failure = nil
        do {
            existingSchemas = browsedSchemaNames()
            try await loadPrivilegeVocabulary()
            if let existing = mode.existingName {
                try await loadCurrent(named: existing)
            }
            loadState = .ready
        } catch {
            Self.logger.error("Schema editor load failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    private func loadPrivilegeVocabulary() async throws {
        guard supportsOwner || supportsPrivileges else { return }
        guard let principals = services.databaseManager.principalDriver(for: connectionId) else { return }
        if supportsOwner {
            ownerCandidates = try await principals.fetchPrincipals()
                .map(\.ref.name)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        if supportsPrivileges {
            privileges = try await principals.fetchPrivilegeCatalog().schemaPrivileges
        }
    }

    private func loadCurrent(named schema: String) async throws {
        guard let scope = resolvedScope() else { throw DatabaseError.notConnected }
        let details = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
            try await driver.fetchSchemaDetails(name: schema)
        }
        let resolved = details ?? PluginSchemaDetails(name: schema)
        isLoadingForm = true
        current = resolved
        name = resolved.name
        owner = resolved.owner ?? ""
        comment = resolved.comment ?? ""
        granteeRows = SchemaFormRules.rows(from: resolved.grants, privileges: privileges)
        isLoadingForm = false
        touched = []
    }

    private func touch(_ facet: Facet, changedFrom oldValue: String, to newValue: String) {
        guard !isLoadingForm, oldValue != newValue else { return }
        touched.insert(facet)
    }

    func addGrantee(_ grantee: String) {
        let trimmed = grantee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !granteeRows.contains(where: { $0.grantee == trimmed }) else { return }
        granteeRows.append(SchemaGranteeRow(grantee: trimmed, granted: [], grantable: []))
        granteeRows.sort { $0.grantee.localizedStandardCompare($1.grantee) == .orderedAscending }
    }

    /// The target state to send: the freshly read schema with only the facets the user edited
    /// overlaid. Every other facet is whatever the server says it is right now.
    private func merged(onto latest: PluginSchemaDetails) -> PluginSchemaDefinition {
        let intent = target
        var grants = latest.grants.filter { grant in
            !touched.contains(.privilege(grantee: grant.grantee, privilege: grant.privilege))
        }
        for grant in intent.grants
            where touched.contains(.privilege(grantee: grant.grantee, privilege: grant.privilege)) {
            grants.append(grant)
        }
        return PluginSchemaDefinition(
            name: touched.contains(.name) ? intent.name : latest.name,
            owner: touched.contains(.owner) ? intent.owner : latest.owner,
            comment: touched.contains(.comment) ? intent.comment : latest.comment,
            grants: supportsPrivileges ? grants : []
        )
    }

    /// Toggling a privilege off and on again must leave it exactly as it was.
    ///
    /// The grant option has no control of its own in this sheet, so clearing it along with the
    /// privilege made a re-checked box look untouched while Save emitted `REVOKE GRANT OPTION`.
    /// The bit is restored from the server's own state whenever the privilege ends up enabled.
    func setPrivilege(_ privilege: String, granted: Bool, for grantee: String) {
        guard let index = granteeRows.firstIndex(where: { $0.grantee == grantee }) else { return }
        if granted {
            granteeRows[index].granted.insert(privilege)
            if wasGrantable(privilege, for: grantee) {
                granteeRows[index].grantable.insert(privilege)
            }
        } else {
            granteeRows[index].granted.remove(privilege)
            granteeRows[index].grantable.remove(privilege)
        }
        touched.insert(.privilege(grantee: grantee, privilege: privilege))
    }

    private func wasGrantable(_ privilege: String, for grantee: String) -> Bool {
        current?.grants.contains {
            $0.grantee == grantee && $0.privilege == privilege && $0.isGrantable
        } ?? false
    }

    /// What the apply actually did, for the caller that has to reconcile the window with it.
    ///
    /// The name is the one that was executed rather than whatever the form holds by the time this
    /// returns, and `renameCommitted` is separate from success: on an engine with no transactional
    /// DDL the rename can land and a later statement still fail, and a tab left on the old name is
    /// then pointing at a schema that no longer exists.
    struct ApplyOutcome {
        let succeeded: Bool
        let committedName: String
        let renameCommitted: Bool
    }

    /// Applies the change, re-reading the schema first so the diff is against what is on the server
    /// now and not against what it looked like when the sheet opened.
    func apply() async -> ApplyOutcome {
        let originalName = mode.existingName
        guard canApply, let scope = resolvedScope() else {
            return ApplyOutcome(
                succeeded: false, committedName: originalName ?? "", renameCommitted: false
            )
        }
        isApplying = true
        failure = nil
        defer { isApplying = false }

        let plan: Plan
        do {
            plan = try await freshPlan(scope: scope)
        } catch {
            failure = error.localizedDescription
            return ApplyOutcome(
                succeeded: false, committedName: originalName ?? "", renameCommitted: false
            )
        }
        guard !plan.statements.isEmpty else {
            return ApplyOutcome(succeeded: true, committedName: plan.name, renameCommitted: false)
        }

        do {
            try await services.databaseManager.runContainerStatements(
                .statements(plan.statements),
                description: operationDescription,
                scope: scope,
                databaseType: databaseType,
                event: .changed(
                    CatalogChange(connectionId: connectionId, database: database, kinds: .schemas)
                )
            )
            return ApplyOutcome(
                succeeded: true,
                committedName: plan.name,
                renameCommitted: plan.renamesFirst
            )
        } catch let error as ContainerDDLPartialFailure {
            failure = error.underlying.localizedDescription
            /// The rename is always the first statement the planner emits, so one committed
            /// statement is exactly the case where the schema now answers to its new name.
            return ApplyOutcome(
                succeeded: false,
                committedName: plan.name,
                renameCommitted: plan.renamesFirst && error.committedCount >= 1
            )
        } catch {
            failure = error.localizedDescription
            return ApplyOutcome(
                succeeded: false, committedName: originalName ?? "", renameCommitted: false
            )
        }
    }

    private struct Plan {
        let statements: [SchemaStatement]
        let name: String
        let renamesFirst: Bool
    }

    private func freshPlan(scope: DatabaseScope) async throws -> Plan {
        guard let driver = services.databaseManager.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }
        switch mode {
        case .create:
            let intent = target
            guard let sql = driver.createSchemaStatements(intent) else {
                throw DatabaseError.unsupportedOperation
            }
            return Plan(
                statements: sql.map { SchemaStatement(sql: $0, description: $0, isDestructive: false) },
                name: intent.name,
                renamesFirst: false
            )
        case .edit(let existing):
            let latest = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchSchemaDetails(name: existing)
            } ?? PluginSchemaDetails(name: existing)
            let intent = merged(onto: latest)
            guard let sql = driver.alterSchemaStatements(from: latest, to: intent) else {
                throw DatabaseError.unsupportedOperation
            }
            return Plan(
                statements: sql.map {
                    SchemaStatement(sql: $0, description: $0, isDestructive: Self.revokes($0))
                },
                name: intent.name,
                renamesFirst: intent.name != latest.name
            )
        }
    }

    /// A revoke takes access away, so the gate treats it at the destructive tier. Matched on the
    /// leading keyword because these statements are the driver's own, generated a line at a time.
    private static func revokes(_ sql: String) -> Bool {
        sql.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("REVOKE")
    }

    private var operationDescription: String {
        let entity = services.pluginManager.schemaEntityName(for: databaseType)
        switch mode {
        case .create:
            return String(format: String(localized: "Create %1$@ \"%2$@\""), entity, target.name)
        case .edit(let existing):
            return String(format: String(localized: "Edit %1$@ \"%2$@\""), entity, existing)
        }
    }

    /// The schema list is only a duplicate pre-check, and it is only used when it describes the
    /// database this sheet targets. `SchemaService` holds one catalog per connection, for the
    /// database the window browses, so a schema row from another database would otherwise be
    /// checked against the wrong list: a valid rename blocked by a same-named schema elsewhere, and
    /// a real collision missed until the server refused it.
    private func browsedSchemaNames() -> [String] {
        guard let loaded = services.schemaService.loadedScope(for: connectionId),
              loaded.database == database
        else { return [] }
        return services.schemaService.schemas(for: connectionId)
    }

    private func resolvedScope() -> DatabaseScope? {
        services.databaseManager.resolvedScope(database: database, schema: nil, for: connectionId)
    }
}
