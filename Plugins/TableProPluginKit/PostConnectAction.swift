import Foundation

public enum PostConnectAction: Sendable, Equatable {
    case selectDatabaseFromLastSession
    case selectDatabaseFromConnectionField(fieldId: String)
}
