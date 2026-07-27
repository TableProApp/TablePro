import Foundation

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case error(String)
}
