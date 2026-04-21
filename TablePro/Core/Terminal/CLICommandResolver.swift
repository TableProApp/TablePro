//
//  CLICommandResolver.swift
//  TablePro
//

import Foundation
import os

struct CLILaunchSpec {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

enum CLICommandResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CLICommandResolver")

    // MARK: - Public API

    static func resolve(
        connection: DatabaseConnection,
        password: String?,
        activeDatabase: String?
    ) -> CLILaunchSpec? {
        let sshConfig = extractSSHConfig(from: connection)
        if let sshConfig {
            return resolveViaSSH(
                connection: connection,
                password: password,
                activeDatabase: activeDatabase,
                sshConfig: sshConfig
            )
        }
        return resolveLocal(connection: connection, password: password, activeDatabase: activeDatabase)
    }

    // MARK: - Local Resolution

    private static func resolveLocal(
        connection: DatabaseConnection,
        password: String?,
        activeDatabase: String?
    ) -> CLILaunchSpec? {
        let dbName = activeDatabase ?? connection.database
        let type = connection.type

        switch type {
        case .mysql, .mariadb:
            return resolveMysql(connection: connection, password: password, database: dbName)
        case .postgresql, .redshift:
            return resolvePsql(connection: connection, password: password, database: dbName)
        case .redis:
            return resolveRedisCli(connection: connection, password: password)
        case .mongodb:
            return resolveMongosh(connection: connection, password: password, database: dbName)
        case .sqlite:
            return resolveSqlite3(connection: connection)
        case .mssql:
            return resolveSqlcmd(connection: connection, password: password, database: dbName)
        case .clickhouse:
            return resolveClickhouseClient(connection: connection, password: password, database: dbName)
        case .duckdb:
            return resolveDuckdb(connection: connection)
        case .oracle:
            return resolveSqlplus(connection: connection, password: password, database: dbName)
        default:
            logger.warning("No CLI mapping for database type: \(type.rawValue, privacy: .public)")
            return nil
        }
    }

    // MARK: - SSH Resolution

    private static func extractSSHConfig(from connection: DatabaseConnection) -> SSHConfiguration? {
        switch connection.sshTunnelMode {
        case .disabled:
            return nil
        case .inline(let config):
            return config
        case .profile(_, let snapshot):
            return snapshot
        }
    }

    private static func resolveViaSSH(
        connection: DatabaseConnection,
        password: String?,
        activeDatabase: String?,
        sshConfig: SSHConfiguration
    ) -> CLILaunchSpec? {
        guard let sshPath = findExecutable("ssh") else {
            logger.error("ssh binary not found")
            return nil
        }

        let cliName = binaryName(for: connection.type)
        let dbName = activeDatabase ?? connection.database

        // Build the remote CLI command
        var remoteCommand = buildRemoteCommand(
            connection: connection,
            password: password,
            database: dbName,
            cliName: cliName
        )
        guard !remoteCommand.isEmpty else { return nil }

        // Build ssh args
        var sshArgs: [String] = []

        // SSH port
        if sshConfig.port != 22 {
            sshArgs += ["-p", String(sshConfig.port)]
        }

        // Private key
        if sshConfig.authMethod == .privateKey, !sshConfig.privateKeyPath.isEmpty {
            let expanded = (sshConfig.privateKeyPath as NSString).expandingTildeInPath
            sshArgs += ["-i", expanded]
        }

        // Jump hosts
        if !sshConfig.jumpHosts.isEmpty {
            let jumpSpec = sshConfig.jumpHosts.map { jump -> String in
                if jump.port != 22 {
                    return "\(jump.username.isEmpty ? "" : "\(jump.username)@")\(jump.host):\(jump.port)"
                }
                return "\(jump.username.isEmpty ? "" : "\(jump.username)@")\(jump.host)"
            }.joined(separator: ",")
            sshArgs += ["-J", jumpSpec]
        }

        // Request TTY for interactive CLI
        sshArgs.append("-t")

        // user@host
        let userHost = sshConfig.username.isEmpty
            ? sshConfig.host
            : "\(sshConfig.username)@\(sshConfig.host)"
        sshArgs.append(userHost)

        // Remote command (the CLI invocation on the remote host)
        sshArgs.append(remoteCommand)

        return CLILaunchSpec(executablePath: sshPath, arguments: sshArgs, environment: [:])
    }

