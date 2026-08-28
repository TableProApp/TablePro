//
//  ObjectCopyPlanner.swift
//  TablePro
//
//  Resolves a request into the work the runner will do.
//
//  Everything the plan needs is read here, while nothing is being written, so
//  the sheet can show the DDL and every refusal before the user commits. The
//  reads go through `CompareMetadataService`, which routes them through
//  `DatabaseManager.withMetadataDriver` and so keeps them off the connection's
//  live interactive driver.
//
//  A driver is taken once per side rather than once per object: the target's
//  DDL for every table is built inside one scoped call, because a copy of a
//  hundred tables would otherwise take the session gate a hundred times.
//

import Foundation
import TableProPluginKit

@MainActor
internal struct ObjectCopyPlanner {
    private let metadata: CompareMetadataService
    private let catalog: ObjectCopyCatalog
    private let manager: DatabaseManager

    internal init(
        metadata: CompareMetadataService = CompareMetadataService(),
        catalog: ObjectCopyCatalog = ObjectCopyCatalog(),
        manager: DatabaseManager = .shared
    ) {
        self.metadata = metadata
        self.catalog = catalog
        self.manager = manager
    }

    internal func plan(_ request: ObjectCopyRequest) async throws -> ObjectCopyPlan {
        let connections = try resolveConnections(request)
        try await manager.ensureConnected(connections.source)
        try await manager.ensureConnected(connections.target)
        try refuseUpFront(request)

        let names = Set(request.objects.map(\.name))
        let sourceReads = try await metadata.tableReads(
            for: request.source, connection: connections.source, includeViews: true, names: names
        )
        let targetReads = try await existingTargetReads(request, connection: connections.target, names: names)
        let targetObjects = try await existingTargetObjects(request, connection: connections.target)

        var skipped: [ObjectCopySkip] = []
        let tableSteps = try await buildTableSteps(
            request, sourceReads: sourceReads, targetReads: targetReads, skipped: &skipped
        )
        let definitionSteps = try await buildDefinitionSteps(
            request,
            sourceReads: sourceReads,
            targetObjects: targetObjects,
            connection: connections.source,
            skipped: &skipped
        )

        return ObjectCopyPlan(
            request: request,
            createsDatabase: request.destination.createsDatabase,
            tableSteps: tableSteps,
            definitionSteps: definitionSteps,
            skipped: skipped
        )
    }

    // MARK: - Refusals

    private struct Connections {
        let source: DatabaseConnection
        let target: DatabaseConnection
    }

    private func resolveConnections(_ request: ObjectCopyRequest) throws -> Connections {
        let saved = ConnectionStorage.shared.loadConnections()
        guard let source = saved.first(where: { $0.id == request.source.connectionId }) else {
            throw ObjectCopyError.refused(missingConnection(request.source))
        }
        guard let target = saved.first(where: { $0.id == request.target.connectionId }) else {
            throw ObjectCopyError.refused(missingConnection(request.target))
        }
        return Connections(source: source, target: target)
    }

    private func missingConnection(_ endpoint: DatabaseEndpoint) -> String {
        String(format: String(localized: "%@ is no longer a saved connection."), endpoint.connectionName)
    }

    private func refuseUpFront(_ request: ObjectCopyRequest) throws {
        if let reason = ObjectCopyEligibility.targetRefusal(request.target) {
            throw ObjectCopyError.refused(reason)
        }
        if !request.destination.createsDatabase,
           let reason = ObjectCopyEligibility.sameObjectRefusal(source: request.source, target: request.target) {
            throw ObjectCopyError.refused(reason)
        }
        if let reason = ObjectCopyEligibility.engineRefusal(
            from: request.source.databaseType, to: request.target.databaseType
        ) {
            throw ObjectCopyError.refused(reason)
        }
        let supportsSchemas = PluginManager.shared.supportsSchemaSwitching(for: request.source.databaseType)
        if let reason = ObjectCopyEligibility.unscopedSchemaRefusal(
            endpoint: request.source, supportsSchemas: supportsSchemas
        ) {
            throw ObjectCopyError.refused(reason)
        }
        guard request.content.includesData else { return }
        if let reason = CompareRowService(manager: manager)
            .concurrentReadRefusal(source: request.source, target: request.target) {
            throw ObjectCopyError.refused(reason)
        }
    }


