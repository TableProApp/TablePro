import CoreSpotlight
import Foundation

nonisolated enum SceneIntent: Hashable, Sendable {
    case openConnection(UUID, table: String?)
    case importConnections(URL)

    static let viewConnectionActivity = "com.TablePro.viewConnection"
    static let viewTableActivity = "com.TablePro.viewTable"
    static let connectionFileExtension = "tablepro"

    static func parse(url: URL) -> SceneIntent? {
        if url.isFileURL {
            guard url.pathExtension.lowercased() == connectionFileExtension else { return nil }
            return .importConnections(url)
        }
        guard url.scheme?.lowercased() == "tablepro",
              url.host(percentEncoded: false)?.lowercased() == "connect" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let first = segments.first, let connectionId = UUID(uuidString: first) else { return nil }
        guard segments.count == 3, segments[1] == "table", !segments[2].isEmpty else {
            return .openConnection(connectionId, table: nil)
        }
        return .openConnection(connectionId, table: segments[2])
    }

    static func parse(activityType: String, userInfo: [AnyHashable: Any]?) -> SceneIntent? {
        switch activityType {
        case CSSearchableItemActionType:
            guard let identifier = userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let connectionId = UUID(uuidString: identifier) else { return nil }
            return .openConnection(connectionId, table: nil)
        case viewConnectionActivity:
            guard let connectionId = connectionId(in: userInfo) else { return nil }
            return .openConnection(connectionId, table: nil)
        case viewTableActivity:
            guard let connectionId = connectionId(in: userInfo) else { return nil }
            let table = (userInfo?["tableName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .openConnection(connectionId, table: table)
        default:
            return nil
        }
    }

    private static func connectionId(in userInfo: [AnyHashable: Any]?) -> UUID? {
        (userInfo?["connectionId"] as? String).flatMap(UUID.init(uuidString:))
    }
}
