//
//  OpenConnectionIntent.swift
//  TablePro
//

import AppIntents
import Foundation

@available(macOS 14.0, *)
internal struct OpenConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Connection"
    static let description = IntentDescription(
        "Opens a database connection in TablePro",
        categoryName: "Database",
        searchKeywords: ["TablePro", "database", "connection", "SQL", "open"]
    )
    static let openAppWhenRun = true

    @Parameter(title: "Connection")
    var connection: ConnectionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        do {
            _ = try ScriptQueryRunner.visibleSnapshot(connectionId: connection.id, channel: .shortcuts)
            try await TabRouter.shared.route(.openConnection(connection.id))
        } catch {
            throw ShortcutsActionError.wrapping(error)
        }
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        return .result()
    }
}
