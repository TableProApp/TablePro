import Foundation
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

    static func importStatus(typeId: String) -> String? {
        isMacOnly(type: DatabaseType(rawValue: typeId)) ? status : nil
    }
}
