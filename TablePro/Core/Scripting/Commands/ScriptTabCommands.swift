//
//  ScriptTabCommands.swift
//  TablePro
//

import AppKit
import Foundation

/// `open table "users" in connection "prod"`
///
/// Goes through the same routing a deep link does, so a table already open is brought forward rather
/// than opened twice, and the connection is opened first if it is not already.
@objc(TPScriptOpenTableCommand)
internal final class ScriptOpenTableCommand: ScriptCommand {
    @MainActor
    override internal func run() async throws -> Any? {
        let table = try requiredText()
        let connection = try requiredConnection()
        let database = optionalString(ScriptingKeys.Parameter.database)
        let schema = optionalString(ScriptingKeys.Parameter.schema)

        /// Through `TabRouter` rather than `LaunchIntentRouter`, because the latter catches
        /// everything and returns. A denied pre-connect approval or a failed connect would otherwise
        /// reach the script as an unrelated timeout, or as a shell tab reported as success.
        try await TabRouter.shared.route(
            .openTable(
                connectionId: connection.connectionId,
                database: database,
                schema: schema,
                table: table,
                isView: false
            )
        )
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)

        guard let tab = await ScriptingSnapshot.awaitTab(
            connectionId: connection.connectionId,
            tableName: table,
            databaseName: database,
            schemaName: schema
        ) else {
            throw ScriptingError.failed(
                String(localized: "TablePro did not open that table in time.")
            )
        }
        return tab
    }
}

/// `focus tab id "…" of connection "prod"`
///
/// Selects the tab and brings its window forward. Named `focus` rather than `select` because
/// selecting is what the grid does to rows, and a script that says `select` about a tab would be
/// reading as though it changed the selection inside it.
@objc(TPScriptFocusTabCommand)
internal final class ScriptFocusTabCommand: ScriptCommand {
    @MainActor
    override internal func run() async throws -> Any? {
        let tab = try requiredReceiver(ScriptTab.self)
        guard ScriptingSnapshot.focus(tab: tab.tabId, connectionId: tab.connectionId) else {
            throw ScriptingError.noSuchObject(String(localized: "That tab is not open."))
        }
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        return tab
    }
}
