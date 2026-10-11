//
//  DatabaseURLConnectionMatch.swift
//  TablePro
//

import Foundation

internal enum DatabaseURLConnectionMatch {
    // A socket URL always says localhost and names no port, so only the socket path tells two
    // local servers apart, and a TCP URL never opens a socket connection or the other way round.
    internal static func matches(saved: DatabaseConnection, parsed: ParsedConnectionURL) -> Bool {
        guard saved.type == parsed.type,
              saved.database == parsed.database,
              parsed.username.isEmpty || saved.username == parsed.username,
              saved.localSocketPath == parsed.localSocketPath
        else { return false }
        guard parsed.localSocketPath == nil else { return true }
        return saved.host == parsed.host && (parsed.port == nil || saved.port == parsed.port)
    }
}
