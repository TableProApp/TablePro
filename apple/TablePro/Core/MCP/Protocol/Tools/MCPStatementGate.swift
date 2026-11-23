import Foundation
import TableProMCP
import TableProSQLGrammar

// The MCP side of `ExternalStatementGate`. A tool classifies the text before anything connects, resolves the scope,
// builds the exact statements, then approves them, and runs only the `ApprovedOperation` it gets back.
enum MCPStatementGate {
    @discardableResult
    static func classify(
        sql: String,
        meta: ToolConnectionMetadata,
        allowsDestructive: Bool,
        allowsMultiStatement: Bool = false,
        readOnly: Bool = false,
        destructiveAlternative: String = confirmToolAlternative,
        context: MCPRequestContext
    ) throws -> QueryClassification {
        // The caller lowering its own reach, so its refusal names the request rather than the connection.
        if readOnly, QueryClassifier.classify(sql, databaseType: meta.databaseType).tier != .safe {
            throw MCPToolExecutionError.denied(Self.readOnlyRefusal)
        }

        let classification = try translating {
            try ExternalStatementGate.classify(
                ExternalStatementGate.Statement(
                    sql: sql,
                    connectionId: meta.connectionId,
                    databaseType: meta.databaseType,
                    externalAccess: meta.externalAccess,
                    loadsExtensions: meta.loadsExtensions,
                    allowsDestructive: allowsDestructive,
                    allowsMultiStatement: allowsMultiStatement,
                    destructiveAlternative: destructiveAlternative
                )
            )
        }

        if classification.tier != .safe {
            try requireWriteScope(context: context)
        }
        return classification
    }

    // An operation with no text of its own, refused by what it is: creating a database, a transaction.
    static func classify(
        kind: OperationKind,
        meta: ToolConnectionMetadata,
        allowsDestructive: Bool,
        context: MCPRequestContext
    ) throws {
        guard kind.declaresWrite else { return }
        try translating { try ExternalStatementGate.refuseWrite(externalAccess: meta.externalAccess) }
        if kind.declaresDestructive, !allowsDestructive {
            throw MCPToolExecutionError.denied("\(ExternalStatementGate.destructiveRefusal) \(confirmToolAlternative)")
        }
        try requireWriteScope(context: context)
    }

    // confirm_destructive_operation runs only what `classify` refuses to every other tool.
    static func requireDestructive(sql: String, meta: ToolConnectionMetadata) throws {
        try translating { try ExternalStatementGate.requireDestructive(sql, databaseType: meta.databaseType) }
    }

    static let confirmToolAlternative = String(localized: "Use confirm_destructive_operation for it.")

