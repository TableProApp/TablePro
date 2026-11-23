//
//  DatabaseURLConnectionMatch.swift
//  TablePro
//

import Foundation

internal enum DatabaseURLConnectionMatch {
    // A socket URL always says localhost, so only the socket file tells two local servers apart.
    internal static func matches(saved: DatabaseConnection, parsed: ParsedConnectionURL) -> Bool {
        guard saved.type == parsed.type else { return false }
        if parsed.namesDatabaseFile {
            return localFilePath(of: saved) == parsed.database
        }
        guard saved.database == parsed.database,
              parsed.username.isEmpty || saved.username == parsed.username,
              saved.localSocketFile == parsed.localSocketFile
        else { return false }
        guard parsed.localSocketFile == nil else { return true }
        return saved.host == parsed.host && (parsed.port == nil || saved.port == parsed.port)
    }

    // A saved file connection keeps whatever host and port the form defaulted to, and DuckDB keeps its path in a
    // field of its own, falling back to `database` as its driver does. A row that dials a server, or reads its file
    // over SSH, opens no local file.
    private static func localFilePath(of saved: DatabaseConnection) -> String? {
        guard saved.activeServerEndpointFields == nil, !saved.opensRemoteDatabaseFile,
              !saved.opensRemoteDatabaseSession else { return nil }
        let field = PluginMetadataRegistry.shared.snapshot(for: saved.type)?.capabilities.localFilePathField ?? .database
        let path = saved.localFilePath(in: field)
        return path.isEmpty ? saved.database : path
    }
}
