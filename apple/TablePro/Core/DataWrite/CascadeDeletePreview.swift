import Foundation
import os
import TableProPluginKit

struct CascadeDeletePreview: Equatable, Sendable {
    enum Count: Equatable, Sendable {
        case rows(Int)
        case unknown
    }

    struct Line: Equatable, Sendable {
        let table: String
        let kind: CascadeEffect.Kind
        let constraints: [String]
        let count: Count
        let filterCondition: String?
    }

    // What the lines leave out.
    enum Gap: Hashable, Sendable {
        case tablesPastDepthLimit
        case keysNotFollowed
        case otherSchemas
        // Counts come from another connection, which cannot see the session's uncommitted rows.
        case openTransaction
        case keyColumnsEdited
        // "Ignore foreign key checks" on a staged table operation turns them off for the save, when it can.
        case checksTurnedOff
    }

    enum Outcome: Equatable, Sendable {
        case checked(lines: [Line], gaps: Set<Gap>)
        case notEnforced
        case unavailable
    }

    let outcome: Outcome
}

@MainActor
enum CascadeDeletePreviewer {
    struct Environment {
        var slot: EngineNamespaceSlot
        var tableNames: CascadeTableNames
        var checksTurnedOffBySave = false
        var dialect: CascadeSQLDialect
        var readForeignKeys: @MainActor () async throws -> [String: [ForeignKeyInfo]]
        // Nil for an engine without schemas. The keys read are the ones declared in the table's own schema.
        var readHasOtherSchemas: (@MainActor () async throws -> Bool)?
        // Nil when the counts run on the save's own connection and so see what it sees.
        var readHoldsTransaction: (@MainActor () async -> Bool)?
        // Nil for an engine whose sessions cannot switch foreign keys off.
        var readEnforcement: (@MainActor () async throws -> Bool)?
        var count: @MainActor (String) async throws -> Int
    }

    // An alert that takes longer than this to appear reads as a Save that hung.
    static let budget: Duration = .seconds(5)

    private static let logger = Logger(subsystem: "com.TablePro", category: "CascadeDeletePreview")

    // Nil when no foreign key can point at the table, so the prompt has nothing to add.
    static func preview(
        of root: CascadeDeleteRoot,
        in scope: DatabaseScope,
        environment: Environment,
        budget: Duration = budget,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> CascadeDeletePreview? {
        let progress = Progress()
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish = Once(continuation)
            work = Task { @MainActor in
                await run(root: root, scope: scope, environment: environment, progress: progress)
                finish.fire()
            }
            timer = Task { @MainActor in
                try? await clock.sleep(for: budget)
                finish.fire()
            }
        }
        work?.cancel()
        timer?.cancel()
        return progress.preview
    }

    private static func run(
        root: CascadeDeleteRoot,
        scope: DatabaseScope,
        environment: Environment,
        progress: Progress
    ) async {
        let foreignKeys: [String: [ForeignKeyInfo]]
        do {
            foreignKeys = try await environment.readForeignKeys()
        } catch {
            logger.info("[cascade] foreign key read failed: \(error.publicLogShape, privacy: .public)")
            progress.state = .failed
            return
        }
        var gaps: Set<CascadeDeletePreview.Gap> = []
        if let readHasOtherSchemas = environment.readHasOtherSchemas,
           (try? await readHasOtherSchemas()) ?? true {
            gaps.insert(.otherSchemas)
        }
        guard !Task.isCancelled else { return }

        let keys = ReferencingKey.keys(from: foreignKeys, pointingInto: scope, slot: environment.slot)
        let rootName = environment.tableNames.key(root.table)
        guard keys.contains(where: { environment.tableNames.key($0.referencedTable) == rootName }) else {
            progress.state = .unreferenced(gaps: gaps)
            return
        }

        if root.editsKeyColumns(of: keys, tableNames: environment.tableNames) { gaps.insert(.keyColumnsEdited) }
        if environment.checksTurnedOffBySave { gaps.insert(.checksTurnedOff) }
        let plan = CascadeDeletePlan.walk(root: root, keys: keys, tableNames: environment.tableNames)
        let conditions = plan.effects.map { effect in
            CascadeDeleteSQL.condition(
                for: effect,
                excluding: plan.rowsDeletedAnyway(alongside: effect, root: root),
                dialect: environment.dialect
            )
        }
        if plan.stoppedAtDepth { gaps.insert(.tablesPastDepthLimit) }
        if plan.leftKeysUnfollowed { gaps.insert(.keysNotFollowed) }
        progress.state = .planned(plan, conditions: conditions, gaps: gaps)

        if let readEnforcement = environment.readEnforcement {
            do {
                if try await readEnforcement() == false {
                    progress.state = .notEnforced
                    return
                }
            } catch {
                logger.info("[cascade] enforcement read failed: \(error.publicLogShape, privacy: .public)")
            }
        }
        if let readHoldsTransaction = environment.readHoldsTransaction, await readHoldsTransaction() {
            gaps.insert(.openTransaction)
            progress.state = .planned(plan, conditions: conditions, gaps: gaps)
        }

        for (index, effect) in plan.effects.enumerated() {
            guard !Task.isCancelled else { return }
            guard let condition = conditions[index] else { continue }
            let query = CascadeDeleteSQL.countQuery(table: effect.table, condition: condition, dialect: environment.dialect)
            do {
                progress.counts[index] = .rows(try await environment.count(query))
            } catch {
                logger.info("[cascade] count failed: \(error.publicLogShape, privacy: .public)")
            }
        }
    }

    @MainActor
    private final class Progress {
        enum State {
            case reading
            case failed
            case unreferenced(gaps: Set<CascadeDeletePreview.Gap>)
            case planned(CascadeDeletePlan, conditions: [String?], gaps: Set<CascadeDeletePreview.Gap>)
            case notEnforced
        }

