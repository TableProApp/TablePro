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
        let classification = QueryClassifier.classify(sql, databaseType: meta.databaseType)

        guard !classification.reachesFilesystemOrExecutesCode else {
            throw MCPToolExecutionError.denied(
                String(
                    localized: """
                    Statements that read or write files, or that run server-side code, cannot be sent \
                    through MCP. Run this one in TablePro instead.
                    """
                )
            )
        }

        if !allowsMultiStatement,
           QueryClassifier.isMultiStatement(sql, databaseType: meta.databaseType) {
            throw MCPToolExecutionError.invalidArgument(
                String(localized: "Send one statement at a time.")
            )
        }

        if classification.tier != .safe, meta.externalAccess != .readWrite {
            throw MCPToolExecutionError.denied(
                String(localized: "This connection is read only for external clients.")
            )
        }

        if classification.tier == .destructive, !allowsDestructive {
            throw MCPToolExecutionError.denied(
                String(
                    localized: """
                    This statement drops or truncates data. Use confirm_destructive_operation for it.
                    """
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
        if classification.tier == .destructive { return true }
        if QueryClassifier.isDangerousQuery(sql, databaseType: meta.databaseType) { return true }
        guard meta.safeModeLevel.requiresConfirmation else { return false }
        return classification.tier != .safe || meta.safeModeLevel.appliesToAllQueries
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
