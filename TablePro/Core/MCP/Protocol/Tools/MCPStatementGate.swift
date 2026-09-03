import Foundation

enum MCPStatementGate {
    @discardableResult
    static func authorize(
        sql: String,
        meta: ToolConnectionMetadata,
        allowsDestructive: Bool,
        allowsMultiStatement: Bool = false,
        forcesUserConsent: Bool = false,
        operationLabel: String,
        context: MCPRequestContext,
        services: MCPToolServices
    ) async throws -> QueryClassification {
        let classification = try translating {
            try ExternalStatementGate.classify(
                ExternalStatementGate.Statement(
                    sql: sql,
                    connectionId: meta.connectionId,
                    databaseType: meta.databaseType,
                    externalAccess: meta.externalAccess,
                    allowsDestructive: allowsDestructive,
                    allowsMultiStatement: allowsMultiStatement,
                    destructiveAlternative: String(
                        localized: "Use confirm_destructive_operation for it."
                    )
                )
            )
        }

        if classification.tier != .safe {
            try MCPToolAuthorization.requireScope(
                .toolsWrite,
                context: context,
                reason: String(localized: "Writing to a database needs the tools:write scope.")
            )
        }

        let consent = try consentOutcome(
            classification: classification,
            sql: sql,
            meta: meta,
            forcesUserConsent: forcesUserConsent,
            operationLabel: operationLabel,
            context: context
        )

        var capabilities: CallerCapabilities = [.mayWrite]
        if allowsDestructive {
            capabilities.insert(.mayRunDestructive)
        }
        capabilities.formUnion(consent.capabilities)

        try await services.authPolicy.checkSafeModeDialog(
            sql: sql,
            connectionId: meta.connectionId,
            databaseType: meta.databaseType,
            capabilities: capabilities
        )

        return classification
    }

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

    /// The shared gate speaks in its own vocabulary so it owes nothing to MCP. Its two refusals map
    /// onto the two tool errors that already mean the same things.
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
        classification: QueryClassification,
        sql: String,
        meta: ToolConnectionMetadata,
        forcesUserConsent: Bool,
        operationLabel: String,
        context: MCPRequestContext
    ) throws -> MCPConsentOutcome {
        let needed = forcesUserConsent
            || requiresUserConsent(classification: classification, sql: sql, meta: meta)
        guard needed else {
            return .nativeAlert
        }
        return try MCPToolConsent.resolve(
            key: "approve_statement",
            message: String(
                format: String(localized: "Allow %@ on '%@'?"),
                operationLabel,
                meta.connectionName
            ),
            detail: preview(of: sql),
            context: context
        )
    }

    static func preview(of sql: String) -> String {
        let condensed = sql
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (condensed as NSString).length > 400 else { return condensed }
        return (condensed as NSString).substring(to: 400) + "…"
    }
}
