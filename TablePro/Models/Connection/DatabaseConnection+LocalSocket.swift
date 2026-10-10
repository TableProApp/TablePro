//
//  DatabaseConnection+LocalSocket.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DatabaseConnection {
    var supportsLocalSocket: Bool {
        PluginMetadataRegistry.shared.snapshot(for: type)?.connection.defaultLocalSocketPath != nil
    }

    // A tunnel connects to its forwarded port, never this Mac's socket.
    var localSocketPath: String? {
        get {
            guard supportsLocalSocket, activeTunnelKind == nil else { return nil }
            return MySQLLocalSocket.path(in: additionalFields)
        }
        set {
            let path = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if path.isEmpty {
                additionalFields.removeValue(forKey: MySQLLocalSocket.fieldKey)
            } else {
                additionalFields[MySQLLocalSocket.fieldKey] = path
            }
        }
    }

    var timeoutEndpointName: String {
        localSocketPath ?? host.nilIfEmpty ?? name
    }
}
