import AppIntents
import Foundation
import UIKit

struct OpenConnectionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Connection"
    static var description = IntentDescription("Opens a database connection in TablePro")
    static var openAppWhenRun = true

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
