import Foundation
import TableProModels

nonisolated extension DatabaseConnection {
    /// A tunnel replaces the socket on the Mac too, so only a direct connection would dial it.
    var macSocketPath: String? {
        switch type {
        case .mysql, .mariadb, .tidb, .oceanbase:
            guard !(sshEnabled && sshConfiguration != nil) else { return nil }
            return MySQLLocalSocket.path(in: additionalFields)
        default:
            return nil
        }
    }
}
