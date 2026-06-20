//
//  BeekeeperStudioImporter.swift
//  TablePro
//
//  Imports saved connections from Beekeeper Studio.
//
//  Beekeeper stores everything in `~/Library/Application Support/beekeeper-studio/app.db`
//  (SQLite). Encrypted password columns are unwrapped via `BeekeeperEncryptor`
//  using the per-install key read from `.key` next to that database.
//
//  Only the local workspace (workspaceId = -1) is imported. Cloud-synced
//  workspaces require a Beekeeper account and would arrive with their own
//  source of truth.
//

import AppKit
import Foundation
import os
import SQLite3
import TableProImport
import TableProPluginKit

struct BeekeeperStudioImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "BeekeeperStudioImporter")

    let id = "beekeeperstudio"
    let displayName = "Beekeeper Studio"
    let symbolName = "ant"
    let appBundleIdentifier = "io.beekeeperstudio.desktop"
    let readsPasswordsFromKeychain = false

    var dataDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/beekeeper-studio")

    private var appDatabaseURL: URL { dataDirectoryURL.appendingPathComponent("app.db") }
    private var keyFileURL: URL { dataDirectoryURL.appendingPathComponent(".key") }

    func connectionCount() -> Int {
        guard let db = try? openDatabase() else { return 0 }
        defer { sqlite3_close(db) }
        return (try? readSavedConnections(db: db).count) ?? 0
    }

    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult {
        let db: OpaquePointer?
        do {
            db = try openDatabase()
        } catch let error as ForeignAppImportError {
            throw error
        } catch {
            throw ForeignAppImportError.parseError(error.localizedDescription)
        }
        defer { sqlite3_close(db) }

        let rows = try readSavedConnections(db: db)
        let folderMap = (try? readConnectionFolders(db: db)) ?? [:]
        let userKey = includePasswords ? loadUserEncryptionKey() : nil

        var exportableConnections: [ExportableConnection] = []
        var groupNames: Set<String> = []
        var credentials: [String: ExportableCredentials] = [:]

        for row in rows {
            try Task.checkCancellation()
            guard let type = Self.mapDriver(row.connectionType) else {
                Self.logger.warning("Skipping Beekeeper connection \(row.id) with unsupported driver \(row.connectionType ?? "<nil>", privacy: .public)")
                continue
            }
            let groupName = row.connectionFolderId.flatMap { folderMap[$0] }
            if let groupName { groupNames.insert(groupName) }

            let exportable = ExportableConnection(
                name: row.name.isEmpty ? "Untitled" : row.name,
                host: row.host.isEmpty ? "localhost" : row.host,
                port: row.port ?? Self.defaultPort(for: type),
                database: row.defaultDatabase ?? "",
                username: row.username ?? "",
                type: type,
                sshConfig: row.sshEnabled ? Self.buildSSHConfig(row) : nil,
                sslConfig: row.ssl ? Self.buildSSLConfig(row) : nil,
                color: Self.mapColor(row.labelColor),
                tagName: nil,
                groupName: groupName,
                sshProfileId: nil,
                safeModeLevel: nil,
                aiPolicy: nil,
                additionalFields: nil,
                redisDatabase: nil,
                startupCommands: nil,
                localOnly: nil
            )
            let index = exportableConnections.count
            exportableConnections.append(exportable)

            if includePasswords, let userKey {
                let creds = Self.extractCredentials(row: row, key: userKey)
                if creds.password != nil || creds.sshPassword != nil || creds.keyPassphrase != nil {
                    credentials[String(index)] = creds
                }
            }
        }

        guard !exportableConnections.isEmpty else {
            throw ForeignAppImportError.noConnectionsFound
        }

        let groups = groupNames.isEmpty ? nil : groupNames.sorted().map { ExportableGroup(name: $0, color: nil) }

        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "Beekeeper Studio Import",
            connections: exportableConnections,
            groups: groups,
            tags: nil,
            credentials: credentials.isEmpty ? nil : credentials
        )

        return ForeignAppImportResult(envelope: envelope, sourceName: displayName)
    }

    // MARK: - Driver Mapping

    /// Beekeeper's `connectionType` strings come from the `ConnectionType`
    /// enum in
    /// `beekeeper-studio/apps/studio/src/lib/db/types.ts`. Update this map
    /// when Beekeeper adds a driver TablePro now supports. Unmapped drivers
    /// are skipped with a warning at the call site.
    private static func mapDriver(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "mysql": return "MySQL"
        case "mariadb": return "MariaDB"
        case "postgresql", "postgres": return "PostgreSQL"
        case "redshift": return "Redshift"
        case "cockroachdb": return "CockroachDB"
        case "sqlite": return "SQLite"
        case "sqlserver": return "SQL Server"
        case "oracle": return "Oracle"
        case "mongodb", "mongo": return "MongoDB"
        case "redis": return "Redis"
        case "cassandra": return "Cassandra"
        case "clickhouse": return "ClickHouse"
        case "bigquery": return "BigQuery"
        case "duckdb": return "DuckDB"
        case "libsql": return "libSQL"
        default: return nil
        }
    }

    private static func defaultPort(for type: String) -> Int {
        switch type {
        case "MySQL", "MariaDB": return 3_306
        case "PostgreSQL", "Redshift": return 5_432
        case "CockroachDB": return 26_257
        case "SQL Server": return 1_433
        case "Oracle": return 1_521
        case "MongoDB": return 27_017
        case "Redis": return 6_379
        case "Cassandra": return 9_042
        case "ClickHouse": return 8_123
        default: return 0
        }
    }

    // MARK: - SSH Mapping

    private static func buildSSHConfig(_ row: SavedConnectionRow) -> ExportableSSHConfig {
        let bastion: ExportableJumpHost? = {
            guard let host = row.sshBastionHost, !host.isEmpty else { return nil }
            return ExportableJumpHost(
                host: host,
                port: row.sshBastionPort,
                username: row.sshBastionUsername ?? "",
                authMethod: mapSSHAuth(row.sshBastionMode),
                privateKeyPath: ForeignAppPathHelper.resolveKeyPath(row.sshBastionKeyfile ?? "")
            )
        }()

        return ExportableSSHConfig(
            enabled: true,
            host: row.sshHost ?? "",
            port: row.sshPort,
            username: row.sshUsername ?? "",
            authMethod: mapSSHAuth(row.sshMode),
            privateKeyPath: ForeignAppPathHelper.resolveKeyPath(row.sshKeyfile ?? ""),
            agentSocketPath: "",
            jumpHosts: bastion.map { [$0] },
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    private static func mapSSHAuth(_ mode: String?) -> String {
        switch mode?.lowercased() {
        case "keyfile": return "Private Key"
        case "agent": return "SSH Agent"
        default: return "Password"
        }
    }

    // MARK: - SSL Mapping

    private static func buildSSLConfig(_ row: SavedConnectionRow) -> ExportableSSLConfig {
        let mode = row.sslRejectUnauthorized && !row.trustServerCertificate
            ? "Verify Identity"
            : "Required"
        return ExportableSSLConfig(
            mode: mode,
            caCertificatePath: row.sslCaFile,
            clientCertificatePath: row.sslCertFile,
            clientKeyPath: row.sslKeyFile
        )
    }

    // MARK: - Color

    private static func mapColor(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "red": return "Red"
        case "orange": return "Orange"
        case "yellow": return "Yellow"
        case "green": return "Green"
        case "blue": return "Blue"
        case "purple": return "Purple"
        case "pink": return "Pink"
        case "gray", "grey": return "Gray"
        default: return nil
        }
    }

    // MARK: - Credentials

    private func loadUserEncryptionKey() -> String? {
        guard let data = try? Data(contentsOf: keyFileURL),
              let payload = String(data: data, encoding: .utf8),
              let decoded = BeekeeperEncryptor.decryptDictionary(payload, key: BeekeeperEncryptor.defaultKey),
              let key = decoded["encryptionKey"] as? String else {
            return nil
        }
        return key
    }

    private static func extractCredentials(row: SavedConnectionRow, key: String) -> ExportableCredentials {
        ExportableCredentials(
            password: decrypt(row.password, key: key),
            sshPassword: decrypt(row.sshPassword, key: key),
            keyPassphrase: decrypt(row.sshKeyfilePassword, key: key),
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    private static func decrypt(_ value: String?, key: String) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return BeekeeperEncryptor.decryptString(value, key: key)
    }

    // MARK: - SQLite Reading

    private struct SavedConnectionRow {
        let id: Int
        let name: String
        let connectionType: String?
        let host: String
        let port: Int?
        let username: String?
        let defaultDatabase: String?
        let password: String?
        let ssl: Bool
        let sslCaFile: String?
        let sslCertFile: String?
        let sslKeyFile: String?
        let sslRejectUnauthorized: Bool
        let trustServerCertificate: Bool
        let sshEnabled: Bool
        let sshHost: String?
        let sshPort: Int?
        let sshUsername: String?
        let sshMode: String?
        let sshKeyfile: String?
        let sshKeyfilePassword: String?
        let sshPassword: String?
        let sshBastionHost: String?
        let sshBastionPort: Int?
        let sshBastionUsername: String?
        let sshBastionMode: String?
        let sshBastionKeyfile: String?
        let labelColor: String?
        let connectionFolderId: Int?
    }

    private func readSavedConnections(db: OpaquePointer?) throws -> [SavedConnectionRow] {
        // Only personal workspace; cloud-synced rows have positive workspaceId.
        let sql = """
            SELECT id, name, connectionType, host, port, username, defaultDatabase, password,
                   ssl, sslCaFile, sslCertFile, sslKeyFile, sslRejectUnauthorized, trustServerCertificate,
                   sshEnabled, sshHost, sshPort, sshUsername, sshMode, sshKeyfile, sshKeyfilePassword, sshPassword,
                   sshBastionHost, sshBastionHostPort, sshBastionUsername, sshBastionMode, sshBastionKeyfile,
                   labelColor, connectionFolderId
            FROM saved_connection
            WHERE workspaceId = -1
            ORDER BY id
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ForeignAppImportError.unsupportedFormat("saved_connection schema mismatch")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SavedConnectionRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(SavedConnectionRow(
                id: Int(sqlite3_column_int64(statement, 0)),
                name: Self.text(statement, 1) ?? "",
                connectionType: Self.text(statement, 2),
                host: Self.text(statement, 3) ?? "",
                port: Self.int(statement, 4),
                username: Self.text(statement, 5),
                defaultDatabase: Self.text(statement, 6),
                password: Self.text(statement, 7),
                ssl: Self.bool(statement, 8),
                sslCaFile: Self.text(statement, 9),
                sslCertFile: Self.text(statement, 10),
                sslKeyFile: Self.text(statement, 11),
                sslRejectUnauthorized: Self.bool(statement, 12),
                trustServerCertificate: Self.bool(statement, 13),
                sshEnabled: Self.bool(statement, 14),
                sshHost: Self.text(statement, 15),
                sshPort: Self.int(statement, 16),
                sshUsername: Self.text(statement, 17),
                sshMode: Self.text(statement, 18),
                sshKeyfile: Self.text(statement, 19),
                sshKeyfilePassword: Self.text(statement, 20),
                sshPassword: Self.text(statement, 21),
                sshBastionHost: Self.text(statement, 22),
                sshBastionPort: Self.int(statement, 23),
                sshBastionUsername: Self.text(statement, 24),
                sshBastionMode: Self.text(statement, 25),
                sshBastionKeyfile: Self.text(statement, 26),
                labelColor: Self.text(statement, 27),
                connectionFolderId: Self.int(statement, 28)
            ))
        }
        return rows
    }

    private func readConnectionFolders(db: OpaquePointer?) throws -> [Int: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name FROM connection_folder", -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var map: [Int: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(statement, 0))
            if let name = Self.text(statement, 1), !name.isEmpty {
                map[id] = name
            }
        }
        return map
    }

    private func openDatabase() throws -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: appDatabaseURL.path) else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }
        var db: OpaquePointer?
        // SQLITE_OPEN_READONLY avoids journal-file creation in another app's
        // data directory.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(appDatabaseURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ForeignAppImportError.parseError("Could not open app.db")
        }
        return db
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func int(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private static func bool(_ statement: OpaquePointer?, _ index: Int32) -> Bool {
        sqlite3_column_int(statement, index) != 0
    }
}