    /// A database this run is about to create holds nothing, and asking a driver about a database
    /// that does not exist yet is an error rather than an empty answer.
    private func existingTargetReads(
        _ request: ObjectCopyRequest,
        connection: DatabaseConnection,
        names: Set<String>
    ) async throws -> [TableStructureRead] {
        guard !request.destination.createsDatabase else { return [] }
        return try await metadata.tableReads(
            for: request.target, connection: connection, includeViews: true, names: names
        )
    }

    /// What the target already has, by kind and name.
    ///
    /// `tableReads` lists tables and views and nothing else, so matching a routine or a trigger
    /// against it always answered "not there": Skip would not skip one, Replace would not drop one
    /// first, and the `CREATE` then failed with "already exists" against a target the user had
    /// asked to leave alone. Keyed by kind as well as name, because a table and a trigger may share
    /// one and only the trigger's own presence decides the trigger's step.
    private func existingTargetObjects(
        _ request: ObjectCopyRequest,
        connection: DatabaseConnection
    ) async throws -> Set<String> {
        guard !request.destination.createsDatabase else { return [] }
        let found = try await catalog.objects(in: request.target, connection: connection)
        return Set(found.map { Self.objectKey(for: $0) })
    }

    /// A materialized view and a view are one object to the engines that have both, and a
    /// procedure and a function share a namespace on several, so the key folds those pairs. The
    /// signature and the trigger's table stay in it, because two overloads and two same-named
    /// triggers are two objects and only one of them may already be in the target.
    nonisolated internal static func objectKey(for selection: ObjectCopySelection) -> String {
        let family: String
        switch selection.kind {
        case .view, .materializedView: family = "view"
        case .procedure, .function: family = "routine"
        default: family = selection.kind.rawValue
        }
        return [family, selection.name, selection.signature ?? "", selection.owner ?? ""]
            .map { $0.lowercased() }
            .joined(separator: "\u{1F}")
    }

    // MARK: - Tables

    private func buildTableSteps(
        _ request: ObjectCopyRequest,
        sourceReads: [TableStructureRead],
        targetReads: [TableStructureRead],
        skipped: inout [ObjectCopySkip]
    ) async throws -> [ObjectCopyTableStep] {
        var reads: [ObjectCopySelection: TableStructureRead] = [:]
        for selection in request.tables {
            guard let read = match(selection, in: sourceReads) else {
                skipped.append(ObjectCopySkip(selection: selection, reason: Self.missingInSource))
                continue
            }
            guard read.snapshot != nil else {
                skipped.append(ObjectCopySkip(selection: selection, reason: read.failure ?? Self.unreadable))
                continue
            }
            reads[selection] = read
        }
        guard !reads.isEmpty else { return [] }

        let sourceSchema = request.source.schema
        var drafts: [ObjectCopyTableDraft] = []
        for selection in Self.orderedByDependency(
            Array(reads.keys), reads: reads, effectiveSchema: sourceSchema
        ) {
            guard let read = reads[selection], let snapshot = read.snapshot else { continue }
            let targetRead = match(selection, in: targetReads)
            let existsInTarget = targetRead != nil
            if existsInTarget, request.existingPolicy == .skip {
                skipped.append(ObjectCopySkip(selection: selection, reason: Self.alreadyThere))
                continue
            }
            /// A table the target lists but cannot describe leaves the copy guessing which of its
            /// columns are writable, so it is refused rather than written to blind. Replacing its
            /// structure outright needs nothing from it and still goes ahead.
            if existsInTarget, targetRead?.snapshot == nil, request.existingPolicy != .replace {
                skipped.append(ObjectCopySkip(
                    selection: selection, reason: targetRead?.failure ?? Self.targetUnreadable
                ))
                continue
            }
            drafts.append(ObjectCopyTableDraft(
                selection: selection,
                snapshot: snapshot,
                targetSnapshot: targetRead?.snapshot,
                existsInTarget: existsInTarget,
                request: request
            ))
        }
        guard !drafts.isEmpty else { return [] }

        let sourceParts = try await readSourceParts(drafts, endpoint: request.source)
        let ddl = try await buildTargetDDL(drafts, request: request)
        return drafts.map { draft in
            let parts = sourceParts[draft.selection.id]
            let statements = ddl[draft.selection.id] ?? ObjectCopyTableDDL()
            return ObjectCopyTableStep(
                selection: draft.selection,
                dropStatements: statements.drop,
                createStatements: statements.create,
                truncateStatements: statements.truncate,
                columns: draft.targetColumns,
                primaryKeyColumns: draft.snapshot.primaryKeyColumns,
                sourceQuery: parts?.query ?? "",
                targetTable: draft.targetTable,
                targetSchema: draft.targetSchema,
                estimatedRows: parts?.estimatedRows,
                copiesData: draft.copiesData,
                copiesIdentityColumn: draft.copiesIdentityColumn,
                note: draft.note
            )
        }
    }

