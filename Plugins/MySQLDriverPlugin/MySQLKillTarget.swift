import Foundation

internal enum MySQLKillTarget: Equatable, Sendable {
    case threadId
    /// `KILL <id>`, the only kill a server before 5.0 has. It ends the session with the statement.
    case connection
    case tidbConnection(UInt64)
    case databendSession(String)

    func statement(threadId: UInt) -> String? {
        switch self {
        case .threadId:
            return threadId > 0 ? "KILL QUERY \(threadId)" : nil
        case .connection:
            return threadId > 0 ? "KILL \(threadId)" : nil
        case .tidbConnection(let id):
            return "KILL TIDB QUERY \(id)"
        case .databendSession(let session):
            return "KILL QUERY '\(mysqlEscapeStringLiteral(session))'"
        }
    }

    var endsSession: Bool {
        switch self {
        case .connection:
            return true
        case .threadId, .tidbConnection, .databendSession:
            return false
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
        case .mysql, .mariadb, .oceanbase:
            return .threadId
        }
    }

    /// 4.1.22 answers `KILL QUERY` with `1204`, so below 5.0 a statement stops only with its session.
    func killTarget(connectionIdentifier: String?, banner: String?) -> MySQLKillTarget {
        guard MySQLServerVersion.canStopStatementAlone(banner: banner, flavor: self) else { return .connection }
        return killTarget(connectionIdentifier: connectionIdentifier)
    }
}
