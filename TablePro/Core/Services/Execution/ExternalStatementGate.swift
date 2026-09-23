//
//  ExternalStatementGate.swift
//  TablePro
//

import Foundation

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

/// What every caller outside the app's own windows has to clear before a statement reaches a driver.
///
/// MCP and AppleScript ask the same four questions of a statement and then hand it to the same
/// `ExecutionGate`. They used to be one method inside `MCPStatementGate`, which meant a second
/// transport could only get the policy by copying it, and a copied policy is a policy that drifts.
///
/// It is two entry points rather than one because the order matters. `classify` refuses a statement
/// on the connection's own terms and prompts nobody; `authorizeExecution` is where safe mode may put
/// a dialog in front of a person. A transport with a consent step of its own (MCP's elicitation)
/// runs it between the two, so nobody is ever asked to approve a statement that was already refused.
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

    /// The refusals a connection's own settings make, before anyone is prompted about anything.
    @discardableResult
    internal static func classify(_ statement: Statement) throws -> QueryClassification {
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

        if classification.tier != .safe, statement.externalAccess != .readWrite {
            throw ExternalStatementGateError.denied(
                String(localized: "This connection is read only for external clients.")
            )
        }

        if classification.tier == .destructive, !statement.allowsDestructive {
            let refusal = String(localized: "This statement drops or truncates data.")
            throw ExternalStatementGateError.denied(
                statement.destructiveAlternative.map { "\(refusal) \($0)" } ?? refusal
            )
        }

        return classification
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

    /// Safe Mode, and the confirmation or biometric prompt it asks for.
    internal static func authorizeExecution(
        sql: String,
        connectionId: UUID,
        databaseType: DatabaseType,
        caller: OperationCaller,
        capabilities: CallerCapabilities,
        operationDescription: String,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: connectionId,
                databaseType: databaseType,
                sql: sql,
                kind: OperationKind.from(QueryClassifier.classifyTier(sql, databaseType: databaseType)),
                caller: caller,
                capabilities: capabilities,
                operationDescription: operationDescription
            )
        )
        if case .denied(let reason) = decision {
            throw ExternalStatementGateError.denied(reason)
        }
    }

    /// Whether a person has to see this statement before it runs, on this connection's settings.
    internal static func requiresUserConsent(
        classification: QueryClassification,
        sql: String,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel
    ) -> Bool {
        if classification.tier == .destructive { return true }
        if QueryClassifier.isDangerousQuery(sql, databaseType: databaseType) { return true }
        guard safeModeLevel.requiresConfirmation else { return false }
        return classification.tier != .safe || safeModeLevel.appliesToAllQueries
    }
}
