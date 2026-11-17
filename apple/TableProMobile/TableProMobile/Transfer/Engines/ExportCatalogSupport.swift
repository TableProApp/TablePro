import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProSQLGrammar

// How a dump spells an engine's DDL and which lexical rules it declares: the session's readings, through the same owner
// the Mac's export adapter uses. Every iOS engine has a curated profile, so nothing is declared beside the session.
nonisolated struct ExportCatalogScript: Sendable {
    let databaseTypeId: String
    let readings: SQLLexicalReadings

    init(databaseTypeId: String, session: SQLSessionLexicalFacts?) {
        self.databaseTypeId = databaseTypeId
        readings = SQLLexicalReadings.resolve(databaseTypeId: databaseTypeId, declared: nil, session: session)
    }

    var lexicalFeatures: SQLLexicalFeatures {
        readings.execution.pluginFeatures
    }

    func scriptText(for ddl: String) -> String {
        SQLScriptText(databaseTypeId: databaseTypeId, readings: readings).scriptText(forDriverText: ddl)
    }
}

// A list read once per container and matched back by name, as the Mac's `ExportObjectCache` keeps it: a driver
// addresses a routine or trigger through the info object it handed out.
nonisolated final class ExportCatalogListCache<Value: Sendable>: Sendable {
    private let lists = OSAllocatedUnfairLock<[String: [Value]]>(initialState: [:])

    func values(for container: String, load: () async throws -> [Value]) async throws -> [Value] {
        if let cached = lists.withLock({ $0[container] }) { return cached }
        let loaded = try await load()
        lists.withLock { $0[container] = loaded }
        return loaded
    }
}

nonisolated enum ExportCatalogItems {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportCatalogItems")

    // `container` is what the export groups the object under: the schema on these engines. A routine's `tableType` is
    // its kind, which picks DROP FUNCTION or DROP PROCEDURE.
    static func item(
        _ name: String,
        container: String,
        kind: PluginExportObjectKind,
        tableType: String? = nil,
        identity: String? = nil,
        parentTable: String? = nil
    ) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: container,
            tableType: tableType ?? kind.rawValue,
            schema: container,
            kind: kind,
            identity: identity,
            parentTable: parentTable
        )
    }

    // The relation kinds a listing names, matched loosely as the Mac matches them. A sequence is listed on its own.
    static func relation(_ table: PluginTableInfo, container: String) -> PluginExportTable? {
        guard table.type.uppercased() != "SEQUENCE" else { return nil }
        return item(table.name, container: container, kind: PluginExportObjectKind.from(tableType: table.type))
    }

    static func routines(_ routines: [PluginRoutineInfo], container: String) -> [PluginExportTable] {
        routines.map {
            item(
                $0.name, container: container, kind: .routine, tableType: $0.kind.rawValue, identity: $0.argumentSignature
            )
        }
    }

    static func triggers(_ triggers: [PluginTriggerInfo], container: String) -> [PluginExportTable] {
        triggers.map { item($0.name, container: container, kind: .trigger, parentTable: $0.table) }
    }

    static func principals(_ principals: [PluginPrincipalInfo], container: String) -> [PluginExportTable] {
        principals.map { item($0.ref.name, container: container, kind: .grant, identity: $0.ref.host) }
    }

    // A kind the engine cannot answer comes back empty: one failed list must not cost the user the table list.
    static func listing(_ kind: String, _ read: () async throws -> [PluginExportTable]) async -> [PluginExportTable] {
        do {
            return try await read()
        } catch {
            logger.warning("Failed to list \(kind, privacy: .public) for export: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    // The kind is part of the match: `f()` can name a function and a procedure apart.
    static func routine(matching object: PluginExportTable, in routines: [PluginRoutineInfo]) throws -> PluginRoutineInfo {
        let kind = PluginRoutineKind(rawValue: object.tableType.lowercased())
        guard let routine = routines.first(where: { candidate in
            candidate.name == object.name
                && (candidate.argumentSignature ?? "") == (object.identity ?? "")
                && (kind == nil || candidate.kind == kind)
        }) else {
            throw PluginObjectSourceError.unsupported(object.name)
        }
        return routine
    }

    static func trigger(matching object: PluginExportTable, in triggers: [PluginTriggerInfo]) throws -> PluginTriggerInfo {
        guard let trigger = triggers.first(where: { $0.name == object.name && $0.table == object.parentTable }) else {
            throw PluginObjectSourceError.unsupported(object.name)
        }
        return trigger
    }

    // The engine renders its own GRANT text: only it knows how it spells a grantee and a privilege target.
    static func grantStatements(
        principal: String,
        host: String?,
        fetchGrants: (PluginPrincipalRef) async throws -> [PluginGrantInfo],
        generate: (PluginPrincipalChangeSet) -> [String]?
    ) async throws -> [String] {
        let ref = PluginPrincipalRef(name: principal, host: host)
        let grants = try await fetchGrants(ref)
        guard !grants.isEmpty else { return [] }
        return generate(PluginPrincipalChangeSet(principal: ref, grantsToAdd: grants)) ?? []
    }

    // A routine's drop needs its kind: PostgreSQL refuses DROP FUNCTION on a procedure.
    static func routineKind(of object: PluginExportTable) -> PluginRoutineKind? {
        guard object.kind == .routine else { return nil }
        return PluginRoutineKind(rawValue: object.tableType.lowercased())
    }
}

nonisolated extension DriverTransactionState {
    var pluginSessionState: PluginSessionTransactionState {
        switch self {
        case .idle: .idle
        case .explicitTransaction, .implicitTransaction: .inTransaction
        case .abortedTransaction: .abortedTransaction
        case .unknown: .unknown
        }
    }
}

nonisolated enum ImportTableNames {
    // As the Mac's statement generator spells the target: schema-qualified when the import names a schema.
    static func qualified(_ table: String, schema: String?, quote: (String) -> String) -> String {
        guard let schema, !schema.isEmpty else { return quote(table) }
        return "\(quote(schema)).\(quote(table))"
    }

    static func columnTypeNames(_ columns: [ColumnInfo]) -> [String: String] {
        Dictionary(columns.map { ($0.name, $0.typeName) }, uniquingKeysWith: { first, _ in first })
    }

    // The message the Mac's `RowImportTableMaker` gives when the engine builds no CREATE TABLE.
    static var noStatement: MobileTransferRefusal {
        MobileTransferRefusal(reason: String(localized: "Could not build the CREATE TABLE statement"))
    }
}
