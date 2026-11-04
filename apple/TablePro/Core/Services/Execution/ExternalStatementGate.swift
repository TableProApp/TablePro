//
//  ExternalStatementGate.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProUtilities

internal enum ExternalStatementGateError: LocalizedError, Equatable {
    case denied(String)
    case invalidArgument(String)

    internal var errorDescription: String? {
        switch self {
        case .denied(let detail), .invalidArgument(let detail):
            return detail
        }
    }
}

// What MCP, the assistant, AppleScript and Shortcuts clear before a statement reaches a driver. `classify` refuses
// on the connection's own terms and connects nothing; `approve` asks Safe Mode about the operation as it will run.
// The caller resolves the scope and builds the statements between the two.
internal enum ExternalStatementGate {
    internal struct Statement: Sendable {
        internal let sql: String
        internal let connectionId: UUID
        internal let databaseType: DatabaseType
        internal let externalAccess: ExternalAccessLevel
        internal let loadsExtensions: Bool
        internal let allowsDestructive: Bool
        internal let allowsMultiStatement: Bool
        /// What this transport offers instead, appended to the destructive refusal. MCP has a tool
        /// for it; AppleScript confirms interactively and never reaches the refusal.
        internal let destructiveAlternative: String?

        internal init(
            sql: String,
            connectionId: UUID,
            databaseType: DatabaseType,
            externalAccess: ExternalAccessLevel,
            loadsExtensions: Bool,
            allowsDestructive: Bool,
            allowsMultiStatement: Bool = false,
            destructiveAlternative: String? = nil
        ) {
            self.sql = sql
            self.connectionId = connectionId
            self.databaseType = databaseType
            self.externalAccess = externalAccess
            self.loadsExtensions = loadsExtensions
            self.allowsDestructive = allowsDestructive
            self.allowsMultiStatement = allowsMultiStatement
            self.destructiveAlternative = destructiveAlternative
        }
    }

    // The refusals a connection's own settings make, before anyone is prompted about anything.
    @discardableResult
    internal static func classify(_ statement: Statement) throws -> QueryClassification {
        if let refusal = privateRequestRefusal(sql: statement.sql) {
            throw ExternalStatementGateError.denied(refusal)
        }

        let classification = QueryClassifier.classify(statement.sql, databaseType: statement.databaseType)

        guard !classification.reachesFilesystemOrExecutesCode else {
            throw ExternalStatementGateError.denied(
                String(
                    localized: """
                    Statements that read or write files, or that run server-side code, cannot be sent \
                    from outside the app. Run this one in TablePro instead.
                    """
                )
            )
        }

        if let refusal = extensionCallRefusal(
            sql: statement.sql,
            databaseType: statement.databaseType,
            loadsExtensions: statement.loadsExtensions
        ) {
            throw ExternalStatementGateError.denied(refusal)
        }

        if !statement.allowsMultiStatement,
           QueryClassifier.isMultiStatement(statement.sql, databaseType: statement.databaseType) {
            throw ExternalStatementGateError.invalidArgument(
                String(localized: "Send one statement at a time.")
            )
        }

        if classification.tier != .safe {
            try refuseWrite(externalAccess: statement.externalAccess)
        }

        if !statement.allowsDestructive, isDestructive(statement.sql, databaseType: statement.databaseType) {
            throw ExternalStatementGateError.denied(
                statement.destructiveAlternative.map { "\(destructiveRefusal) \($0)" } ?? destructiveRefusal
            )
        }

        return classification
    }

    // What `classify` refuses to a caller without leave to destroy, and all that confirm_destructive_operation runs.
    internal static func isDestructive(_ sql: String, databaseType: DatabaseType) -> Bool {
        QueryClassifier.isDangerousQuery(sql, databaseType: databaseType)
    }

    internal static func requireDestructive(_ sql: String, databaseType: DatabaseType) throws {
        guard isDestructive(sql, databaseType: databaseType) else {
            throw ExternalStatementGateError.invalidArgument(notDestructiveRefusal)
        }
    }

    internal static let destructiveRefusal = String(
        localized: "This statement is destructive, like DROP, TRUNCATE or a DELETE with no WHERE."
    )

    internal static let notDestructiveRefusal = String(
        localized: """
        This tool runs only destructive statements, like DROP, TRUNCATE or a DELETE with no WHERE. \
        Use execute_query for everything else.
        """
    )

    // For a caller that writes by construction, such as adding rows, whose statements a classifier may not read as
    // writes on every engine.
    internal static func refuseWrite(externalAccess: ExternalAccessLevel) throws {
        guard externalAccess != .readWrite else { return }
        throw ExternalStatementGateError.denied(
            String(localized: "This connection is read only for external clients.")
        )
    }

