import Foundation
import TableProImport
import TableProModels

nonisolated enum MacOnlyConnection {
    static var status: String {
        String(localized: "Opens on Mac only")
    }

    static func isMacOnly(_ connection: DatabaseConnection) -> Bool {
        IOSDriverFactory.refusal(for: connection) != nil
    }

    static func isMacOnly(type: DatabaseType) -> Bool {
        !IOSDriverFactory.supportedTypeList.contains(type)
    }

    static func importStatus(for settings: ExportableConnection) -> String? {
        isMacOnly(DatabaseConnection(importedSettings: settings)) ? status : nil
    }
}
