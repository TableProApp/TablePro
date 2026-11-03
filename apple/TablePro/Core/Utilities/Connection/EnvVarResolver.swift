//
//  EnvVarResolver.swift
//  TablePro
//

import Foundation
import os
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

internal enum EnvVarResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EnvVarResolver")

    static func resolve(_ value: String) -> String {
        EnvVarReferences.replacing(in: value) { name in
            guard let envValue = ProcessInfo.processInfo.environment[name] else {
                logger.warning("A connection field names an environment variable that is not set")
                return nil
            }
            return envValue
        }
    }

    static func referencedNames(in connection: DatabaseConnection) -> Set<String> {
        var names: Set<String> = []
        var scanned = connection
        visitResolvedFields(of: &scanned) { names.formUnion(EnvVarReferences.names(in: $0)) }
        return names
    }

    static func resolveConnection(_ connection: DatabaseConnection) -> DatabaseConnection {
        var resolved = connection
        visitResolvedFields(of: &resolved) { $0 = resolve($0) }
        return resolved
    }

    // The one list of fields a connect resolves, so consent covers exactly what is read.
    private static func visitResolvedFields(of connection: inout DatabaseConnection, _ visit: (inout String) -> Void) {
        visit(&connection.host)
        visit(&connection.database)
        visit(&connection.username)

        visit(&connection.sshConfig.host)
        visit(&connection.sshConfig.username)
        visit(&connection.sshConfig.privateKeyPath)
        visit(&connection.sshConfig.agentSocketPath)

        visit(&connection.sslConfig.caCertificatePath)
        visit(&connection.sslConfig.clientCertificatePath)
        visit(&connection.sslConfig.clientKeyPath)

        if var commands = connection.startupCommands {
            visit(&commands)
            connection.startupCommands = commands
        }

        connection.additionalFields = connection.additionalFields.mapValues { value in
            var visited = value
            visit(&visited)
            return visited
        }
    }
}
