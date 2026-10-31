//
//  DuckDBIsolatedImport.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation

// DuckDB's settings for running untrusted SQL ("Securing DuckDB" in its operations manual), on an instance of its own,
// since `enable_external_access` cannot be turned back on once a session turns it off.
enum DuckDBIsolatedImport {
    static let openOptions: [(name: String, value: String)] = [
        ("autoinstall_known_extensions", "false"),
        ("autoload_known_extensions", "false"),
        ("allow_community_extensions", "false"),
    ]

    // duckdb_set_config rejects allowed_directories, and DuckDB refuses to change it once external access is off.
    static func lockdownStatements(allowing folder: String) -> [String] {
        [
            "SET allowed_directories = [\(DuckDBSchemaQueries.quoteLiteral(folder))]",
            "SET enable_external_access = false",
            "SET lock_configuration = true",
        ]
    }

    static func importStatement(folder: String) -> String {
        "IMPORT DATABASE \(DuckDBSchemaQueries.quoteLiteral(folder))"
    }

    static func run(folder: String, into file: String) async throws {
        let live = DuckDBLiveConnectionBox()
        try await withTaskCancellationHandler {
            try importFolder(folder, into: file, live: live)
        } onCancel: {
            live.interrupt()
        }
    }

    private static func importFolder(_ folder: String, into file: String, live: DuckDBLiveConnectionBox) throws {
        var config: duckdb_config?
        guard duckdb_create_config(&config) != DuckDBError else {
            throw DuckDBPluginError.connectionFailed("DuckDB could not allocate a configuration")
        }
        defer { duckdb_destroy_config(&config) }
        for option in openOptions where duckdb_set_config(config, option.name, option.value) == DuckDBError {
            throw DuckDBPluginError.connectionFailed("DuckDB rejected \(option.name) = \(option.value)")
        }

        var database: duckdb_database?
        var openError: UnsafeMutablePointer<CChar>?
        guard duckdb_open_ext(file, &database, config, &openError) != DuckDBError else {
            let detail = openError.map { String(cString: $0) } ?? "unknown error"
            duckdb_free(openError)
            throw DuckDBPluginError.connectionFailed("Failed to open DuckDB database at '\(file)': \(detail)")
        }
        defer { duckdb_close(&database) }

        var handle: duckdb_connection?
        guard duckdb_connect(database, &handle) != DuckDBError, let connection = handle else {
            throw DuckDBPluginError.connectionFailed("Failed to create DuckDB connection")
        }
        live.set(connection)
        defer {
            live.set(nil)
            duckdb_disconnect(&handle)
        }
        if Task.isCancelled { throw CancellationError() }

        // IMPORT DATABASE expands into the folder's statements, which duckdb_prepare refuses.
        for statement in lockdownStatements(allowing: folder) + [importStatement(folder: folder)] {
            var result = duckdb_result()
            defer { duckdb_destroy_result(&result) }
            guard duckdb_query(connection, statement, &result) != DuckDBError else {
                let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Unknown DuckDB error"
                throw DuckDBPluginError.queryFailed(message)
            }
        }
    }
}
