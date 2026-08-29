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

        /// One pass per source namespace. A database-level copy on PostgreSQL spans every schema,
        /// and each schema's tables have to be read, ordered and written in their own scope: one
        /// read against a nil schema answers only whatever the connection is currently on.
        var skipped: [ObjectCopySkip] = []
        var tableSteps: [ObjectCopyTableStep] = []
        var definitionSteps: [ObjectCopyDefinitionStep] = []
        var targetNamespaces: [String] = []
        /// The target catalog is one read per distinct target endpoint, not one per source scope.
        /// A copy into a chosen target resolves every scope to the same endpoint, so a database
        /// with twelve schemas read the same catalog twelve times.
        var targetObjectsByEndpoint: [String: [String: ObjectCopySelection]] = [:]

        for scope in Self.scopes(of: request) {
            let names = Set(scope.objects.map(\.name))
            let sourceEndpoint = request.source.withSchema(scope.namespace)
            let targetEndpoint = request.target.withSchema(scope.targetNamespace(for: request))
            if let namespace = targetEndpoint.schema?.nilIfEmpty, !targetNamespaces.contains(namespace) {
                targetNamespaces.append(namespace)
            }

            let sourceReads = try await metadata.tableReads(
                for: sourceEndpoint, connection: connections.source, includeViews: true, names: names
            )
            let targetReads = try await existingTargetReads(
                request, endpoint: targetEndpoint, connection: connections.target, names: names
            )
            var targetObjects: [String: ObjectCopySelection] = [:]
            /// Only the definition steps read it, and only when structure takes part, so a
            /// data-only copy never pays for a catalog it would discard unread.
            if request.content.includesStructure {
                if let cached = targetObjectsByEndpoint[targetEndpoint.id] {
                    targetObjects = cached
                } else {
                    targetObjects = try await existingTargetObjects(
                        request, endpoint: targetEndpoint, connection: connections.target
                    )
                    targetObjectsByEndpoint[targetEndpoint.id] = targetObjects
                }
            }

            tableSteps += try await buildTableSteps(
                request,
                scope: scope,
                sourceEndpoint: sourceEndpoint,
                targetEndpoint: targetEndpoint,
                sourceReads: sourceReads,
                targetReads: targetReads,
                skipped: &skipped
            )
            definitionSteps += try await buildDefinitionSteps(
                request,
                scope: scope,
                sourceEndpoint: sourceEndpoint,
                targetEndpoint: targetEndpoint,
                sourceReads: sourceReads,
                targetObjects: targetObjects,
                connection: connections.source,
                skipped: &skipped
            )
        }

        return ObjectCopyPlan(
            request: request,
            createsDatabase: request.destination.createsDatabase,
            tableSteps: tableSteps,
            definitionSteps: definitionSteps,
            schemaStatements: try await buildSchemaStatements(request, namespaces: targetNamespaces),
            skipped: skipped
        )
    }

    /// The schemas a duplicated database needs before its first `CREATE TABLE` names one.
    ///
    /// `CREATE DATABASE` gives the new database whatever schema its engine gives it, and a
    /// duplicate keeps every source schema name, so a PostgreSQL database with a `sales` schema
    /// produced `CREATE TABLE "sales"."invoices"` against a database that had only `public`. The
    /// structure phase then rolled back with the database already created, leaving a duplicate that
    /// held nothing and could not be retried without deleting it first.
    ///
    /// Only for a run that creates the database: copying into one the user chose means its schemas
    /// are the user's to make, and creating one silently would put objects somewhere they did not
    /// ask for. A driver with no single statement for it answers nil and the copy is left as it
    /// was, rather than being handed DDL the server would reject.
    private func buildSchemaStatements(
        _ request: ObjectCopyRequest,
        namespaces: [String]
    ) async throws -> [SyncStatement] {
        guard request.destination.createsDatabase, !namespaces.isEmpty else { return [] }
        return try await manager.withMetadataDriver(
            scope: targetScope(request, endpoint: request.target)
        ) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else { return [] }
            return namespaces.compactMap { name in
                guard let sql = plugin.createSchemaStatement(name: name) else { return nil }
                return SyncStatement(
                    sql: sql.hasSuffix(";") ? sql : sql + ";",
                    objectName: name,
                    summary: String(format: String(localized: "Create schema %@"), name)
                )
            }
        }
    }

    /// The selected objects grouped by the namespace they were found in.
    internal struct Scope {
        internal let namespace: String?
        internal let objects: [ObjectCopySelection]

        /// Where this namespace's objects land. A duplicate keeps every schema name, so its
        /// objects go into a schema of the same name in the new database; a copy to a chosen
        /// target puts them all in the schema that was chosen.
        internal func targetNamespace(for request: ObjectCopyRequest) -> String? {
            request.destination.createsDatabase ? namespace : request.target.schema
        }
    }

    nonisolated internal static func scopes(of request: ObjectCopyRequest) -> [Scope] {
        var order: [String] = []
        var grouped: [String: [ObjectCopySelection]] = [:]
        for object in request.objects {
            let key = object.schema ?? ""
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(object)
        }
        return order.map { Scope(namespace: $0.isEmpty ? nil : $0, objects: grouped[$0] ?? []) }
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
        endpoint: DatabaseEndpoint,
        connection: DatabaseConnection,
        names: Set<String>
    ) async throws -> [TableStructureRead] {
        guard !request.destination.createsDatabase else { return [] }
        return try await metadata.tableReads(
            for: endpoint, connection: connection, includeViews: true, names: names
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
        endpoint: DatabaseEndpoint,
        connection: DatabaseConnection
    ) async throws -> [String: ObjectCopySelection] {
        guard !request.destination.createsDatabase else { return [:] }
        let found = try await catalog.objects(in: endpoint, connection: connection)
        return Dictionary(
            found.map { (Self.objectKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
        scope: Scope,
        sourceEndpoint: DatabaseEndpoint,
        targetEndpoint: DatabaseEndpoint,
        sourceReads: [TableStructureRead],
        targetReads: [TableStructureRead],
        skipped: inout [ObjectCopySkip]
    ) async throws -> [ObjectCopyTableStep] {
        var reads: [ObjectCopySelection: TableStructureRead] = [:]
        for selection in scope.objects.filter({ $0.kind.carriesRows }) {
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

        /// The engine's own namespace, not the endpoint's schema. MySQL reports no schema on a
        /// table while its foreign keys carry the database name, so ordering by the schema alone
        /// matched no edge and fell through to alphabetical order.
        let sourceNamespace = ObjectCopyNamespace.name(for: sourceEndpoint)
        let targetNamespace = ObjectCopyNamespace.name(for: targetEndpoint)
        /// Seeded from the user's own order, not from `reads.keys`. Swift seeds Dictionary hashing
        /// per process, so taking the keys gave the tables with no foreign key between them a
        /// different tie-break on every launch: the approved script, the progress order and the
        /// outcome list were all shuffled differently for the same copy.
        var drafts: [ObjectCopyTableDraft] = []
        for selection in Self.orderedByDependency(
            scope.objects.filter { reads[$0] != nil }, reads: reads, effectiveSchema: sourceNamespace
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
                read: read,
                snapshot: snapshot,
                targetSnapshot: targetRead?.snapshot,
                existsInTarget: existsInTarget,
                sourceSchema: sourceEndpoint.schema ?? read.table.schema,
                targetSchema: targetEndpoint.schema,
                request: request
            ))
        }
        guard !drafts.isEmpty else { return [] }

        let sourceParts = try await readSourceParts(drafts, endpoint: sourceEndpoint)
        let ddl = try await buildTargetDDL(
            drafts,
            request: request,
            targetEndpoint: targetEndpoint,
            sourceNamespace: sourceNamespace,
            targetNamespace: targetNamespace
        )
        return drafts.map { draft in
            let parts = sourceParts[draft.selection.id]
            let statements = ddl[draft.selection.id] ?? ObjectCopyTableDDL()
            return ObjectCopyTableStep(
                selection: draft.selection,
                dropStatements: statements.drop,
                sequenceStatements: Self.sequenceStatements(
                    parts?.sequences ?? [], table: draft.targetTable
                ),
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
        let sequences: [String]
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
            (
                id: $0.selection.id,
                table: $0.snapshot.name,
                schema: $0.sourceSchema,
                columns: $0.sourceColumns,
                copiesData: $0.copiesData,
                writesStructure: $0.writesStructure
            )
        }
        guard inputs.contains(where: { $0.copiesData || $0.writesStructure }) else { return [:] }
        return try await manager.withMetadataDriver(scope: endpoint.scope, workload: .bulk) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noSourceDriver)
            }
            var parts: [String: SourceParts] = [:]
            /// A sequence several tables default from is created once, under the first of them,
            /// which the dependency order has already put ahead of the rest.
            var claimedSequences: Set<String> = []
            for input in inputs {
                try Task.checkCancellation()
                var query = ""
                var estimatedRows: Int?
                /// Only the tables whose rows are actually copied. Teradata implements the row
                /// estimate as `SELECT COUNT(*)`, so preparing every draft made reviewing a
                /// structure-only copy scan every table it named.
                if input.copiesData {
                    query = ObjectCopySelectQuery.build(
                        columns: input.columns, table: input.table, schema: input.schema, driver: plugin
                    )
                    estimatedRows = (try? await plugin.fetchApproximateRowCount(
                        table: input.table, schema: input.schema
                    )) ?? nil
                }
                var sequences: [String] = []
                if input.writesStructure {
                    let found = (try? await plugin.fetchDependentSequences(
                        table: input.table, schema: input.schema
                    )) ?? []
                    for sequence in found
                    where claimedSequences.insert(sequence.name.lowercased()).inserted {
                        sequences += SQLStatementScanner.allStatements(in: sequence.ddl)
                    }
                }
                parts[input.id] = SourceParts(
                    query: query, estimatedRows: estimatedRows, sequences: sequences
                )
            }
            return parts
        }
    }

    /// A copied table's default names its sequence, so the sequence has to be there before the
    /// `CREATE TABLE` runs.
    ///
    /// PostgreSQL renders a `SERIAL` column as `integer ... DEFAULT nextval('orders_id_seq')`, and
    /// the driver keeps that text verbatim. Copied without the sequence it names, the table either
    /// fails to be created at all or, where the source's own sequence happens to be reachable, is
    /// created sharing it, so the copy and the original hand out the same keys.
    nonisolated internal static func sequenceStatements(
        _ sql: [String],
        table: String
    ) -> [SyncStatement] {
        sql.map { statement in
            SyncStatement(
                sql: statement.hasSuffix(";") ? statement : statement + ";",
                objectName: table,
                summary: String(format: String(localized: "Create the sequences %@ defaults from"), table)
            )
        }
    }

    private func buildTargetDDL(
        _ drafts: [ObjectCopyTableDraft],
        request: ObjectCopyRequest,
        targetEndpoint: DatabaseEndpoint,
        sourceNamespace: String?,
        targetNamespace: String?
    ) async throws -> [String: ObjectCopyTableDDL] {
        let inputs = drafts.map {
            ObjectCopyDDLInput(
                id: $0.selection.id,
                snapshot: Self.retargeted(
                    $0.snapshot, from: sourceNamespace, to: targetNamespace, schema: $0.targetSchema
                ),
                targetSchema: $0.targetSchema,
                writesStructure: $0.writesStructure,
                dropsFirst: $0.dropsFirst,
                emptiesFirst: $0.emptiesFirst,
                /// Rolling back is only promised where the run wraps the table in a transaction,
                /// and TRUNCATE commits implicitly on engines that offer it without transactional
                /// DDL, so a promise of rollback has to be kept with DELETE.
                clearsWithDelete: request.wrapEachTableInTransaction
                    && request.errorHandling != .skipAndContinue
            )
        }
        guard inputs.contains(where: { $0.writesStructure || $0.dropsFirst || $0.emptiesFirst })
        else { return [:] }

        return try await manager.withMetadataDriver(scope: targetScope(request, endpoint: targetEndpoint)) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let builder = SchemaSyncScriptBuilder(targetDriver: plugin)
            var result: [String: ObjectCopyTableDDL] = [:]
            for input in inputs {
                try Task.checkCancellation()
                var ddl = ObjectCopyTableDDL()
                if input.dropsFirst {
                    ddl.drop = Self.dropStatements(
                        table: input.snapshot.name,
                        schema: input.targetSchema,
                        builder: builder,
                        driver: plugin
                    )
                }
                if input.writesStructure {
                    ddl.create = try builder.build(
                        operations: [.createTable(input.snapshot)], foreignKeysByTable: [:]
                    )
                }
                if input.emptiesFirst {
                    ddl.truncate = Self.emptyStatements(
                        table: input.snapshot.name,
                        schema: input.targetSchema,
                        prefersDelete: input.clearsWithDelete,
                        driver: plugin
                    )
                }
                result[input.id] = ddl
            }
            return result
        }
    }

    /// The DROP a replacement needs, whatever the driver offers.
    ///
    /// `dropObjectStatement` has a protocol default of nil that MySQL, PostgreSQL, SQL Server,
    /// SQLite, Oracle, DuckDB and Trino all inherit, so the builder produced no drop at all and the
    /// CREATE that followed ran against the table that was still there. Replace was unusable on
    /// every core engine. A quoted `DROP TABLE` is the fallback, built with the driver's own
    /// quoting.
    nonisolated private static func dropStatements(
        table: String,
        schema: String?,
        builder: SchemaSyncScriptBuilder,
        driver: any PluginDatabaseDriver
    ) -> [SyncStatement] {
        let generated = (try? builder.build(
            operations: [.dropTable(name: table, schema: schema)], foreignKeysByTable: [:]
        )) ?? []
        guard generated.isEmpty else { return generated }
        return [SyncStatement(
            sql: "DROP TABLE \(qualified(table, schema, driver));",
            objectName: table,
            summary: String(format: String(localized: "Drop table %@"), table),
            hazards: SyncSafetyClassifier().hazards(forDropping: table)
        )]
    }

    nonisolated private static func qualified(
        _ name: String,
        _ schema: String?,
        _ driver: any PluginDatabaseDriver
    ) -> String {
        guard let schema, !schema.isEmpty else { return driver.quoteIdentifier(name) }
        return "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(name))"
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
        to targetSchema: String?,
        schema: String? = nil
    ) -> TableStructureSnapshot {
        let placedSchema = schema ?? targetSchema
        let source = (sourceSchema ?? "").lowercased()
        /// Hoisted out of the map: it names neither the key nor the snapshot, so a copy that stays
        /// in one namespace has nothing to move and can say so once instead of per foreign key.
        let movesReferences = source != (targetSchema ?? "").lowercased()
        let foreignKeys = !movesReferences ? snapshot.foreignKeys : snapshot.foreignKeys.map { key in
            let referenced = (key.referencedSchema ?? "").lowercased()
            guard referenced.isEmpty || referenced == source else { return key }
            var moved = key
            moved.referencedSchema = targetSchema
            return moved
        }
        return TableStructureSnapshot(
            name: snapshot.name,
            schema: placedSchema,
            columns: snapshot.columns,
            indexes: snapshot.indexes,
            foreignKeys: foreignKeys,
            engine: snapshot.engine,
            charset: snapshot.charset,
            collation: snapshot.collation
        )
    }

    /// What empties a table before its rows are written.
    ///
    /// DELETE whenever the run promises to roll the table back. TRUNCATE commits implicitly on the
    /// engines that offer it without transactional DDL, so a copy that failed afterwards rolled the
    /// new rows back and left the target's own gone for good.
    nonisolated private static func emptyStatements(
        table: String,
        schema: String?,
        prefersDelete: Bool,
        driver: any PluginDatabaseDriver
    ) -> [SyncStatement] {
        let qualified = qualified(table, schema, driver)
        let truncate = prefersDelete
            ? nil
            : driver.truncateTableStatements(table: table, schema: schema, cascade: false)?.first
        let sql = truncate ?? "DELETE FROM \(qualified)"
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
        scope: Scope,
        sourceEndpoint: DatabaseEndpoint,
        targetEndpoint: DatabaseEndpoint,
        sourceReads: [TableStructureRead],
        targetObjects: [String: ObjectCopySelection],
        connection: DatabaseConnection,
        skipped: inout [ObjectCopySkip]
    ) async throws -> [ObjectCopyDefinitionStep] {
        let selections = scope.objects.filter { $0.kind.isSourceDefined }
        guard !selections.isEmpty else { return [] }
        guard request.content.includesStructure else {
            skipped += selections.map { ObjectCopySkip(selection: $0, reason: Self.structureOnlyObject) }
            return []
        }

        let targetSchema = targetEndpoint.schema
        let sourceNamespace = ObjectCopyNamespace.name(for: sourceEndpoint)
        let targetNamespace = ObjectCopyNamespace.name(for: targetEndpoint)

        /// Asked once for the whole scope, and before anything is read. It depends only on the two
        /// namespaces, so a cross-namespace copy rejected every object anyway: asking per object
        /// first fetched every view body, routine body and trigger body from the source and then
        /// discarded all of them, and wrote one identical skip row per object where the scope has
        /// one reason.
        guard ObjectCopyEligibility.canCopyDefinition(
            sourceNamespace: sourceNamespace, targetNamespace: targetNamespace
        ) else {
            skipped += selections.map {
                ObjectCopySkip(selection: $0, reason: ObjectCopyEligibility.definitionNamespaceRefusal)
            }
            return []
        }

        let definitions = try await sourceDefinitions(
            sourceEndpoint: sourceEndpoint,
            selections: selections,
            sourceReads: sourceReads,
            connection: connection
        )
        var pending: [(selection: ObjectCopySelection, definition: String, target: ObjectCopySelection?)] = []
        for selection in Self.orderedByKind(selections) {
            guard let definition = definitions[selection.id],
                  !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped.append(ObjectCopySkip(selection: selection, reason: Self.noDefinition))
                continue
            }
            guard ObjectCopyEligibility.isExecutableDefinition(definition) else {
                skipped.append(ObjectCopySkip(
                    selection: selection, reason: ObjectCopyEligibility.definitionNotExecutableRefusal
                ))
                continue
            }
            let existing = targetObjects[Self.objectKey(for: selection)]
            /// Add rows promises the target's structure is kept, and these objects hold no rows at
            /// all, so replacing one would be pure destruction with nothing to gain by it.
            if existing != nil, request.existingPolicy != .replace {
                skipped.append(ObjectCopySkip(selection: selection, reason: Self.alreadyThere))
                continue
            }
            pending.append((selection, definition, existing))
        }
        guard !pending.isEmpty else { return [] }

        let inputs = pending.map { item in
            (
                id: item.selection.id,
                create: CompareObjectResult(
                    identity: CompareObjectIdentity(
                        kind: item.selection.kind,
                        schema: targetSchema ?? item.selection.schema,
                        name: item.selection.name,
                        signature: item.selection.signature
                    ),
                    status: .onlyInSource,
                    sourceDefinition: [item.definition]
                ),
                /// Dropped as the kind the target actually holds. A source view over a target
                /// materialized view emitted `DROP VIEW`, which those engines refuse.
                drop: item.target.map { target in
                    CompareObjectResult(
                        identity: CompareObjectIdentity(
                            kind: target.kind,
                            schema: targetSchema ?? target.schema,
                            name: target.name,
                            /// A trigger's owning table travels in the same slot a routine's
                            /// argument list does, which is the shape `triggerReads` already uses,
                            /// and is what lets PostgreSQL spell `DROP TRIGGER name ON table`.
                            signature: target.signature ?? target.owner
                        ),
                        status: .onlyInTarget
                    )
                }
            )
        }
        let built = try await manager.withMetadataDriver(
            scope: targetScope(request, endpoint: targetEndpoint)
        ) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw ObjectCopyError.refused(Self.noTargetDriver)
            }
            let builder = SourceObjectSyncBuilder(targetDriver: plugin)
            var statements: [String: (drop: [SyncStatement], create: [SyncStatement])] = [:]
            for input in inputs {
                let drop = input.drop.map { builder.build(for: $0, action: .drop) } ?? []
                let create = builder.build(for: input.create, action: .create)
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
        sourceEndpoint: DatabaseEndpoint,
        selections: [ObjectCopySelection],
        sourceReads: [TableStructureRead],
        connection: DatabaseConnection
    ) async throws -> [String: String] {
        var definitions: [String: String] = [:]

        let views = selections.filter { $0.kind == .view || $0.kind == .materializedView }
        if !views.isEmpty {
            let infos = sourceReads.map(\.table).filter { info in
                views.contains { $0.name.lowercased() == info.name.lowercased() }
            }
            for read in try await metadata.viewDefinitions(
                for: sourceEndpoint, connection: connection, views: infos
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
            for read in try await metadata.routineReads(for: sourceEndpoint, connection: connection) {
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
                for: sourceEndpoint, connection: connection, tables: Array(owners)
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
        var placed: Set<ObjectCopySelection> = []
        for node in ForeignKeyTopologicalSort.ordered(
            nodes, foreignKeysByTable: foreignKeysByTable, childrenFirst: false
        ) where emitted.insert(node.identifier).inserted {
            guard let selection = bySortKey[node.identifier] else { continue }
            result.append(selection)
            placed.insert(selection)
        }
        /// Membership against a set rather than the array being built. A database-wide copy of 500
        /// tables ran 125,000 equality checks here for a tail that is usually empty.
        for selection in selections where !placed.contains(selection) {
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
    private func targetScope(
        _ request: ObjectCopyRequest,
        endpoint: DatabaseEndpoint
    ) -> DatabaseScope {
        guard request.destination.createsDatabase else { return endpoint.scope }
        return DatabaseScope(connectionId: endpoint.connectionId, database: "", schema: nil)
    }

    /// Exact spelling first, and a folded match only when it is unambiguous. PostgreSQL allows
    /// quoted `Orders` and `orders` side by side, and folding first resolved both selections to
    /// whichever the driver happened to list first.
    private func match(_ selection: ObjectCopySelection, in reads: [TableStructureRead]) -> TableStructureRead? {
        if let exact = reads.first(where: { $0.table.name == selection.name }) { return exact }
        let folded = reads.filter { $0.table.name.lowercased() == selection.name.lowercased() }
        return folded.count == 1 ? folded[0] : nil
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
        read: TableStructureRead,
        snapshot: TableStructureSnapshot,
        targetSnapshot: TableStructureSnapshot?,
        existsInTarget: Bool,
        sourceSchema: String?,
        targetSchema: String?,
        request: ObjectCopyRequest
    ) {
        self.selection = selection
        self.snapshot = snapshot
        self.sourceSchema = sourceSchema
        /// Never the source's. A target endpoint that names no schema means the target driver's
        /// own current scope, and inheriting the source's put a SQL Server `dbo` into a MySQL
        /// INSERT, naming a database that engine does not have.
        self.targetSchema = targetSchema

        let keepsTargetStructure = existsInTarget && request.existingPolicy != .replace
        let writesStructure = request.content.includesStructure && !keepsTargetStructure
        self.writesStructure = writesStructure
        self.dropsFirst = writesStructure && existsInTarget

        /// The target's own name when it already has the table, because a case-insensitive match
        /// pairs `Orders` with `orders` and the INSERT has to quote the one that exists.
        self.targetTable = (writesStructure ? nil : targetSnapshot?.name) ?? snapshot.name

        /// Read from the driver's own columns rather than from the snapshot. SQL Server computed
        /// columns and ClickHouse ALIAS columns set `isGenerated` with no expression, and
        /// PostgreSQL reports identity through `identityKind`; the snapshot conversion keeps
        /// neither, so those columns looked ordinary and writable.
        let pairs = Self.writableColumnPairs(
            columns: read.columns,
            snapshot: snapshot,
            targetSnapshot: writesStructure ? nil : targetSnapshot
        )
        self.sourceColumns = pairs.map(\.source)
        self.targetColumns = pairs.map(\.target)
        let copiesData = request.content.includesData && !pairs.isEmpty && (writesStructure || existsInTarget)
        self.copiesData = copiesData

        /// A data-only replace has no DROP and CREATE to clear the table, so it is emptied instead,
        /// and only where rows are going back into it. Emptying without that condition deleted
        /// every row of a table whose columns the target does not share, and then wrote nothing:
        /// the step was dropped from the data phase for having no writable column while its DELETE
        /// stayed in the clear phase, and the review said only that the two sides shared no column.
        self.emptiesFirst = copiesData
            && existsInTarget
            && request.existingPolicy == .replace
            && !writesStructure

        let written = Set(pairs.map { $0.source.lowercased() })
        self.copiesIdentityColumn = request.content.includesData && read.columns.contains {
            written.contains($0.name.lowercased()) && ($0.isIdentity || $0.extra?.lowercased().contains("auto_increment") == true)
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
        columns: [PluginColumnInfo],
        snapshot: TableStructureSnapshot,
        targetSnapshot: TableStructureSnapshot?
    ) -> [(source: String, target: String)] {
        let generated = Set(columns.filter(\.isGenerated).map { $0.name.lowercased() })
        let sourceColumns = snapshot.columns
            .filter { $0.generationExpression == nil && !generated.contains($0.name.lowercased()) }
            .map(\.name)
        guard let targetSnapshot else { return sourceColumns.map { ($0, $0) } }

        /// Exact spellings first. PostgreSQL allows quoted `Orders` and `orders` in one schema, so
        /// folding case unconditionally resolved either to whichever row came back first.
        var exact: [String: String] = [:]
        var folded: [String: [String]] = [:]
        for column in targetSnapshot.columns where column.generationExpression == nil {
            exact[column.name] = column.name
            folded[column.name.lowercased(), default: []].append(column.name)
        }
        return sourceColumns.compactMap { name in
            if let target = exact[name] { return (name, target) }
            guard let candidates = folded[name.lowercased()], candidates.count == 1 else { return nil }
            return (name, candidates[0])
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
    let clearsWithDelete: Bool
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
