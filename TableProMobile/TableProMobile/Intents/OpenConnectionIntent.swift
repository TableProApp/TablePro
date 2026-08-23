import AppIntents
import Foundation
import UIKit

struct OpenConnectionIntent: AppIntent {
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
        guard let url = URL(string: "tablepro://connect/\(connection.id.uuidString)") else {
            return .result()
        }
        await UIApplication.shared.open(url)
        return .result()
    }
}