    /// Builds the remote shell command string to run the database CLI on the SSH host.
    /// The DB connects to localhost on the remote (or the configured host from there).
    private static func buildRemoteCommand(
        connection: DatabaseConnection,
        password: String?,
        database: String,
        cliName: String
    ) -> String {
        let host = connection.host.isEmpty ? "127.0.0.1" : connection.host
        var envPrefix = ""
        var cmd = cliName
        let type = connection.type

        switch type {
        case .mysql, .mariadb:
            if let password, !password.isEmpty {
                envPrefix = "MYSQL_PWD=\(shellEscape(password)) "
            }
            cmd += " -h \(host) -P \(connection.port)"
            if !connection.username.isEmpty { cmd += " -u \(shellEscape(connection.username))" }
            if !database.isEmpty { cmd += " \(shellEscape(database))" }

        case .postgresql, .redshift:
            if let password, !password.isEmpty {
                envPrefix = "PGPASSWORD=\(shellEscape(password)) "
            }
            cmd += " -h \(host) -p \(connection.port)"
            if !connection.username.isEmpty { cmd += " -U \(shellEscape(connection.username))" }
            if !database.isEmpty { cmd += " \(shellEscape(database))" }

        case .redis:
            if let password, !password.isEmpty {
                envPrefix = "REDISCLI_AUTH=\(shellEscape(password)) "
            }
            cmd += " -h \(host) -p \(connection.port)"
            if let dbIndex = connection.redisDatabase, dbIndex > 0 {
                cmd += " -n \(dbIndex)"
            }

        case .mongodb:
            let db = database.isEmpty ? "test" : database
            var uri: String
            if !connection.username.isEmpty, let password, !password.isEmpty {
                let encodedUser = connection.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? connection.username
                let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                uri = "mongodb://\(encodedUser):\(encodedPass)@\(host):\(connection.port)/\(db)"
            } else {
                uri = "mongodb://\(host):\(connection.port)/\(db)"
            }
            cmd += " \(shellEscape(uri))"

        case .mssql:
            if let password, !password.isEmpty {
                envPrefix = "SQLCMDPASSWORD=\(shellEscape(password)) "
            }
            cmd += " -S \(host),\(connection.port)"
            if !connection.username.isEmpty { cmd += " -U \(shellEscape(connection.username))" }
            if !database.isEmpty { cmd += " -d \(shellEscape(database))" }

        case .clickhouse:
            if let password, !password.isEmpty {
                envPrefix = "CLICKHOUSE_PASSWORD=\(shellEscape(password)) "
            }
            cmd += " --host \(host) --port \(connection.port)"
            if !connection.username.isEmpty { cmd += " --user \(shellEscape(connection.username))" }
            if !database.isEmpty { cmd += " --database \(shellEscape(database))" }

        case .oracle:
            let serviceName = connection.additionalFields["oracleServiceName"] ?? database
            let pass = password ?? ""
            var connectString: String
            if !connection.username.isEmpty {
                connectString = "\(connection.username)/\(pass)@\(host):\(connection.port)/\(serviceName)"
            } else {
                connectString = "@\(host):\(connection.port)/\(serviceName)"
            }
            cmd += " \(shellEscape(connectString))"

        default:
            return ""
        }

        return "\(envPrefix)\(cmd)"
    }

