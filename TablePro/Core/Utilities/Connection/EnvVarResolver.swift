//
//  EnvVarResolver.swift
//  TablePro
//
//  Resolves $VAR and ${VAR} patterns from process environment variables.
//

import Foundation
import os

internal enum EnvVarResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EnvVarResolver")

    // Matches ${VAR_NAME} or $VAR_NAME
    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
    )

    /// Resolve environment variable references in a string.
    /// Unresolved variables are left as-is and logged as warnings.
    static func resolve(_ value: String) -> String {
        let nsValue = value as NSString
        let length = nsValue.length
        guard length > 0 else { return value }

        let fullRange = NSRange(location: 0, length: length)
        let matches = pattern.matches(in: value, range: fullRange)
        guard !matches.isEmpty else { return value }

        // Process in reverse order so replacement ranges stay valid
        let result = NSMutableString(string: nsValue)
        for match in matches.reversed() {
            // Group 1: ${VAR}, Group 2: $VAR
            let varName: String
            if match.range(at: 1).location != NSNotFound {
                varName = nsValue.substring(with: match.range(at: 1))
            } else {
                varName = nsValue.substring(with: match.range(at: 2))
            }

            if let envValue = ProcessInfo.processInfo.environment[varName] {
                result.replaceCharacters(in: match.range, with: envValue)
            } else {
                logger.warning("Unresolved environment variable: \(varName)")
            }
        }

        return result as String
    }

    /// Check whether a string contains any `$VAR` or `${VAR}` references.
    static func containsVarReferences(_ value: String) -> Bool {
        let length = (value as NSString).length
        guard length > 0 else { return false }
        let fullRange = NSRange(location: 0, length: length)
        return pattern.firstMatch(in: value, range: fullRange) != nil
    }

    /// Resolve environment variables in all applicable connection fields.
    /// Returns a new connection; the original is never mutated.
    static func resolveConnection(_ connection: DatabaseConnection) -> DatabaseConnection {
        var resolved = connection

        resolved.host = resolve(connection.host)
        resolved.database = resolve(connection.database)
        resolved.username = resolve(connection.username)

        // SSH fields
        resolved.sshConfig.host = resolve(connection.sshConfig.host)
        resolved.sshConfig.username = resolve(connection.sshConfig.username)
        resolved.sshConfig.privateKeyPath = resolve(connection.sshConfig.privateKeyPath)
        resolved.sshConfig.agentSocketPath = resolve(connection.sshConfig.agentSocketPath)

        // SSL certificate paths
        resolved.sslConfig.caCertificatePath = resolve(connection.sslConfig.caCertificatePath)
        resolved.sslConfig.clientCertificatePath = resolve(connection.sslConfig.clientCertificatePath)
        resolved.sslConfig.clientKeyPath = resolve(connection.sslConfig.clientKeyPath)

        // Startup commands
        if let commands = connection.startupCommands {
            resolved.startupCommands = resolve(commands)
        }

        // Additional fields values
        var resolvedFields: [String: String] = [:]
        for (key, value) in connection.additionalFields {
            resolvedFields[key] = resolve(value)
        }
        resolved.additionalFields = resolvedFields

        return resolved
    }
}
