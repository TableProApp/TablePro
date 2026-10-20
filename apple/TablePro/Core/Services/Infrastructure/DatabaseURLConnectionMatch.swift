//
//  DatabaseURLConnectionMatch.swift
//  TablePro
//

import Foundation

internal enum DatabaseURLConnectionMatch {
    // A socket URL always says localhost, so only the socket file tells two local servers apart.
    internal static func matches(saved: DatabaseConnection, parsed: ParsedConnectionURL) -> Bool {
        guard saved.type == parsed.type,
              saved.database == parsed.database,
              parsed.username.isEmpty || saved.username == parsed.username,
              saved.localSocketFile == parsed.localSocketFile
        else { return false }
        guard parsed.localSocketFile == nil else { return true }
        return saved.host == parsed.host && (parsed.port == nil || saved.port == parsed.port)
    }
}
