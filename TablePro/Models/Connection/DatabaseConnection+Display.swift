//
//  DatabaseConnection+Display.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DatabaseConnection {
    var connectionSubtitle: String {
        var components: [String] = [endpointDescription]
        if let database = databaseDescriptor {
            components.append(database)
        }
        if let via = sshViaDescriptor {
            components.append(via)
        }
        return components.joined(separator: " · ")
    }

    private var endpointDescription: String {
        if host.isEmpty {
            let trimmed = database.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? type.rawValue : (trimmed as NSString).abbreviatingWithTildeInPath
        }
        if host.hasPrefix("/") {
            return (host as NSString).abbreviatingWithTildeInPath
        }
        if let mongoHosts = additionalFields["mongoHosts"], mongoHosts.contains(",") {
            let count = mongoHosts.split(separator: ",").count
            return String(format: String(localized: "%@ (+%d more)"), hostWithOptionalPort, count - 1)
        }
        return hostWithOptionalPort
    }

    private var databaseDescriptor: String? {
        guard !host.isEmpty else { return nil }
        switch type.pathFieldRole {
        case .database, .serviceName:
            let trimmed = database.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case .databaseIndex:
            guard let index = redisDatabase else { return nil }
            return String(format: String(localized: "db %d"), index)
        case .filePath:
            return nil
        }
    }

    private var hostWithOptionalPort: String {
        port == type.defaultPort ? host : "\(host):\(port)"
    }

    private var sshViaDescriptor: String? {
        let ssh = resolvedSSHConfig
        guard ssh.enabled, !ssh.host.isEmpty else { return nil }
        return String(format: String(localized: "via %@"), ssh.host)
    }
}
