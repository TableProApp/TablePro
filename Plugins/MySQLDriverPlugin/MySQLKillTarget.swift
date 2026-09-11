import Foundation

internal enum MySQLKillTarget: Equatable, Sendable {
    case threadId
    case tidbConnection(UInt64)
    case databendSession(String)

    func statement(threadId: UInt) -> String? {
        switch self {
        case .threadId:
            return threadId > 0 ? "KILL QUERY \(threadId)" : nil
        case .tidbConnection(let id):
            return "KILL TIDB QUERY \(id)"
        case .databendSession(let session):
            return "KILL QUERY '\(mysqlEscapeStringLiteral(session))'"
        }
    }
}

internal extension MySQLServerFlavor {
    func killTarget(connectionIdentifier: String?) -> MySQLKillTarget {
        switch self {
        case .tidb:
            guard let id = connectionIdentifier.flatMap(UInt64.init) else { return .threadId }
            return .tidbConnection(id)
        case .databend:
            guard let session = connectionIdentifier, !session.isEmpty else { return .threadId }
            return .databendSession(session)
        case .mysql, .mariadb:
            return .threadId
        }
    }
}
