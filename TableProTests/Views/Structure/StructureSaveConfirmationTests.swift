//
//  StructureSaveConfirmationTests.swift
//  TableProTests
//
//  A Structure save is confirmed once. The execution gate's sheet is that confirmation for an
//  ALTER save and the rebuild review is that confirmation for a rebuild; the editor used to ask
//  first with an alert of its own, which made one decision two dialogs, and three with Touch ID.
//  Every case runs the request the app builds through the real gate, with prompts that count.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class MySQLShapedDDLDriver: PluginDatabaseDriver, @unchecked Sendable {
    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE `\(table)` ADD COLUMN `\(column.name)` \(column.dataType)"
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        let nullability = newColumn.isNullable ? "NULL" : "NOT NULL"
        return "ALTER TABLE `\(table)` CHANGE COLUMN `\(oldColumn.name)` `\(newColumn.name)` "
            + "\(newColumn.dataType) \(nullability)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE `\(table)` DROP COLUMN `\(columnName)`"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX `\(indexName)` ON `\(table)`"
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        "ALTER TABLE `\(table)` ADD CONSTRAINT `\(constraint.name)` CHECK (\(constraint.expression))"
    }

    func generateModifyPrimaryKeySQL(
        table: String,
        oldColumns: [String],
        newColumns: [String],
        constraintName: String?
    ) -> [String]? {
        [
            "ALTER TABLE `\(table)` DROP PRIMARY KEY",
            "ALTER TABLE `\(table)` ADD PRIMARY KEY (\(newColumns.map { "`\($0)`" }.joined(separator: ", ")))"
        ]
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

private struct StructureSave {
    let name: String
    let change: SchemaChange
    let isDestructive: Bool
}

private struct ServerRejection: LocalizedError {
    var errorDescription: String? { "Duplicate column name 'notes'" }
}

@MainActor
struct StructureSaveConfirmationTests {
    private static let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)

    private static func column(
        _ name: String,
        type: String = "VARCHAR(255)",
        isNullable: Bool = true
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(),
            name: name,
            dataType: type,
            isNullable: isNullable,
            defaultValue: nil,
            autoIncrement: false,
            unsigned: false,
            comment: nil,
            collation: nil,
            onUpdate: nil,
            charset: nil,
            extra: nil,
            isPrimaryKey: false
        )
    }

    private static var saves: [StructureSave] {
        let email = column("email")
        return [
            StructureSave(name: "add column", change: .addColumn(column("notes", type: "TEXT")), isDestructive: false),
            StructureSave(
                name: "rename column",
                change: .modifyColumn(old: email, new: column("contact_email")),
                isDestructive: false
            ),
            StructureSave(name: "drop column", change: .deleteColumn(email), isDestructive: true),
            StructureSave(
                name: "type change",
                change: .modifyColumn(old: email, new: column("email", type: "VARCHAR(32)")),
                isDestructive: true
            ),
            StructureSave(
                name: "NOT NULL",
                change: .modifyColumn(old: email, new: column("email", isNullable: false)),
                isDestructive: true
            ),
            StructureSave(
                name: "add check constraint",
                change: .addCheckConstraint(
                    EditableCheckConstraintDefinition(
                        id: UUID(), name: "chk_email", expression: "email LIKE '%@%'", columns: ["email"], isValidated: true
                    )
                ),
                isDestructive: true
            ),
            StructureSave(
                name: "primary key change",
                change: .modifyPrimaryKey(old: ["id"], new: ["id", "tenant_id"]),
                isDestructive: true
            ),
            StructureSave(
                name: "drop index",
                change: .deleteIndex(
                    EditableIndexDefinition(
                        id: UUID(), name: "idx_email", columns: ["email"], type: .btree,
                        isUnique: false, isPrimary: false, comment: nil
                    )
                ),
                isDestructive: true
            )
        ]
    }

    private static func gate(
        _ level: SafeModeLevel,
        confirm: StubConfirming,
        auth: StubAuthenticating
    ) -> DefaultExecutionGate {
        DefaultExecutionGate(
            confirming: confirm,
            authenticating: auth,
            safeModeLevelResolver: { _ in level },
            forcesWriteResolver: { _ in false },
            auditLog: ExecutionAuditLog(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("structure-save-audit-\(UUID().uuidString).json")
            )
        )
    }

    private static func asksForConfirmation(_ level: SafeModeLevel, isDestructive: Bool) -> Bool {
        switch level {
        case .silent: isDestructive
        case .alert, .alertFull, .safeMode, .safeModeFull: true
        case .readOnly: false
        }
    }

    private static func asksForAuthentication(_ level: SafeModeLevel) -> Bool {
        level == .safeMode || level == .safeModeFull
    }

    // MARK: - ALTER saves

    @Test("Every ALTER save asks at most once, and a destructive one asks at every level but Read-Only")
    func alterSavesAskOnce() async throws {
        let generator = SchemaStatementGenerator(tableName: "users", pluginDriver: MySQLShapedDDLDriver())
        for save in Self.saves {
            let statements = try generator.generate(changes: [save.change])
            let request = DatabaseManager.schemaChangeAuthorizationRequest(
                statements, databaseType: .mysql, scope: Self.scope
            )
            for level in SafeModeLevel.allCases {
                let confirm = StubConfirming(answer: true)
                let auth = StubAuthenticating(answer: true)
                let decision = await Self.gate(level, confirm: confirm, auth: auth).authorize(request)
                let label = "\(save.name) at \(level.rawValue)"

                guard level != .readOnly else {
                    #expect(!decision.isAuthorized, "\(label) must be refused")
                    #expect(confirm.callCount == 0, "\(label) must be refused without asking")
                    #expect(auth.callCount == 0, "\(label) must be refused without Touch ID")
                    continue
                }
                let asks = Self.asksForConfirmation(level, isDestructive: save.isDestructive)
                #expect(decision.isAuthorized, "\(label) must run once answered")
                #expect(confirm.callCount == (asks ? 1 : 0), "\(label) asked \(confirm.callCount) times")
                #expect(auth.callCount == (Self.asksForAuthentication(level) ? 1 : 0), "\(label) Touch ID")
                if asks {
                    #expect(confirm.lastDestructive == save.isDestructive, "\(label) warning")
                }
            }
        }
    }

    /// `CHANGE COLUMN .. NOT NULL`, a type change and an added `CHECK` read as plain writes, so the
    /// gate can only see what they risk if the statements say so. A dropped index is destructive by
    /// its own `DROP` and needs no mark.
    @Test("A change that can lose or refuse existing rows marks every statement it generates")
    func dataLossIsStampedOnTheStatements() throws {
        let stamped: Set<String> = ["drop column", "type change", "NOT NULL", "add check constraint", "primary key change"]
        let generator = SchemaStatementGenerator(tableName: "users", pluginDriver: MySQLShapedDDLDriver())
        for save in Self.saves {
            let statements = try generator.generate(changes: [save.change])
            let expected = stamped.contains(save.name)
            #expect(!statements.isEmpty)
            #expect(
                statements.allSatisfy { $0.isDestructive == expected },
                "\(save.name) statements must be marked \(expected)"
            )
        }
    }

    @Test("A Cancel at the gate's sheet comes back as a Cancel, not a refusal")
    func cancelAtTheSheetIsACancel() async throws {
        let generator = SchemaStatementGenerator(tableName: "users", pluginDriver: MySQLShapedDDLDriver())
        let statements = try generator.generate(changes: [.deleteColumn(Self.column("email"))])
        let request = DatabaseManager.schemaChangeAuthorizationRequest(
            statements, databaseType: .mysql, scope: Self.scope
        )
        let decision = await Self.gate(
            .silent,
            confirm: StubConfirming(answer: false),
            auth: StubAuthenticating(answer: true)
        ).authorize(request)

        let error = try #require(decision.denialError)
        #expect(StructureApplyFailure(error) == .cancelledByUser)
    }

    @Test("A declined Touch ID is a refusal that says why, not a quiet Cancel")
    func declinedAuthenticationIsARefusal() async throws {
        let generator = SchemaStatementGenerator(tableName: "users", pluginDriver: MySQLShapedDDLDriver())
        let statements = try generator.generate(changes: [.deleteColumn(Self.column("email"))])
        let request = DatabaseManager.schemaChangeAuthorizationRequest(
            statements, databaseType: .mysql, scope: Self.scope
        )
        let decision = await Self.gate(
            .safeMode,
            confirm: StubConfirming(answer: true),
            auth: StubAuthenticating(answer: false)
        ).authorize(request)

        let error = try #require(decision.denialError)
        let failure = StructureApplyFailure(error)
        #expect(failure.outcome == .refused)
        #expect(failure.message != nil)
        #expect(!failure.reportsFailure)
    }

    // MARK: - Rebuilds

    private static func plan(cost: PluginColumnReorderCost) -> PluginColumnReorderPlan {
        switch cost {
        case .metadataOnly:
            PluginColumnReorderPlan(
                statements: ["ALTER TABLE `users` MODIFY COLUMN `email` VARCHAR(255) AFTER `id`"],
                cost: .metadataOnly,
                verifications: []
            )
        default:
            PluginColumnReorderPlan(
                statements: [
                    "CREATE TABLE \"_album_new\" (\"id\" INTEGER PRIMARY KEY, \"artist_id\" INTEGER)",
                    "INSERT INTO \"_album_new\" SELECT \"id\", \"artist_id\" FROM \"album\"",
                    "DROP TABLE \"album\"",
                    "ALTER TABLE \"_album_new\" RENAME TO \"album\""
                ],
                isTransactional: true,
                cost: .tableRebuild,
                verifications: []
            )
        }
    }

    @Test("A review that can run the rebuild warns of data loss ahead of its caveats, and a preview does not")
    func runnableRebuildReviewWarnsOfDataLoss() {
        let action = TableRebuildReviewRequest.Action(
            title: "Apply", operationDescription: "Apply Schema Changes", perform: {}
        )
        let rebuild = Self.plan(cost: .tableRebuild)
        let caveat = "Triggers on album are not recreated."
        let withCaveat = PluginColumnReorderPlan(
            statements: rebuild.statements, isTransactional: true, cost: .tableRebuild, caveats: [caveat], verifications: []
        )
        let dataWarning = OperationConfirmationPrompt.destructiveDataWarning

        let runnable = TableRebuildReviewRequest(tableName: "album", scope: Self.scope, plan: rebuild, action: action)
        #expect(runnable.warning == dataWarning)

        let runnableWithCaveat = TableRebuildReviewRequest(
            tableName: "album", scope: Self.scope, plan: withCaveat, action: action
        )
        #expect(runnableWithCaveat.warning == "\(dataWarning) \(caveat)")

        let preview = TableRebuildReviewRequest(tableName: "album", scope: Self.scope, plan: rebuild, action: nil)
        #expect(preview.warning == nil)
    }

    @Test("A rebuild the review sheet confirmed is not confirmed again, and still asks for Touch ID")
    func reviewedRebuildIsConfirmedOnce() async {
        let request = StructureRebuildPlanRunner.authorizationRequest(
            plan: Self.plan(cost: .tableRebuild),
            scope: Self.scope,
            databaseType: .sqlite,
            operationDescription: "Apply Schema Changes",
            isConfirmationPreCleared: true
        )
        for level in SafeModeLevel.allCases {
            let confirm = StubConfirming(answer: false)
            let auth = StubAuthenticating(answer: true)
            let decision = await Self.gate(level, confirm: confirm, auth: auth).authorize(request)

            #expect(confirm.callCount == 0, "a reviewed rebuild at \(level.rawValue) was confirmed again")
            guard level != .readOnly else {
                #expect(!decision.isAuthorized, "Read-Only must still refuse a reviewed rebuild")
                continue
            }
            #expect(decision.isAuthorized, "a reviewed rebuild at \(level.rawValue) must run")
            #expect(auth.callCount == (Self.asksForAuthentication(level) ? 1 : 0), "Touch ID at \(level.rawValue)")
        }
    }

    @Test("A reorder that runs on the drop, with no review, is confirmed by the gate at the levels that ask")
    func unreviewedReorderIsConfirmedPerLevel() async {
        let request = StructureRebuildPlanRunner.authorizationRequest(
            plan: Self.plan(cost: .metadataOnly),
            scope: Self.scope,
            databaseType: .mysql,
            operationDescription: "Reorder Columns",
            isConfirmationPreCleared: false
        )
        for level in SafeModeLevel.allCases where level != .readOnly {
            let confirm = StubConfirming(answer: true)
            let auth = StubAuthenticating(answer: true)
            let decision = await Self.gate(level, confirm: confirm, auth: auth).authorize(request)

            #expect(decision.isAuthorized)
            let asks = Self.asksForConfirmation(level, isDestructive: false)
            #expect(confirm.callCount == (asks ? 1 : 0), "a reorder at \(level.rawValue) asked \(confirm.callCount) times")
        }
    }

    @Test("A review that can run its script reads as the confirmation it is")
    func runnableReviewIsTheConfirmation() {
        let request = TableRebuildReviewRequest(
            tableName: "album",
            scope: Self.scope,
            plan: Self.plan(cost: .tableRebuild),
            action: TableRebuildReviewRequest.Action(
                title: "Apply and Rebuild",
                operationDescription: "Apply Schema Changes",
                perform: {}
            )
        )

        #expect(request.confirmationTitle == "Apply Schema Changes")
        #expect(request.showsStatementsVerbatim)
        #expect(request.confirmationSubtitle(connectionName: "Chinook")?.contains("Chinook") == true)
    }

    @Test("A preview, and a script the app will not run, keep the preview heading")
    func previewIsNotAConfirmation() {
        let preview = TableRebuildReviewRequest(
            tableName: "album",
            scope: Self.scope,
            plan: Self.plan(cost: .tableRebuild),
            action: nil
        )
        let unrunnable = TableRebuildReviewRequest(
            tableName: "album",
            scope: Self.scope,
            plan: PluginColumnReorderPlan(
                statements: Self.plan(cost: .tableRebuild).statements,
                cost: .tableRebuild,
                isRunnable: false,
                verifications: []
            ),
            action: TableRebuildReviewRequest.Action(
                title: "Apply and Rebuild",
                operationDescription: "Apply Schema Changes",
                perform: {}
            )
        )

        for request in [preview, unrunnable] {
            #expect(request.confirmationTitle == nil)
            #expect(!request.showsStatementsVerbatim)
            #expect(request.confirmationSubtitle(connectionName: "Chinook") == nil)
        }
    }

    // MARK: - How a save that did not apply ends

    @Test("A Cancel leaves the edits staged and shows nothing")
    func cancelIsQuiet() {
        let failure = StructureApplyFailure(ExecutionGateError.cancelledByUser("Operation cancelled by user"))

        #expect(failure == .cancelledByUser)
        #expect(failure.outcome == .refused)
        #expect(failure.message == nil)
        #expect(!failure.reportsFailure)
    }

    @Test("A Safe Mode refusal leaves the edits staged and says why, and is not a failed operation")
    func refusalExplainsItself() {
        let failure = StructureApplyFailure(ExecutionGateError.denied("Safe Mode is read-only"))

        #expect(failure.outcome == .refused)
        #expect(failure.message == "Safe Mode is read-only")
        #expect(!failure.reportsFailure)
    }

    @Test("A statement the server rejected is a failed save")
    func serverRejectionIsAFailure() {
        let failure = StructureApplyFailure(ServerRejection())

        #expect(failure.outcome == .failed("Duplicate column name 'notes'"))
        #expect(failure.message == "Duplicate column name 'notes'")
        #expect(failure.reportsFailure)
    }
}