    // Elicitation, then Safe Mode, on the statements as they will run in `scope`. A call that approves several in turn
    // passes the `consent(for:)` it got for all of them, so the client is asked once.
    static func approve(
        _ statements: [OperationStatement],
        kind: OperationKind,
        unit: OperationUnit = .statement,
        gradedSQL: String? = nil,
        displayStatements: [String]? = nil,
        scope: DatabaseScope,
        meta: ToolConnectionMetadata,
        allowsDestructive: Bool,
        allowsMultiStatement: Bool = false,
        forcesUserConsent: Bool = false,
        operationLabel: String,
        consent callConsent: MCPCallConsent? = nil,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> ApprovedOperation {
        let generation = await services.connectionBridge.driverGeneration(of: scope.connectionId)
        let pending = pendingOperation(
            statements,
            kind: kind,
            unit: unit,
            gradedSQL: gradedSQL,
            displayStatements: displayStatements,
            scope: scope,
            driverGeneration: generation,
            meta: meta,
            allowsDestructive: allowsDestructive,
            allowsMultiStatement: allowsMultiStatement,
            forcesUserConsent: forcesUserConsent,
            operationLabel: operationLabel,
            context: context
        )
        let consent: MCPConsentOutcome
        if let callConsent, callConsent.covers(pending) {
            consent = callConsent.outcome
        } else {
            consent = try consentOutcome(
                needed: needsConsent(pending, meta: meta, forcesUserConsent: forcesUserConsent),
                pending: pending,
                meta: meta,
                operationLabel: operationLabel,
                context: context
            )
        }

        var approved = pending
        approved.capabilities.formUnion(consent.capabilities)
        return try await services.authPolicy.checkSafeModeDialog(principal: context.principal, operation: approved)
    }

    static func pendingOperation(
        _ statements: [OperationStatement],
        kind: OperationKind,
        unit: OperationUnit = .statement,
        gradedSQL: String? = nil,
        displayStatements: [String]? = nil,
        scope: DatabaseScope,
        driverGeneration: UUID?,
        meta: ToolConnectionMetadata,
        allowsDestructive: Bool,
        allowsMultiStatement: Bool = false,
        forcesUserConsent: Bool = false,
        operationLabel: String,
        context: MCPRequestContext
    ) -> PendingOperation {
        var capabilities: CallerCapabilities = [.mayWrite]
        if allowsDestructive {
            capabilities.insert(.mayRunDestructive)
        }
        if allowsMultiStatement {
            capabilities.insert(.mayRunMultiStatement)
        }
        // Elicited consent stands in for the Mac dialog only on an admin token, so the dialog asks everyone else.
        if forcesUserConsent {
            capabilities.insert(.confirmsWrites)
        }
        return PendingOperation(
            scope: scope,
            driverGeneration: driverGeneration,
            databaseType: meta.databaseType,
            statements: statements,
            kind: kind,
            unit: unit,
            caller: .mcpClient(label: context.principal.auditLabel),
            capabilities: capabilities,
            operationDescription: MCPAuthPolicy.operationDescription(for: operationLabel),
            gradedSQL: gradedSQL,
            displayStatements: displayStatements
        )
    }

    // One elicitation listing every statement a call runs, sealed as one target over each statement's own. Asked one
    // at a time, the answer for the second restarted the call and asked for the first again, so it never finished.
    static func consent(
        for operations: [PendingOperation],
        meta: ToolConnectionMetadata,
        forcesUserConsent: Bool = false,
        operationLabel: String,
        context: MCPRequestContext
    ) throws -> MCPCallConsent {
        let targets = operations.map(MCPToolConsent.target(of:))
        let needed = operations.contains { needsConsent($0, meta: meta, forcesUserConsent: forcesUserConsent) }
        // Statements in more than one scope cannot share one message, so each gets the Mac dialog instead.
        guard needed, let scope = operations.first?.scope, operations.allSatisfy({ $0.scope == scope }) else {
            return MCPCallConsent(outcome: .nativeAlert, targets: targets)
        }
        guard let detail = preview(of: operations.flatMap(\.displayStatements).joined(separator: "\n\n")) else {
            return MCPCallConsent(outcome: .nativeAlert, targets: targets)
        }
        let outcome = try MCPToolConsent.resolve(
            key: "approve_statement",
            message: consentMessage(operationLabel: operationLabel, connectionName: meta.connectionName, scope: scope),
            detail: detail.isEmpty ? nil : detail,
            target: MCPToolConsent.target(covering: targets),
            context: context
        )
        return MCPCallConsent(outcome: outcome, targets: targets)
    }

    private static func needsConsent(_ pending: PendingOperation, meta: ToolConnectionMetadata, forcesUserConsent: Bool) -> Bool {
        forcesUserConsent || ExternalStatementGate.requiresUserConsent(
            kind: pending.kind,
            sql: pending.gradedSQL,
            databaseType: meta.databaseType,
            safeModeLevel: meta.safeModeLevel
        )
    }

    static let readOnlyRefusal = String(localized: "This request is read only, and the statement is not a read.")

    static func requiresUserConsent(
        classification: QueryClassification,
        sql: String,
        meta: ToolConnectionMetadata
    ) -> Bool {
        ExternalStatementGate.requiresUserConsent(
            classification: classification,
            sql: sql,
            databaseType: meta.databaseType,
            safeModeLevel: meta.safeModeLevel
        )
    }

    private static func requireWriteScope(context: MCPRequestContext) throws {
        try MCPToolAuthorization.requireScope(
            .toolsWrite,
            context: context,
            reason: String(localized: "Writing to a database needs the tools:write scope.")
        )
    }

    // The shared gate speaks in its own vocabulary, mapped onto the two tool errors that mean the same things.
    private static func translating<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ExternalStatementGateError {
            switch error {
            case .denied(let detail):
                throw MCPToolExecutionError.denied(detail)
            case .invalidArgument(let detail):
                throw MCPToolExecutionError.invalidArgument(detail)
            }
        }
    }

    private static func consentOutcome(
        needed: Bool,
        pending: PendingOperation,
        meta: ToolConnectionMetadata,
        operationLabel: String,
        context: MCPRequestContext
    ) throws -> MCPConsentOutcome {
        guard needed else {
            return .nativeAlert
        }
        let shown = pending.displayStatements.joined(separator: "\n")
        // A detail the client's form would have to cut is never sent; the Mac dialog shows it whole instead.
        guard let detail = preview(of: shown) else {
            return .nativeAlert
        }
        return try MCPToolConsent.resolve(
            key: "approve_statement",
            message: consentMessage(operationLabel: operationLabel, connectionName: meta.connectionName, scope: pending.scope),
            detail: detail.isEmpty ? nil : detail,
            target: MCPToolConsent.target(of: pending),
            context: context
        )
    }

    // Each part execution honors is named on its own: a schema with no database named still runs there.
    static func consentMessage(operationLabel: String, connectionName: String, scope: DatabaseScope) -> String {
        switch (scope.namedDatabase, scope.schema) {
        case (nil, nil):
            return String(format: String(localized: "Allow %@ on '%@'?"), operationLabel, connectionName)
        case (let database?, nil):
            return String(
                format: String(localized: "Allow %1$@ on '%2$@', database '%3$@'?"),
                operationLabel,
                connectionName,
                database
            )
        case (nil, let schema?):
            return String(
                format: String(localized: "Allow %1$@ on '%2$@', schema '%3$@'?"),
                operationLabel,
                connectionName,
                schema
            )
        case (let database?, let schema?):
            return String(
                format: String(localized: "Allow %1$@ on '%2$@', database '%3$@', schema '%4$@'?"),
                operationLabel,
                connectionName,
                database,
                schema
            )
        }
    }

    // The only text the client shows beside its Approve control, so it keeps its line breaks. The cap is sized for
    // a form field in someone else's interface; past it there is no detail, and the caller falls back to the dialog.
    static let previewCharacterLimit = 2_000

    static func preview(of sql: String) -> String? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed as NSString).length <= previewCharacterLimit else { return nil }
        return trimmed
    }
}

// The answer a call's one elicitation got, good only for the statements it listed.
struct MCPCallConsent: Sendable {
    let outcome: MCPConsentOutcome
    private let targets: Set<String>

    fileprivate init(outcome: MCPConsentOutcome, targets: [String]) {
        self.outcome = outcome
        self.targets = Set(targets)
    }

    func covers(_ operation: PendingOperation) -> Bool {
        targets.contains(MCPToolConsent.target(of: operation))
    }
}
