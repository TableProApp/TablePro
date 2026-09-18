//
//  ScriptRunQueryCommand.swift
//  TablePro
//

import Foundation

/// `run query "SELECT …" in connection "prod"`
///
/// Runs headlessly: no window is opened and no tab is disturbed, because a script that wants rows
/// back usually wants them without the app coming to the front. `open table` is the command for the
/// other intent.
@objc(TPScriptRunQueryCommand)
internal final class ScriptRunQueryCommand: ScriptCommand {
    private let bridge = DatabaseAccessBridge()

    @MainActor
    override internal func run() async throws -> Any? {
        let sql = try requiredText()
        let connection = try requiredConnection()
        let request = ScriptQueryRunner.Request(
            sql: sql,
            connectionId: connection.connectionId,
            database: optionalString(ScriptingKeys.Parameter.database),
            schema: optionalString(ScriptingKeys.Parameter.schema),
            rowLimit: optionalInt(ScriptingKeys.Parameter.rowLimit),
            timeoutSeconds: optionalInt(ScriptingKeys.Parameter.timeout),
            client: sendingApplication
        )

        let outcome = try await ScriptQueryRunner.run(request, bridge: bridge)
        return ScriptResultEncoder.encode(outcome.result, executionTimeMs: outcome.executionTimeMs)
    }
}