    /// Escapes a string for safe use in a shell command.
    private static func shellEscape(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func findExecutable(_ name: String) -> String? {
        // 1. System PATH via /usr/bin/which
        let whichResult = shell("/usr/bin/which", arguments: [name])
        if let path = whichResult, !path.isEmpty {
            return path
        }

        // 2. Common locations
        let commonPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/local/mysql/bin/\(name)",
            "/Applications/Postgres.app/Contents/Versions/latest/bin/\(name)"
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    static func binaryName(for databaseType: DatabaseType) -> String {
        switch databaseType {
        case .mysql, .mariadb: return "mysql"
        case .postgresql, .redshift: return "psql"
        case .redis: return "redis-cli"
        case .mongodb: return "mongosh"
        case .sqlite: return "sqlite3"
        case .mssql: return "sqlcmd"
        case .clickhouse: return "clickhouse-client"
        case .duckdb: return "duckdb"
        case .oracle: return "sqlplus"
        default: return databaseType.rawValue.lowercased()
        }
    }

    static func installInstructions(for databaseType: DatabaseType) -> String {
        switch databaseType {
        case .mysql, .mariadb:
            return "brew install mysql"
        case .postgresql, .redshift:
            return "brew install libpq"
        case .redis:
            return "brew install redis"
        case .mongodb:
            return "brew install mongosh"
        case .sqlite:
            return "sqlite3 is included with macOS"
        case .mssql:
            return "brew install sqlcmd"
        case .clickhouse:
            return "brew install clickhouse"
        case .duckdb:
            return "brew install duckdb"
        case .oracle:
            return "brew install instantclient-sqlplus"
        default:
            return "Install the CLI client for \(databaseType.displayName)"
        }
    }

    // MARK: - Private Resolvers

    private static func resolveMysql(
        connection: DatabaseConnection,
        password: String?,
        database: String
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("mysql") else { return nil }

        var args: [String] = []
        if !connection.username.isEmpty {
            args += ["-u", connection.username]
        }
        args += ["-h", connection.host.isEmpty ? "127.0.0.1" : connection.host]
        args += ["-P", String(connection.port)]
        if !database.isEmpty {
            args.append(database)
        }

        var env: [String: String] = [:]
        if let password, !password.isEmpty {
            env["MYSQL_PWD"] = password
        }

        return CLILaunchSpec(executablePath: path, arguments: args, environment: env)
    }

    private static func resolvePsql(
        connection: DatabaseConnection,
        password: String?,
        database: String
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("psql") else { return nil }

        var args: [String] = []
        if !connection.username.isEmpty {
            args += ["-U", connection.username]
        }
        args += ["-h", connection.host.isEmpty ? "127.0.0.1" : connection.host]
        args += ["-p", String(connection.port)]
        if !database.isEmpty {
            args.append(database)
        }

        var env: [String: String] = [:]
        if let password, !password.isEmpty {
            env["PGPASSWORD"] = password
        }

        return CLILaunchSpec(executablePath: path, arguments: args, environment: env)
    }

    private static func resolveRedisCli(
        connection: DatabaseConnection,
        password: String?
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("redis-cli") else { return nil }

        var args: [String] = []
        args += ["-h", connection.host.isEmpty ? "127.0.0.1" : connection.host]
        args += ["-p", String(connection.port)]
        if let dbIndex = connection.redisDatabase, dbIndex > 0 {
            args += ["-n", String(dbIndex)]
        }

        var env: [String: String] = [:]
        if let password, !password.isEmpty {
            env["REDISCLI_AUTH"] = password
        }

        return CLILaunchSpec(executablePath: path, arguments: args, environment: env)
    }

    private static func resolveMongosh(
        connection: DatabaseConnection,
        password: String?,
        database: String
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("mongosh") else { return nil }

        let host = connection.host.isEmpty ? "127.0.0.1" : connection.host
        let port = connection.port
        let db = database.isEmpty ? "test" : database

        var uri: String
        if !connection.username.isEmpty, let password, !password.isEmpty {
            let encodedUser = connection.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? connection.username
            let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            uri = "mongodb://\(encodedUser):\(encodedPass)@\(host):\(port)/\(db)"
        } else {
            uri = "mongodb://\(host):\(port)/\(db)"
        }

        return CLILaunchSpec(executablePath: path, arguments: [uri], environment: [:])
    }

    private static func resolveSqlite3(connection: DatabaseConnection) -> CLILaunchSpec? {
        guard let path = findExecutable("sqlite3") else { return nil }

        let dbPath = connection.database
        return CLILaunchSpec(executablePath: path, arguments: [dbPath], environment: [:])
    }

    private static func resolveSqlcmd(
        connection: DatabaseConnection,
        password: String?,
        database: String
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("sqlcmd") else { return nil }

        let host = connection.host.isEmpty ? "127.0.0.1" : connection.host
        var args: [String] = ["-S", "\(host),\(connection.port)"]
        if !connection.username.isEmpty {
            args += ["-U", connection.username]
        }
        if !database.isEmpty {
            args += ["-d", database]
        }

        var env: [String: String] = [:]
        if let password, !password.isEmpty {
            env["SQLCMDPASSWORD"] = password
        }

        return CLILaunchSpec(executablePath: path, arguments: args, environment: env)
    }

    private static func resolveClickhouseClient(
        connection: DatabaseConnection,
        password: String?,
        database: String
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("clickhouse-client") else { return nil }

        let host = connection.host.isEmpty ? "127.0.0.1" : connection.host
        var args: [String] = ["--host", host, "--port", String(connection.port)]
        if !connection.username.isEmpty {
            args += ["--user", connection.username]
        }
        if !database.isEmpty {
            args += ["--database", database]
        }
        var env: [String: String] = [:]
        if let password, !password.isEmpty {
            env["CLICKHOUSE_PASSWORD"] = password
        }

        return CLILaunchSpec(executablePath: path, arguments: args, environment: env)
    }

    private static func resolveSqlplus(
        connection: DatabaseConnection,
        password: String?,
        database: String
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("sqlplus") else { return nil }

        let host = connection.host.isEmpty ? "127.0.0.1" : connection.host
        let serviceName = connection.additionalFields["oracleServiceName"] ?? database

        // sqlplus user/password@host:port/service_name
        var connectString: String
        if !connection.username.isEmpty {
            let pass = password ?? ""
            connectString = "\(connection.username)/\(pass)@\(host):\(connection.port)/\(serviceName)"
        } else {
            connectString = "@\(host):\(connection.port)/\(serviceName)"
        }

        return CLILaunchSpec(executablePath: path, arguments: [connectString], environment: [:])
    }

    private static func resolveDuckdb(connection: DatabaseConnection) -> CLILaunchSpec? {
        guard let path = findExecutable("duckdb") else { return nil }

        let dbPath = connection.database
        return CLILaunchSpec(executablePath: path, arguments: [dbPath], environment: [:])
    }

    // MARK: - Shell Helper

    private static func shell(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
