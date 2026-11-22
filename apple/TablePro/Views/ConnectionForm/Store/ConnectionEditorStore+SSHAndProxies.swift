//
//  ConnectionEditorStore+SSHAndProxies.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSSHConfig

enum JumpHostField: Hashable {
    case host
    case keyFile
}

extension ConnectionEditorStore {
    // An SSH tunnel forwards one endpoint, so a host list in General reaches its first host only.
    var tunnelHostListAdvice: String? {
        guard draft.transport == .ssh,
              let field = ConnectionEditorEngine.visibleHostListFields(draft, traits).first else { return nil }
        let hosts = draft.fieldValues[field.id] ?? field.defaultValue ?? ""
        return TunnelHostListAdvice.message(fieldId: field.id, hosts: hosts)
    }

    // A file database offers only where the file lives, so the picker reads as a location, not a transport.
    var transportIsLocationChoice: Bool {
        traits.supportsRemoteDatabaseFile && availableTransports.allSatisfy { $0 == nil || $0 == .remoteFile }
    }

    // The engine flags a whole hop; this is the field it still lacks, in the order SSHJumpHost.isValid checks.
    func missingJumpHostField(_ id: UUID) -> JumpHostField? {
        guard let hop = draft.ssh.jumpHosts.first(where: { $0.id == id }) else { return nil }
        if hop.host.isEmpty { return .host }
        if hop.authMethod == .privateKey, hop.privateKeyPath.isEmpty { return .keyFile }
        return nil
    }
}

// Ported from the old Network pane with its wording; the ids are the plugins' host list fields.
enum TunnelHostListAdvice {
    static func message(fieldId: String, hosts: String) -> String? {
        switch fieldId {
        case "redisSentinelHosts":
            return String(
                localized: "Sentinel mode cannot run through a tunnel. Set Connection Mode to Standalone and enter a data node, or turn the tunnel off."
            )
        case "redisClusterHosts":
            return String(
                localized: "TablePro connects to the first node over a tunnel, as a single server. Keys on other nodes cannot be reached."
            )
        default:
            break
        }
        guard hosts.contains(",") else { return nil }
        switch fieldId {
        case "mongoHosts":
            return String(localized: "TablePro connects to the first host over a tunnel. Replica set failover is not available.")
        case "kafkaBootstrapServers":
            return String(localized: "TablePro connects to the first broker over a tunnel. Partitions led by other brokers cannot be read.")
        default:
            return String(localized: "TablePro connects to the first host over a tunnel. The other hosts are not used.")
        }
    }
}
