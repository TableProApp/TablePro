//
//  MariaDBPluginConnection+Transport.swift
//  MySQLDriverPlugin
//

import CMariaDB
import Foundation
import TableProPluginKit

enum MySQLTransport: Sendable, Equatable {
    case tcp(host: String, port: UInt32)
    case unixSocket(path: String)

    init(host: String, port: Int, additionalFields: [String: String]) {
        if let path = MySQLLocalSocket.path(in: additionalFields) {
            self = .unixSocket(path: path)
        } else {
            self = .tcp(host: host, port: UInt32(clamping: port))
        }
    }

    var isUnixSocket: Bool {
        if case .unixSocket = self { return true }
        return false
    }

    var pathIssue: MySQLLocalSocket.PathIssue? {
        guard case .unixSocket(let path) = self else { return nil }
        return MySQLLocalSocket.issue(for: path)
    }

    func configureProtocol(on handle: UnsafeMutablePointer<MYSQL>) {
        let selected = isUnixSocket ? MYSQL_PROTOCOL_SOCKET : MYSQL_PROTOCOL_TCP
        var value = UInt32(selected.rawValue)
        mysql_options(handle, MYSQL_OPT_PROTOCOL, &value)
    }

    /// Connector/C takes the socket path only when the host is NULL or exactly `localhost`.
    func realConnect(
        _ handle: UnsafeMutablePointer<MYSQL>,
        user: String,
        password: String?,
        database: String?
    ) -> UnsafeMutablePointer<MYSQL>? {
        switch self {
        case .tcp(let host, let port):
            return mysql_real_connect(handle, host, user, password, database, port, nil, 0)
        case .unixSocket(let path):
            return mysql_real_connect(handle, "localhost", user, password, database, 0, path, 0)
        }
    }
}

extension MariaDBPluginError {
    init(_ issue: MySQLLocalSocket.PathIssue) {
        self.init(code: 0, message: issue.message, sqlState: nil)
    }
}
