import Foundation

@frozen
public enum PostConnectAction: Sendable, Equatable {
    case selectDatabaseFromLastSession
    case selectDatabaseFromConnectionField(fieldId: String)
    case selectSchemaFromLastSession
}
