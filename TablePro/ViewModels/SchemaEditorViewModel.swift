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

    private(set) var mode: Mode
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

    var name = ""
    var owner = ""
    var comment = ""

    private(set) var granteeRows: [SchemaGranteeRow] = []

    /// What the form held when it loaded. Dirtiness is this compared with the form now, never a
    /// latch: a checkbox toggled on and straight off again is not an edit, and treating it as one
    /// made `apply()` overwrite a concurrent grant with the stale value and run a REVOKE the
    /// preview never showed.
    private var baselineRows: [SchemaGranteeRow] = []

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
        /// A schema that is not there any more is an error rather than an empty baseline: treating
        /// nil as "exists with nothing set" made a Save re-emit statements that had already run.
        guard let resolved = details else { throw Self.missingSchema(schema) }
        current = resolved
        name = resolved.name
        owner = resolved.owner ?? ""
        comment = resolved.comment ?? ""
        granteeRows = SchemaFormRules.rows(from: resolved, privileges: privileges)
        baselineRows = granteeRows
    }

    func addGrantee(_ grantee: PluginSchemaGrantee) {
        guard !granteeRows.contains(where: { $0.grantee == grantee }) else { return }
        /// A role added here holds nothing on the server yet, so nothing about it is locked: every
        /// box the user ticks is theirs to untick again.
        granteeRows.append(
            SchemaGranteeRow(grantee: grantee, granted: [], grantable: [], locked: [])
        )
        granteeRows.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Which cells differ from what the form loaded. Derived, so restoring a value stops counting
    /// as an edit.
    private var editedCells: Set<String> {
        var result: Set<String> = []
        let baseline = Dictionary(uniqueKeysWithValues: baselineRows.map { ($0.grantee, $0) })
        for row in granteeRows {
            let before = baseline[row.grantee]
            for privilege in row.granted.union(before?.granted ?? []) {
                let held = row.granted.contains(privilege)
                let wasHeld = before?.granted.contains(privilege) ?? false
                if held != wasHeld { result.insert("\(row.id)\u{1}\(privilege)") }
            }
        }
        for row in baselineRows where !granteeRows.contains(where: { $0.grantee == row.grantee }) {
            for privilege in row.granted { result.insert("\(row.id)\u{1}\(privilege)") }
        }
        return result
    }

    /// The target state to send: the freshly read schema with only the cells the user edited
    /// overlaid. Every other facet is whatever the server says it is right now.
    private func merged(onto latest: PluginSchemaDetails) -> PluginSchemaDefinition {
        let intent = target
        let edited = editedCells
        let key = { (grant: PluginSchemaGrant) -> String in
            let rowId: String
            switch grant.grantee {
            case .publicGroup: rowId = "\u{1}public"
            case .role(let name): rowId = "role\u{1}\(name)"
            }
            return "\(rowId)\u{1}\(grant.privilege)"
        }
        var grants = latest.grants.filter { !edited.contains(key($0)) }
        grants += intent.grants.filter { edited.contains(key($0)) }
        return PluginSchemaDefinition(
            name: name != (baselineName ?? "") ? intent.name : latest.name,
            owner: owner != (current?.owner ?? "") ? intent.owner : latest.owner,
            comment: comment != (current?.comment ?? "") ? intent.comment : latest.comment,
            grants: supportsPrivileges ? grants : []
        )
    }

    private var baselineName: String? { current?.name }

    private static func missingSchema(_ name: String) -> DatabaseError {
        .queryFailed(
            String(format: String(localized: "Schema \"%@\" no longer exists."), name)
        )
    }

    /// Toggling a privilege off and on again must leave it exactly as it was.
    ///
    /// The grant option has no control of its own in this sheet, so clearing it along with the
    /// privilege made a re-checked box look untouched while Save emitted `REVOKE GRANT OPTION`.
    /// The bit is restored from the server's own state whenever the privilege ends up enabled.
    func setPrivilege(_ privilege: String, granted: Bool, for grantee: PluginSchemaGrantee) {
        guard let index = granteeRows.firstIndex(where: { $0.grantee == grantee }),
              granteeRows[index].canEdit(privilege) else { return }
        if granted {
            granteeRows[index].granted.insert(privilege)
            /// Restored from the baseline rather than dropped, because this sheet has no
            /// grant-option control: clearing it on the way through made a re-checked box look
            /// untouched while Save emitted `REVOKE GRANT OPTION`.
            if baselineGrantable(privilege, for: grantee) {
                granteeRows[index].grantable.insert(privilege)
            }
        } else {
            granteeRows[index].granted.remove(privilege)
            granteeRows[index].grantable.remove(privilege)
        }
    }

    private func baselineGrantable(_ privilege: String, for grantee: PluginSchemaGrantee) -> Bool {
        baselineRows.first { $0.grantee == grantee }?.grantable.contains(privilege) ?? false
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
            /// Whatever committed before the failure is now the server's truth, so the editor is
            /// rebased onto it: without this a retry reissued the `CREATE` against a schema that
            /// already existed, or looked the old name up, found nothing, and emitted the
            /// already-committed rename a second time.
            let committedFirst = error.committedCount >= 1
            if committedFirst {
                await rebase(onto: plan.name, scope: scope)
            }
            return ApplyOutcome(
                succeeded: false,
                committedName: plan.name,
                renameCommitted: plan.renamesFirst && committedFirst
            )
        } catch {
            failure = error.localizedDescription
            return ApplyOutcome(
                succeeded: false, committedName: originalName ?? "", renameCommitted: false
            )
        }
    }

    /// Re-reads the schema under the name that committed and switches the editor to editing it.
    ///
    /// A create whose first statement landed is no longer a create, and a rename that landed has
    /// moved the object the rest of the plan names. Reloading leaves the remaining user intent in
    /// the form, so pressing Save again emits only what has not run.
    private func rebase(onto committedName: String, scope: DatabaseScope) async {
        mode = .edit(committedName)
        existingSchemas = browsedSchemaNames()
        do {
            try await loadCurrent(named: committedName)
        } catch {
            Self.logger.error(
                "Rebase after a partial schema apply failed: \(error.localizedDescription, privacy: .public)"
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
            let fetched = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchSchemaDetails(name: existing)
            }
            guard let latest = fetched else { throw Self.missingSchema(existing) }
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