    /// Whether a caller that takes scripts may send several statements in one call to this engine.
    ///
    /// Only where a script is cut into batches at `GO` lines, as on SQL Server. There the server runs whatever one
    /// request carries as one batch whether or not its statements end in `;`, and a local variable exists only inside
    /// the batch that declares it, so one statement per call is neither enforceable nor useful. Every other engine
    /// keeps one statement per call.
    internal static func acceptsScripts(on databaseType: DatabaseType) -> Bool {
        databaseType.lexicalGrammar.contains(.batchSeparatorLines)
    }

    /// `capabilities`, plus leave to run several statements in one call where the engine takes scripts.
    ///
    /// The execution gate refuses a text of several statements to a caller without that leave, before Safe Mode is
    /// asked anything, so a caller that lets a script past `classify` has to claim it there as well.
    internal static func capabilities(
        _ capabilities: CallerCapabilities,
        takingScriptsOn databaseType: DatabaseType
    ) -> CallerCapabilities {
        guard acceptsScripts(on: databaseType) else { return capabilities }
        return capabilities.union(.mayRunMultiStatement)
    }

    /// A loaded SQLite extension can add functions that write files or run a nested statement, and
    /// the classifier reads `SELECT BlobToFile(...)` as a read. So on a connection that loads
    /// extensions, a statement from outside the app may call only what SQLite itself provides. Nil
    /// when the statement may go ahead.
    internal static func extensionCallRefusal(sql: String, databaseType: DatabaseType, loadsExtensions: Bool) -> String? {
        guard loadsExtensions,
              !SQLiteExtensionCallScanner.callsOnlyBuiltins(sql, readings: databaseType.lexicalReadings)
        else { return nil }
        return String(
            localized: """
            This connection loads SQLite extensions, and their functions can read and write files. \
            A statement from outside TablePro can call only the functions built into SQLite. Run this one in TablePro instead.
            """
        )
    }

    // Drivers decode these from any caller, some through a lexer of their own, so a UTF-16 match anywhere counts.
    internal static func privateRequestRefusal(sql: String) -> String? {
        guard driverRequestMarkers.contains(where: { sql.range(of: $0, options: .literal) != nil }) else { return nil }
        return String(
            localized: """
            TablePro builds this request for its own grid, so it cannot be sent from outside the app. \
            Send the statement it stands for instead.
            """
        )
    }

    private static let driverRequestMarkers = [
        "BIGQUERY_BROWSE:", "BIGQUERY_COMBINED:", "BIGQUERY_FILTER:", "BIGQUERY_SEARCH:",
        "BIGTABLE_BROWSE:",
        "ELASTICSEARCH_EXPORT:", "ELASTICSEARCH_SEARCH:", "ELASTICSEARCH_WRITE:",
        "ETCD_COUNT:", "ETCD_RANGE:", "ETCD_REFUSAL:",
        "FIREBASE_BROWSE:",
        "MEMCACHED_BROWSE:", "MEMCACHED_REFUSAL:",
        "QDRANT_BROWSE:", "QDRANT_EXPORT:", "QDRANT_INSERT_CHECK:",
        "SPANNER_BROWSE:",
        "TYPESENSE_EXPORT:", "TYPESENSE_SEARCH:", "TYPESENSE_WRITE:",
        "WEAVIATE_EXPORT:", "WEAVIATE_SEARCH:", "WEAVIATE_WRITE:",
        "/* TablePro browse ",
    ]

    // Safe Mode and the prompt it asks for, on the operation exactly as it will run. The answer is the only way to
    // get an `ApprovedOperation`, which is what `DatabaseAccessBridge` takes from an external caller.
    internal static func approve(_ pending: PendingOperation, gate: any ExecutionGate) async throws -> ApprovedOperation {
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: pending.scope.connectionId,
                databaseType: pending.databaseType,
                sql: pending.gradedSQL,
                kind: pending.kind,
                caller: pending.caller,
                capabilities: pending.capabilities,
                operationDescription: pending.operationDescription,
                scope: pending.scope,
                statements: pending.displayStatements
            )
        )
        switch decision {
        case .authorized(let receipt):
            return ApprovedOperation(pending, receipt: receipt)
        case .denied(let reason, _):
            throw ExternalStatementGateError.denied(reason)
        }
    }

    internal static func requiresUserConsent(
        classification: QueryClassification,
        sql: String,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel
    ) -> Bool {
        if isDestructive(sql, databaseType: databaseType) { return true }
        guard safeModeLevel.requiresConfirmation else { return false }
        return classification.tier != .safe || safeModeLevel.appliesToAllQueries
    }

    // For an operation that may have no text of its own: a count, a database the driver creates, a transaction.
    internal static func requiresUserConsent(
        kind: OperationKind,
        sql: String?,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel
    ) -> Bool {
        if kind.declaresDestructive { return true }
        if let sql,
           requiresUserConsent(
               classification: QueryClassifier.classify(sql, databaseType: databaseType),
               sql: sql,
               databaseType: databaseType,
               safeModeLevel: safeModeLevel
           ) {
            return true
        }
        guard safeModeLevel.requiresConfirmation else { return false }
        return kind.declaresWrite || safeModeLevel.appliesToAllQueries
    }
}

