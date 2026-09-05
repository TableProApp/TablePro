//
//  ConnectionFormCoordinator+Transport.swift
//  TablePro
//

import Foundation

/// The form's transport selection, in the same vocabulary the connect path reads.
///
/// `DatabaseConnection.activeTunnelKind` answers `nil` whenever more than one transport is
/// enabled, and `DatabaseManager.activeTunnelManager` then opens a direct connection to the
/// database host, so a connection carrying two enabled transports silently bypasses both. The
/// form used to allow exactly that, warn about it in a banner, and leave Save enabled. Editing
/// one optional value instead of five booleans makes the state unrepresentable rather than
/// discouraged.
@MainActor
extension ConnectionFormCoordinator {
    var transport: ConnectionTunnelKind? {
        get {
            if ssh.state.enabled {
                return supportsRemoteDatabaseFile ? .remoteFile : .ssh
            }
            if cloudflareTunnel.state.enabled { return .cloudflare }
            if cloudSQLProxy.state.enabled { return .cloudSQLProxy }
            if socksProxy.state.enabled { return .socksProxy }
            if tunnelCommand.state.enabled { return .tunnelCommand }
            return nil
        }
        set {
            let usesSSHServer = newValue == .ssh || newValue == .remoteFile
            ssh.state.enabled = usesSSHServer
            if newValue != .remoteFile {
                ssh.state.remoteFilePath = ""
            }
            if newValue != .ssh {
                /// Only a port forward has something to forward to, and the field lives in the SSH
                /// sections, so a path left behind by another transport would be unreachable while
                /// still dimming Host and Port and still being written by `network.write(into:)`.
                network.sshForwardUnixSocketPath = ""
            }
            cloudflareTunnel.state.enabled = newValue == .cloudflare
            cloudSQLProxy.state.enabled = newValue == .cloudSQLProxy
            socksProxy.state.enabled = newValue == .socksProxy
            tunnelCommand.state.enabled = newValue == .tunnelCommand
            testSucceeded = false
        }
    }

    /// Direct first, then whatever this driver can reach a server through.
    ///
    /// `.ssh` and `.remoteFile` are the same SSH server carrying different cargo, and both are
    /// stored in `ssh.state`, so only one of them can be offered: the getter decides which by
    /// capability, and offering both would let the picker select `.ssh` and read back `.remoteFile`.
    var availableTransports: [ConnectionTunnelKind?] {
        var transports: [ConnectionTunnelKind?] = [nil]
        if supportsRemoteDatabaseFile {
            transports.append(.remoteFile)
        } else if services.pluginManager.supportsSSH(for: network.type) {
            transports.append(.ssh)
        }
        if services.pluginManager.supportsCloudflareTunnel(for: network.type) {
            transports.append(.cloudflare)
        }
        if network.type.supportsCloudSQLProxy {
            transports.append(.cloudSQLProxy)
        }
        if services.pluginManager.supportsSOCKSProxy(for: network.type) {
            transports.append(.socksProxy)
        }
        if services.pluginManager.supportsTunnelCommand(for: network.type) {
            transports.append(.tunnelCommand)
        }
        return transports
    }

    var supportsRemoteDatabaseFile: Bool {
        services.pluginManager.supportsRemoteDatabaseFile(for: network.type)
    }

    var supportsSSL: Bool {
        services.pluginManager.supportsSSL(for: network.type)
    }

    /// Collapses whatever the stored connection carries onto a single transport.
    ///
    /// Assigning through the setter is what does the work: a connection saved by an older build
    /// with two transports enabled keeps the first and loses the rest, which is a repair, because
    /// the connect path was reaching that database directly. A transport the current type no
    /// longer offers falls back to direct, or a MySQL connection changed to SQLite would keep a
    /// Cloudflare tunnel nothing in the form can see or switch off.
    func normalizeTransport() {
        let current = transport
        transport = availableTransports.contains(current) ? current : nil
    }
}