        var state = State.reading
        var counts: [Int: CascadeDeletePreview.Count] = [:]

        var preview: CascadeDeletePreview? {
            switch state {
            case .reading, .failed:
                return CascadeDeletePreview(outcome: .unavailable)
            case .unreferenced(let gaps):
                guard !gaps.isEmpty else { return nil }
                return CascadeDeletePreview(outcome: .checked(lines: [], gaps: gaps))
            case .notEnforced:
                return CascadeDeletePreview(outcome: .notEnforced)
            case .planned(let plan, let conditions, let gaps):
                let lines = plan.effects.enumerated().compactMap { index, effect -> CascadeDeletePreview.Line? in
                    let count = counts[index] ?? .unknown
                    if count == .rows(0) { return nil }
                    // A raw filter the validator refuses is dropped, and the tab would show every row.
                    let filter = conditions[index].flatMap { SQLBoundaryValidator.isRawFilterConditionSafe($0) ? $0 : nil }
                    return CascadeDeletePreview.Line(
                        table: effect.table,
                        kind: effect.kind,
                        constraints: effect.constraints,
                        count: count,
                        filterCondition: filter
                    )
                }
                return CascadeDeletePreview(outcome: .checked(lines: lines, gaps: gaps))
            }
        }
    }

    @MainActor
    private final class Once {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func fire() {
            continuation?.resume()
            continuation = nil
        }
    }
}

extension CascadeDeletePreviewer.Environment {
    // Only drivers that read every key in one query: the per-table fallback costs a round trip per table.
    @MainActor
    static func live(scope: DatabaseScope, databaseType: DatabaseType) -> Self? {
        let manager = DatabaseManager.shared
        guard let driver = manager.driver(for: scope.connectionId), driver.providesBulkForeignKeyFetch else {
            return nil
        }
        // Foreign key enforcement is a per-connection setting, so it is read where the DELETE will run.
        let saveRoute = manager.executionRoute(for: scope)
        // A cancelled statement inside a PostgreSQL transaction aborts it, so counts stay off the user's session.
        let countRoute = manager.metadataRoute(for: scope)
        let prefix = SQLStringLiteralPrefix.forDatabaseType(databaseType)
        let implicitSchema = databaseType.implicitSchemaName
        let schema = scope.schema
        let dialect = CascadeSQLDialect(
            quote: { driver.quoteIdentifier($0) },
            qualifiedTable: {
                SchemaQualifiedName.render(
                    name: $0, schema: schema, implicitSchemaName: implicitSchema, quote: driver.quoteIdentifier
                )
            },
            textLiteral: { "\(prefix)'\(driver.escapeStringLiteral($0))'" }
        )

        @MainActor
        func scalar(_ query: String, on route: ScopedDriverRoute) async throws -> String? {
            try await manager.withCancellableRead(scope: scope, route: route) { driver in
                try await driver.execute(query: query).rows.first?.first?.asText
            }
        }

        var readEnforcement: (@MainActor () async throws -> Bool)?
        if let query = CascadeDeletePreviewer.foreignKeyEnforcementQuery(for: databaseType) {
            readEnforcement = { try await scalar(query, on: saveRoute) != "0" }
        }
        var readHoldsTransaction: (@MainActor () async -> Bool)?
        if countRoute != saveRoute {
            // Through the scope, so a database parked on a lane of its own answers for itself.
            readHoldsTransaction = {
                let state = try? await manager.withScopedDriver(
                    scope: scope,
                    route: saveRoute,
                    cancellation: .untracked
                ) { driver in
                    await driver.heldSessionTransactionState()
                }
                return state == .inTransaction || state == .abortedTransaction
            }
        }
        let slot = EngineNamespaceSlot(databaseType: databaseType)
        var readHasOtherSchemas: (@MainActor () async throws -> Bool)?
        if slot == .schema, let ownSchema = scope.schema {
            let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: databaseType))
            readHasOtherSchemas = {
                let schemas = try await manager.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchSchemas()
                }
                return schemas.contains { $0 != ownSchema && !systemSchemas.contains($0) }
            }
        }
        return Self(
            slot: slot,
            tableNames: CascadeTableNames(databaseType: databaseType),
            dialect: dialect,
            readForeignKeys: {
                try await manager.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchAllForeignKeys(schema: scope.schema)
                }
            },
            readHasOtherSchemas: readHasOtherSchemas,
            readHoldsTransaction: readHoldsTransaction,
            readEnforcement: readEnforcement,
            count: { query in
                guard let value = try await scalar(query, on: countRoute).flatMap({ Int($0) }) else {
                    throw DatabaseError.queryFailed("COUNT(*) returned no number")
                }
                return value
            }
        )
    }
}

// SQLite and SQL Server find a table whatever the case of its name, and a REFERENCES clause keeps
// the spelling it was written in, so a key can name its parent in another case.
struct CascadeTableNames: Equatable, Sendable {
    let ignoresCase: Bool

    func key(_ table: String) -> String {
        ignoresCase ? table.lowercased() : table
    }
}

extension CascadeTableNames {
    nonisolated init(databaseType: DatabaseType) {
        switch TransactionEngineFamily.of(databaseType) {
        case .sqlite, .sqlServer: ignoresCase = true
        default: ignoresCase = false
        }
    }
}

extension CascadeDeletePreviewer {
    // A session on these engines can turn its keys off, and then nothing cascades.
    nonisolated static func foreignKeyEnforcementQuery(for databaseType: DatabaseType) -> String? {
        switch TransactionEngineFamily.of(databaseType) {
        case .sqlite: return "PRAGMA foreign_keys"
        case .mysql: return "SELECT @@foreign_key_checks"
        default: return nil
        }
    }
}