internal struct OperationStatement: Sendable, Equatable {
    internal let sql: String
    internal let parameters: [PluginCellValue]

    internal init(sql: String, parameters: [PluginCellValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }

    internal init(bound statement: ParameterizedStatement) {
        self.init(sql: statement.sql, parameters: statement.parameters.map(PluginDriverAdapter.cellValue(for:)))
    }

    // As `DatabaseDriver` takes them; the adapter turns each back into the same cell.
    internal var boundValues: [Any?] {
        parameters.map { cell -> Any? in
            switch cell {
            case .null: return nil
            case .text(let text): return text
            case .bytes(let data): return data
            }
        }
    }
}

internal enum OperationUnit: Sendable, Equatable {
    case statement
    // A SQL Server script, run batch by batch at its GO lines.
    case script
}

// What a caller asks `ExternalStatementGate.approve` to let run: the statements in their scope, before anyone said yes.
internal struct PendingOperation: Sendable {
    internal let scope: DatabaseScope
    internal let databaseType: DatabaseType
    internal let statements: [OperationStatement]
    internal let kind: OperationKind
    internal let unit: OperationUnit
    internal var caller: OperationCaller
    internal var capabilities: CallerCapabilities
    internal let operationDescription: String
    // The text Safe Mode grades. Nil for an operation the driver builds itself, or rows of one statement shape.
    internal let gradedSQL: String?
    // Each statement with its values written in, as the person approving it reads it.
    internal let displayStatements: [String]

    internal init(
        scope: DatabaseScope,
        databaseType: DatabaseType,
        statements: [OperationStatement],
        kind: OperationKind,
        unit: OperationUnit = .statement,
        caller: OperationCaller,
        capabilities: CallerCapabilities,
        operationDescription: String,
        gradedSQL: String? = nil,
        displayStatements: [String]? = nil
    ) {
        self.scope = scope
        self.databaseType = databaseType
        self.statements = statements
        self.kind = kind
        self.unit = unit
        self.caller = caller
        self.capabilities = capabilities
        self.operationDescription = operationDescription
        self.gradedSQL = gradedSQL ?? (statements.count == 1 ? statements.first?.sql : nil)
        self.displayStatements = displayStatements
            ?? statements.map { SQLParameterInliner.inline($0, databaseType: databaseType) }
    }
}

// An operation Safe Mode approved, exactly as it runs. Only `ExternalStatementGate.approve` makes one.
internal struct ApprovedOperation: Sendable {
    internal let scope: DatabaseScope
    internal let databaseType: DatabaseType
    internal let statements: [OperationStatement]
    internal let kind: OperationKind
    internal let unit: OperationUnit
    internal let caller: OperationCaller
    internal let receipt: OperationReceipt
    internal let context: PluginStatementContext

    fileprivate init(_ pending: PendingOperation, receipt: OperationReceipt) {
        scope = pending.scope
        databaseType = pending.databaseType
        statements = pending.statements
        kind = pending.kind
        unit = pending.unit
        caller = pending.caller
        self.receipt = receipt
        context = Self.context(for: pending)
    }

    private static func context(for pending: PendingOperation) -> PluginStatementContext {
        let graded = pending.gradedSQL.map { [$0] } ?? pending.statements.map(\.sql)
        let approvedAsDestructive = pending.kind.declaresDestructive
            || graded.contains { ExternalStatementGate.isDestructive($0, databaseType: pending.databaseType) }
        var context = PluginStatementContext()
        context.origin = .external
        context.hostSplit = true
        // An approval as a read is enforced as one, whatever the text grades.
        context.readOnly = !pending.kind.declaresWrite
        context.allowsDestructive = approvedAsDestructive && pending.capabilities.contains(.mayRunDestructive)
        context.allowsServerCode = false
        return context
    }
}
