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
        activeDatabase: String?,
        databaseType: DatabaseType? = nil,
        customCliPath: String? = nil,
        effectiveConnection: DatabaseConnection? = nil
    ) -> CLILaunchSpec? {
        let sshConfig = extractSSHConfig(from: connection)
        if let sshConfig {
            // Prefer running the CLI on the remote host via SSH — the server
            // that runs the database almost always has the CLI binary installed.
            if let spec = resolveViaSSH(
                connection: connection,
                password: password,
                activeDatabase: activeDatabase,
                sshConfig: sshConfig
            ) {
                return spec
            }

            // Fall back to local CLI through the existing SSH tunnel
            // (e.g. Docker setups where the SSH host doesn't have the CLI).
            if let effective = effectiveConnection {
                return resolveLocal(
                    connection: effective,
                    password: password,
                    activeDatabase: activeDatabase,
                    customCliPath: customCliPath
                )
            }
        }
        return resolveLocal(
            connection: connection,
            password: password,
            activeDatabase: activeDatabase,
            customCliPath: customCliPath
        )
    }

    // MARK: - Local Resolution

    private static func resolveLocal(
        connection: DatabaseConnection,
        password: String?,
        activeDatabase: String?,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        let dbName = activeDatabase ?? connection.database
        let type = connection.type

        switch type {
        case .mysql:
            return resolveMysql(connection: connection, password: password, database: dbName, customCliPath: customCliPath)
        case .mariadb:
            return resolveMariadbOrMysql(connection: connection, password: password, database: dbName, customCliPath: customCliPath)
        case .postgresql, .redshift:
            return resolvePsql(connection: connection, password: password, database: dbName, customCliPath: customCliPath)
        case .redis:
            return resolveRedisCli(connection: connection, password: password, customCliPath: customCliPath)
        case .mongodb:
            return resolveMongosh(connection: connection, password: password, database: dbName, customCliPath: customCliPath)
        case .sqlite:
            return resolveSqlite3(connection: connection, customCliPath: customCliPath)
        case .mssql:
            return resolveSqlcmd(connection: connection, password: password, database: dbName, customCliPath: customCliPath)
        case .clickhouse:
            return resolveClickhouseClient(connection: connection, password: password, database: dbName, customCliPath: customCliPath)
        case .duckdb:
            return resolveDuckdb(connection: connection, customCliPath: customCliPath)
        case .oracle:
            return resolveSqlplus(connection: connection, password: password, database: dbName, customCliPath: customCliPath)
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

        if let port = sshConfig.port, port != 22 {
            sshArgs += ["-p", String(port)]
        }

        if sshConfig.authMethod == .privateKey, !sshConfig.privateKeyPath.isEmpty {
            let expanded = (sshConfig.privateKeyPath as NSString).expandingTildeInPath
            sshArgs += ["-i", expanded]
        }

        if !sshConfig.jumpHosts.isEmpty {
            let jumpSpec = sshConfig.jumpHosts.map { jump -> String in
                let userPrefix = jump.username.isEmpty ? "" : "\(jump.username)@"
                if let port = jump.port, port != 22 {
                    return "\(userPrefix)\(jump.host):\(port)"
                }
                return "\(userPrefix)\(jump.host)"
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

        // Source common profile files so the remote PATH includes CLI binaries.
        // Covers bash (.bash_profile, .bashrc, .profile) and zsh (.zshrc).
        let sourceChain = [".profile", ".bash_profile", ".bashrc", ".zshrc"]
            .map { ". ~/\($0) 2>/dev/null" }
            .joined(separator: "; ")
        sshArgs.append(sourceChain + "; " + remoteCommand)

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
            // Use "mysql" for SSH — universally available on both MySQL and MariaDB servers
            cmd = "mysql"
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
                // Double-quote the password so sqlplus doesn't split on @ or /
                let quotedPass = "\"" + pass.replacingOccurrences(of: "\"", with: "\\\"") + "\""
                connectString = "\(connection.username)/\(quotedPass)@\(host):\(connection.port)/\(serviceName)"
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
    /// Strips null bytes and newlines which cannot be safely quoted in POSIX single-quote strings.
    private static func shellEscape(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        if sanitized.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" }) {
            return sanitized
        }
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    static func userConfiguredPath(for databaseType: DatabaseType) -> String? {
        let customPath = AppSettingsManager.shared.terminal.cliPaths[databaseType.rawValue] ?? ""
        guard !customPath.isEmpty else { return nil }
        return customPath
    }

    static func findExecutable(_ name: String, customPath: String? = nil) -> String? {
        // 1. User-configured path
        if let customPath, !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return customPath
        }

        // 2. System PATH via /usr/bin/which
        let whichResult = shell("/usr/bin/which", arguments: [name])
        if let path = whichResult, !path.isEmpty {
            return path
        }

        // 3. Common locations
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
        case .mysql: return "mysql"
        case .mariadb: return "mariadb"
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
        // brew commands are not localized — they are technical shell commands
        case .mysql:
            return "brew install mysql-client"
        case .mariadb:
            return "brew install mariadb"
        case .postgresql, .redshift:
            return "brew install libpq"
        case .redis:
            return "brew install redis"
        case .mongodb:
            return "brew install mongosh"
        case .sqlite:
            return String(localized: "sqlite3 is included with macOS")
        case .mssql:
            return "brew install sqlcmd"
        case .clickhouse:
            return "brew install clickhouse"
        case .duckdb:
            return "brew install duckdb"
        case .oracle:
            return "brew install instantclient-sqlplus"
        default:
            return String(format: String(localized: "Install the CLI client for %@"), databaseType.displayName)
        }
    }

    // MARK: - Private Resolvers

    private static func resolveMysql(
        connection: DatabaseConnection,
        password: String?,
        database: String,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("mysql", customPath: customCliPath) else { return nil }

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

    private static func resolveMariadbOrMysql(
        connection: DatabaseConnection,
        password: String?,
        database: String,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        let path = findExecutable("mariadb", customPath: customCliPath)
            ?? findExecutable("mysql", customPath: nil)
        guard let path else { return nil }

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
        database: String,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("psql", customPath: customCliPath) else { return nil }

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
        password: String?,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("redis-cli", customPath: customCliPath) else { return nil }

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
        database: String,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("mongosh", customPath: customCliPath) else { return nil }

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

    private static func resolveSqlite3(connection: DatabaseConnection, customCliPath: String? = nil) -> CLILaunchSpec? {
        guard let path = findExecutable("sqlite3", customPath: customCliPath) else { return nil }

        let dbPath = connection.database
        return CLILaunchSpec(executablePath: path, arguments: [dbPath], environment: [:])
    }

    private static func resolveSqlcmd(
        connection: DatabaseConnection,
        password: String?,
        database: String,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("sqlcmd", customPath: customCliPath) else { return nil }

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
        database: String,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("clickhouse-client", customPath: customCliPath) else { return nil }

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
        database: String,
        customCliPath: String? = nil
    ) -> CLILaunchSpec? {
        guard let path = findExecutable("sqlplus", customPath: customCliPath) else { return nil }

        let host = connection.host.isEmpty ? "127.0.0.1" : connection.host
        let serviceName = connection.additionalFields["oracleServiceName"] ?? database

        var connectString: String
        if !connection.username.isEmpty {
            let pass = password ?? ""
            // Double-quote the password so sqlplus doesn't split on @ or /
            let quotedPass = "\"" + pass.replacingOccurrences(of: "\"", with: "\\\"") + "\""
            connectString = "\(connection.username)/\(quotedPass)@\(host):\(connection.port)/\(serviceName)"
        } else {
            connectString = "@\(host):\(connection.port)/\(serviceName)"
        }

        return CLILaunchSpec(executablePath: path, arguments: [connectString], environment: [:])
    }

    private static func resolveDuckdb(connection: DatabaseConnection, customCliPath: String? = nil) -> CLILaunchSpec? {
        guard let path = findExecutable("duckdb", customPath: customCliPath) else { return nil }

        let dbPath = connection.database
        return CLILaunchSpec(executablePath: path, arguments: [dbPath], environment: [:])
    }

    // MARK: - Shell Helper

    // Note: shell() and findExecutable() perform synchronous I/O. They are called
    // from Task.detached in TerminalSessionState.connect() to avoid blocking MainActor.
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
