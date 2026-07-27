import Foundation

public enum SyncRecordType: String, CaseIterable, Sendable {
    case connection = "Connection"
    case group = "ConnectionGroup"
    case tag = "ConnectionTag"
}