    private struct SourceParts: Sendable {
        let query: String
        let estimatedRows: Int?
    }

    /// One scoped call for every table, because each `withMetadataDriver` either leases a pooled
    /// connection or takes the session gate.
    private func readSourceParts(
        _ drafts: [ObjectCopyTableDraft],
        endpoint: DatabaseEndpoint
    ) async throws -> [String: SourceParts] {
        /// The source's own spellings, which are not always the target's: a case-insensitive
        /// match can pair `Orders.UserID` with `orders.userid`, and quoting the source's spelling
        /// into the target's INSERT names a column that engine does not have.
        let inputs = drafts.map {
            (id: $0.selection.id, table: $0.snapshot.name, schema: $0.sourceSchema, columns: $0.sourceColumns)
        }
        return try await manager.withMetadataDriver(scope: endpoint.scope, workload: .bulk) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noSourceDriver)
            }
            var parts: [String: SourceParts] = [:]
            for input in inputs {
                try Task.checkCancellation()
                let query = ObjectCopySelectQuery.build(
                    columns: input.columns, table: input.table, schema: input.schema, driver: plugin
                )
                let estimate = try? await plugin.fetchApproximateRowCount(
                    table: input.table, schema: input.schema
                )
                parts[input.id] = SourceParts(query: query, estimatedRows: estimate ?? nil)
            }
            return parts
        }
    }

    private func buildTargetDDL(
        _ drafts: [ObjectCopyTableDraft],
        request: ObjectCopyRequest
    ) async throws -> [String: ObjectCopyTableDDL] {
        let sourceSchema = request.source.schema
        let inputs = drafts.map {
            ObjectCopyDDLInput(
                id: $0.selection.id,
                snapshot: Self.retargeted(
                    $0.snapshot, from: sourceSchema, to: $0.targetSchema
                ),
                targetSchema: $0.targetSchema,
                writesStructure: $0.writesStructure,
                dropsFirst: $0.dropsFirst,
                emptiesFirst: $0.emptiesFirst
            )
        }
        guard inputs.contains(where: { $0.writesStructure || $0.dropsFirst || $0.emptiesFirst })
        else { return [:] }

        return try await manager.withMetadataDriver(scope: targetScope(request)) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let builder = SchemaSyncScriptBuilder(targetDriver: plugin)
            var result: [String: ObjectCopyTableDDL] = [:]
            for input in inputs {
                try Task.checkCancellation()
                var ddl = ObjectCopyTableDDL()
                if input.dropsFirst {
                    ddl.drop = try builder.build(
                        operations: [.dropTable(name: input.snapshot.name, schema: input.targetSchema)],
                        foreignKeysByTable: [:]
                    )
                }
                if input.writesStructure {
                    ddl.create = try builder.build(
                        operations: [.createTable(input.snapshot)], foreignKeysByTable: [:]
                    )
                }
                if input.emptiesFirst {
                    ddl.truncate = Self.emptyStatements(
                        table: input.snapshot.name, schema: input.targetSchema, driver: plugin
                    )
                }
                result[input.id] = ddl
            }
            return result
        }
    }

    /// Points the snapshot's foreign keys at the copy rather than at the original.
    ///
    /// A snapshot carries each foreign key's `referencedSchema` as the source spelled it. Handed
    /// unchanged to the target generator, the copied child either names a schema the target does
    /// not have or, worse, keeps referencing the source's parent, so `prod_copy.orders` stayed
    /// wired to `prod.customers` and the duplicate was never independent. A reference that names
    /// the source's own schema is moved to the target's; one that names a third schema is left
    /// alone, because that schema was not part of the copy.
    nonisolated internal static func retargeted(
        _ snapshot: TableStructureSnapshot,
        from sourceSchema: String?,
        to targetSchema: String?
    ) -> TableStructureSnapshot {
        let source = (sourceSchema ?? "").lowercased()
        guard source != (targetSchema ?? "").lowercased() else { return snapshot }
        let foreignKeys = snapshot.foreignKeys.map { key -> EditableForeignKeyDefinition in
            let referenced = (key.referencedSchema ?? "").lowercased()
            guard referenced.isEmpty || referenced == source else { return key }
            var moved = key
            moved.referencedSchema = targetSchema
            return moved
        }
        return TableStructureSnapshot(
            name: snapshot.name,
            schema: targetSchema,
            columns: snapshot.columns,
            indexes: snapshot.indexes,
            foreignKeys: foreignKeys,
            engine: snapshot.engine,
            charset: snapshot.charset,
            collation: snapshot.collation
        )
    }

    /// TRUNCATE where the engine has one, DELETE where it does not. Both are hazards, and both are
    /// in the script the user reads before pressing Copy.
    nonisolated private static func emptyStatements(
        table: String,
        schema: String?,
        driver: any PluginDatabaseDriver
    ) -> [SyncStatement] {
        let qualified: String = {
            guard let schema, !schema.isEmpty else { return driver.quoteIdentifier(table) }
            return "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(table))"
        }()
        let sql = driver.truncateTableStatements(table: table, schema: schema, cascade: false)?.first
            ?? "DELETE FROM \(qualified)"
        return [SyncStatement(
            sql: sql.hasSuffix(";") ? sql : sql + ";",
            objectName: table,
            summary: String(format: String(localized: "Empty %@ before copying"), table),
            hazards: [SyncHazard(
                kind: .dataLoss,
                severity: .refusedByDefault,
                explanation: String(
                    format: String(localized: "Every row already in %@ is removed."), table
                )
            )]
        )]
    }

    // MARK: - Views, routines and triggers

    private func buildDefinitionSteps(
        _ request: ObjectCopyRequest,
        sourceReads: [TableStructureRead],
        targetObjects: Set<String>,
        connection: DatabaseConnection,
        skipped: inout [ObjectCopySkip]
    ) async throws -> [ObjectCopyDefinitionStep] {
        let selections = request.sourceDefinedObjects
        guard !selections.isEmpty else { return [] }
        guard request.content.includesStructure else {
            skipped += selections.map { ObjectCopySkip(selection: $0, reason: Self.structureOnlyObject) }
            return []
        }

        let targetSchema = request.target.schema
        let definitions = try await sourceDefinitions(request, sourceReads: sourceReads, connection: connection)
        var pending: [(selection: ObjectCopySelection, definition: String, replaces: Bool)] = []
        for selection in Self.orderedByKind(selections) {
            /// Nothing here parses the definition, so every table it names keeps the source's own
            /// qualification. Running that against another schema recreates the object pointing
            /// back at the source, and for a replacement the generated DROP lands on the source's
            /// own object.
            guard ObjectCopyEligibility.canCopyDefinition(
                sourceSchema: selection.schema ?? request.source.schema, targetSchema: targetSchema
            ) else {
                skipped.append(ObjectCopySkip(
                    selection: selection, reason: ObjectCopyEligibility.definitionSchemaRefusal
                ))
                continue
            }
            guard let definition = definitions[selection.id],
                  !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped.append(ObjectCopySkip(selection: selection, reason: Self.noDefinition))
                continue
            }
            let existsInTarget = targetObjects.contains(Self.objectKey(for: selection))
            /// Add rows promises the target's structure is kept, and these objects hold no rows at
            /// all, so replacing one would be pure destruction with nothing to gain by it.
            if existsInTarget, request.existingPolicy != .replace {
                skipped.append(ObjectCopySkip(selection: selection, reason: Self.alreadyThere))
                continue
            }
            pending.append((selection, definition, existsInTarget))
        }
        guard !pending.isEmpty else { return [] }

        let inputs = pending.map { item in
            (
                id: item.selection.id,
                result: CompareObjectResult(
                    identity: CompareObjectIdentity(
                        kind: item.selection.kind,
                        schema: targetSchema ?? item.selection.schema,
                        name: item.selection.name,
                        signature: item.selection.signature
                    ),
                    status: item.replaces ? .differs : .onlyInSource,
                    sourceDefinition: [item.definition]
                ),
                replaces: item.replaces
            )
        }
        let built = try await manager.withMetadataDriver(scope: targetScope(request)) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let builder = SourceObjectSyncBuilder(targetDriver: plugin)
            var statements: [String: (drop: [SyncStatement], create: [SyncStatement])] = [:]
            for input in inputs {
                let drop = input.replaces ? builder.build(for: input.result, action: .drop) : []
                let create = builder.build(for: input.result, action: .create)
                statements[input.id] = (drop, create)
            }
            return statements
        }

        var steps: [ObjectCopyDefinitionStep] = []
        for item in pending {
            guard let statements = built[item.selection.id], !statements.create.isEmpty else {
                skipped.append(ObjectCopySkip(selection: item.selection, reason: Self.noDefinition))
                continue
            }
            steps.append(ObjectCopyDefinitionStep(
                selection: item.selection,
                dropStatements: statements.drop,
                createStatements: statements.create
            ))
        }
        return steps
    }

    private func sourceDefinitions(
        _ request: ObjectCopyRequest,
        sourceReads: [TableStructureRead],
        connection: DatabaseConnection
    ) async throws -> [String: String] {
        var definitions: [String: String] = [:]
        let selections = request.sourceDefinedObjects

        let views = selections.filter { $0.kind == .view || $0.kind == .materializedView }
        if !views.isEmpty {
            let infos = sourceReads.map(\.table).filter { info in
                views.contains { $0.name.lowercased() == info.name.lowercased() }
            }
            for read in try await metadata.viewDefinitions(
                for: request.source, connection: connection, views: infos
            ) {
                guard let selection = views.first(where: { $0.name.lowercased() == read.name.lowercased() })
                else { continue }
                definitions[selection.id] = read.source
            }
        }

        /// Matched on the argument signature as well as the name, because `f(integer)` and
        /// `f(text)` are two routines and copying one must not carry the other's body.
        let routines = selections.filter { $0.kind == .procedure || $0.kind == .function }
        if !routines.isEmpty {
            for read in try await metadata.routineReads(for: request.source, connection: connection) {
                guard let selection = routines.first(where: {
                    $0.kind == read.kind
                        && $0.name.lowercased() == read.name.lowercased()
                        && ($0.signature ?? "") == (read.signature ?? "")
                }) else { continue }
                definitions[selection.id] = read.source
            }
        }

        /// Asked of the tables the selected triggers name, not of the tables the user happened to
        /// select. Deriving the lookup from the table selection meant a trigger chosen on its own
        /// had no table to be found under and was always reported as having no definition.
        let triggers = selections.filter { $0.kind == .trigger }
        if !triggers.isEmpty {
            let owners = Set(triggers.compactMap(\.owner)).union(sourceReads.map(\.table.name))
            for read in try await metadata.triggerReads(
                for: request.source, connection: connection, tables: Array(owners)
            ) {
                guard let selection = triggers.first(where: {
                    $0.name.lowercased() == read.name.lowercased()
                        && ($0.owner.map { $0.lowercased() == (read.signature ?? "").lowercased() } ?? true)
                })
                else { continue }
                definitions[selection.id] = read.source
            }
        }
        return definitions
    }

    // MARK: - Ordering

    /// Parents before children, so a foreign key in a `CREATE TABLE` finds the table it points at.
    /// A cycle keeps whatever order the sort settles on and fails at the server, which is the same
    /// answer Compare & Sync gives it.
    /// `effectiveSchema` is the scope the tables were read in, and it is load-bearing.
    /// `fetchTables` returns `PluginTableInfo.schema == nil` on MySQL and PostgreSQL while their
    /// foreign keys carry a non-nil `referencedSchema`, so nodes built from the table's own schema
    /// were keyed `child` while the dependency named `public.parent`. No edge ever matched, every
    /// table looked independent, and the sort fell through to alphabetical order: a child could be
    /// created before its parent and the server rejected it.
    nonisolated internal static func orderedByDependency(
        _ selections: [ObjectCopySelection],
        reads: [ObjectCopySelection: TableStructureRead],
        effectiveSchema: String?
    ) -> [ObjectCopySelection] {
        guard selections.count > 1 else { return selections }
        var foreignKeysByTable: [String: [PluginForeignKeyInfo]] = [:]
        var nodes: [ForeignKeyTopologicalSort.Table] = []
        var bySortKey: [String: ObjectCopySelection] = [:]
        for selection in selections {
            guard let read = reads[selection] else { continue }
            let schema = read.table.schema ?? selection.schema ?? effectiveSchema
            let node = ForeignKeyTopologicalSort.Table(name: read.table.name, schema: schema)
            nodes.append(node)
            foreignKeysByTable[node.identifier] = read.foreignKeys
            bySortKey[node.identifier] = selection
        }

        var emitted: Set<String> = []
        var result: [ObjectCopySelection] = []
        for node in ForeignKeyTopologicalSort.ordered(
            nodes, foreignKeysByTable: foreignKeysByTable, childrenFirst: false
        ) where emitted.insert(node.identifier).inserted {
            guard let selection = bySortKey[node.identifier] else { continue }
            result.append(selection)
        }
        for selection in selections where !result.contains(selection) {
            result.append(selection)
        }
        return result
    }

    /// A view selects from a table, a routine calls a view, and a trigger hangs off a table, so the
    /// kinds run in that order. Within a kind the user's own order is kept.
    nonisolated internal static func orderedByKind(_ selections: [ObjectCopySelection]) -> [ObjectCopySelection] {
        let rank: [CompareObjectKind: Int] = [
            .view: 0, .materializedView: 1, .function: 2, .procedure: 3, .trigger: 4
        ]
        return selections.enumerated()
            .sorted { lhs, rhs in
                let left = rank[lhs.element.kind] ?? 9
                let right = rank[rhs.element.kind] ?? 9
                guard left == right else { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Helpers

    /// A database that does not exist yet cannot be connected to, so planning for one asks the
    /// server instead. The run switches to the real scope once `CREATE DATABASE` has succeeded.
    private func targetScope(_ request: ObjectCopyRequest) -> DatabaseScope {
        guard request.destination.createsDatabase else { return request.target.scope }
        return DatabaseScope(connectionId: request.target.connectionId, database: "", schema: nil)
    }

    private func match(_ selection: ObjectCopySelection, in reads: [TableStructureRead]) -> TableStructureRead? {
        reads.first { $0.table.name.lowercased() == selection.name.lowercased() }
    }

    /// Read from inside the scoped-driver closures, which run off the main actor.
    nonisolated private static let missingInSource = String(localized: "Not found in the source.")
    nonisolated private static let unreadable = String(localized: "Its structure could not be read.")
    nonisolated private static let targetUnreadable = String(
        localized: "The target has it, but its structure could not be read."
    )
    nonisolated private static let alreadyThere = String(localized: "Already in the target.")
    nonisolated private static let noDefinition = String(
        localized: "The source reports no definition for it."
    )
    nonisolated private static let structureOnlyObject = String(
        localized: "Views, routines and triggers hold no rows, so a data-only copy leaves them out."
    )
    nonisolated private static let noTargetDriver = String(
        localized: "The target driver cannot generate statements."
    )
    nonisolated private static let noSourceDriver = String(localized: "The source driver cannot be read.")
}

// MARK: - Drafts

/// One table's decisions, made before any driver is opened so the two scoped calls that follow can
/// each run over the whole list.
private struct ObjectCopyTableDraft {
    let selection: ObjectCopySelection
    let snapshot: TableStructureSnapshot
    let sourceSchema: String?
    let targetSchema: String?
    let targetTable: String
    /// Read with these, written with those. A case-insensitive match pairs two spellings of one
    /// column, and each side has to be quoted the way its own server spells it.
    let sourceColumns: [String]
    let targetColumns: [String]
    let writesStructure: Bool
    let dropsFirst: Bool
    let emptiesFirst: Bool
    let copiesData: Bool
    let copiesIdentityColumn: Bool
    let note: String?

    init(
        selection: ObjectCopySelection,
        snapshot: TableStructureSnapshot,
        targetSnapshot: TableStructureSnapshot?,
        existsInTarget: Bool,
        request: ObjectCopyRequest
    ) {
        self.selection = selection
        self.snapshot = snapshot
        self.sourceSchema = request.source.schema ?? snapshot.schema
        /// Never the source's. A target endpoint that names no schema means the target driver's
        /// own current scope, and inheriting the source's put a SQL Server `dbo` into a MySQL
        /// INSERT, naming a database that engine does not have.
        self.targetSchema = request.target.schema

        let keepsTargetStructure = existsInTarget && request.existingPolicy != .replace
        let writesStructure = request.content.includesStructure && !keepsTargetStructure
        self.writesStructure = writesStructure
        self.dropsFirst = writesStructure && existsInTarget
        /// A data-only replace has no DROP and CREATE to clear the table, so it is emptied instead.
        self.emptiesFirst = existsInTarget && request.existingPolicy == .replace && !writesStructure

        /// The target's own name when it already has the table, because a case-insensitive match
        /// pairs `Orders` with `orders` and the INSERT has to quote the one that exists.
        self.targetTable = (writesStructure ? nil : targetSnapshot?.name) ?? snapshot.name

        let pairs = Self.writableColumnPairs(
            snapshot: snapshot,
            targetSnapshot: writesStructure ? nil : targetSnapshot
        )
        self.sourceColumns = pairs.map(\.source)
        self.targetColumns = pairs.map(\.target)
        self.copiesData = request.content.includesData && !pairs.isEmpty && (writesStructure || existsInTarget)

        let written = Set(pairs.map { $0.source.lowercased() })
        self.copiesIdentityColumn = request.content.includesData && snapshot.columns.contains {
            written.contains($0.name.lowercased()) && $0.autoIncrement
        }

        if request.content.includesData, !writesStructure, !existsInTarget {
            self.note = String(
                localized: "The target has no table of this name, so the rows have nowhere to go."
            )
        } else if request.content.includesData, pairs.isEmpty {
            self.note = String(localized: "The source and the target share no writable column.")
        } else {
            self.note = nil
        }
    }

    /// The columns the copy writes, paired source spelling to target spelling.
    ///
    /// The source's own order, without the ones the server computes: an `INSERT` into a generated
    /// column is rejected by every engine that has them. When the target's structure is not being
    /// written the answer narrows to what both sides have, matched without regard to case, because
    /// a column the target lacks cannot be written to and one it has that the source lacks keeps
    /// its default.
    static func writableColumnPairs(
        snapshot: TableStructureSnapshot,
        targetSnapshot: TableStructureSnapshot?
    ) -> [(source: String, target: String)] {
        let sourceColumns = snapshot.columns
            .filter { $0.generationExpression == nil }
            .map(\.name)
        guard let targetSnapshot else { return sourceColumns.map { ($0, $0) } }
        var targetByFoldedName: [String: String] = [:]
        for column in targetSnapshot.columns where column.generationExpression == nil {
            targetByFoldedName[column.name.lowercased()] = column.name
        }
        return sourceColumns.compactMap { name in
            guard let target = targetByFoldedName[name.lowercased()] else { return nil }
            return (name, target)
        }
    }
}

private struct ObjectCopyDDLInput: Sendable {
    let id: String
    let snapshot: TableStructureSnapshot
    let targetSchema: String?
    let writesStructure: Bool
    let dropsFirst: Bool
    let emptiesFirst: Bool
}

private struct ObjectCopyTableDDL: Sendable {
    var drop: [SyncStatement] = []
    var create: [SyncStatement] = []
    var truncate: [SyncStatement] = []
}

internal enum ObjectCopyError: LocalizedError {
    case refused(String)

    internal var errorDescription: String? {
        switch self {
        case .refused(let message): return message
        }
    }
}

/// The read side of a table copy: the exact columns that will be written, in the order they will be
/// written, so the stream and the INSERT cannot drift apart.
internal enum ObjectCopySelectQuery {
    internal static func build(
        columns: [String],
        table: String,
        schema: String?,
        driver: any PluginDatabaseDriver
    ) -> String {
        let list = columns.isEmpty
            ? "*"
            : columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        return "SELECT \(list) FROM \(qualified(table, schema, driver))"
    }

    private static func qualified(_ table: String, _ schema: String?, _ driver: any PluginDatabaseDriver) -> String {
        guard let schema, !schema.isEmpty else { return driver.quoteIdentifier(table) }
        return "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(table))"
    }
}
