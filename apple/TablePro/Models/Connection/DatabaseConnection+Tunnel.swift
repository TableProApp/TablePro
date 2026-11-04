//
//  DatabaseConnection+Tunnel.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit

extension DatabaseConnection {
    static let preTunnelHostKey = "preTunnelHost"
    static let preTunnelPortKey = "preTunnelPort"
    static let tunnelSecuresTransportKey = "tunnelSecuresTransport"

    /// The endpoint this connection addressed before a tunnel rewrote it to the local
    /// forward. Absent when the driver dials the server directly. Anything that must
    /// name the real server rather than the socket the driver opens reads these:
    /// pgpass lookups and RDS IAM token signing.
    var preTunnelHost: String? {
        additionalFields[Self.preTunnelHostKey]?.nilIfEmpty
    }

    var preTunnelPort: Int? {
        additionalFields[Self.preTunnelPortKey].flatMap(Int.init)
    }

    /// Set behind a tunnel that encrypts the hop to the server itself and listens on loopback
    /// without TLS, which is the Cloud SQL Auth Proxy.
    var tunnelSecuresTransport: Bool {
        additionalFields[Self.tunnelSecuresTransportKey] == "true"
    }

    /// The host-list fields this connection's driver declares, if any.
    var hostListFieldIds: [String] {
        declaredConnectionFields
            .filter { field in
                if case .hostList = field.fieldType { return true }
                return false
            }
            .map(\.id)
    }

    /// The host list the connection's current settings actually use.
    ///
    /// Redis declares one for Sentinel and one for Cluster, and a field the form has hidden keeps
    /// its old value, so picking the first declared list would forward a Cluster connection to the
    /// Sentinel address the user typed before switching modes, and a Standalone connection to a
    /// list it does not use at all. A list with no visibility rule is always in use.
    var activeHostListFieldIds: [String] {
        let fields = declaredConnectionFields
        var unconditional: [String] = []
        var visible: [String] = []
        for field in fields {
            guard case .hostList = field.fieldType else { continue }
            if field.visibleWhen == nil {
                unconditional.append(field.id)
            } else if fields.isVisible(field, forValues: additionalFields) {
                visible.append(field.id)
            }
        }
        return visible + unconditional
    }

    private var declaredConnectionFields: [ConnectionField] {
        PluginMetadataRegistry.shared.snapshot(for: type)?
            .connection.additionalConnectionFields ?? []
    }

    /// The plugin fields that hold the server this connection dials, while its settings use them.
    var activeServerEndpointFields: ServerEndpointFields? {
        PluginMetadataRegistry.shared.snapshot(for: type)?
            .activeServerEndpointFields(forValues: additionalFields)
    }

    /// Whether a TCP forward can carry this connection's traffic. A type the registry does not
    /// know keeps the tunnel it always opened. A server port its driver would refuse opens no tunnel:
    /// the forward would be dialed at it first, and a value past `Int32` traps in the SSH channel, while
    /// the driver refuses it with a message. The form keeps the transport, so a typo loses no settings.
    var dialsForwardedEndpoint: Bool {
        guard serverEndpointPortIsUsable else { return false }
        return PluginMetadataRegistry.shared.snapshot(for: type)?
            .dialsForwardedEndpoint(forValues: additionalFields) ?? true
    }

    /// The server the driver dials, as the person named it.
    ///
    /// A DuckDB Remote row keeps it in its own fields while the built-in Host stays `localhost`,
    /// so anything that names the server, forwards to it or diagnoses it reads this rather than
    /// `host`. A connection that names its servers in a host list nominates the first, since a
    /// tunnel carries one local port to one remote address.
    var serverEndpoint: (host: String, port: Int) {
        if let fields = activeServerEndpointFields {
            return endpoint(inServerFields: fields)
        }
        guard let first = firstHostListEntry?.endpoint else { return (host, port) }
        return (first.host, first.port)
    }

    var tunnelForwardEndpoint: (host: String, port: Int) {
        serverEndpoint
    }

    /// Whether the server's port field holds a port the driver would dial: empty, which means the
    /// field's default, or a number in range.
    var serverEndpointPortIsUsable: Bool {
        guard let fields = activeServerEndpointFields else { return true }
        let typed = (additionalFields[fields.portFieldId] ?? "").trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return true }
        guard let port = Int(typed) else { return false }
        return (1...65_535).contains(port)
    }

    // An empty port means what its placeholder shows, as the driver reads it.
    private func endpoint(inServerFields fields: ServerEndpointFields) -> (host: String, port: Int) {
        let serverHost = (additionalFields[fields.hostFieldId] ?? "").trimmingCharacters(in: .whitespaces)
        let typed = (additionalFields[fields.portFieldId] ?? "").trimmingCharacters(in: .whitespaces)
        let declaredDefault = declaredConnectionFields.first { $0.id == fields.portFieldId }?.defaultValue
        let serverPort = Int(typed) ?? declaredDefault.flatMap { Int($0) } ?? type.defaultPort
        return (serverHost, serverPort)
    }

    /// An app that predates the form's normalizing stored rows as typed, so a row can still say
    /// `https://` while SSL Mode is Disabled. The driver honors the scheme, and the tunnel has to
    /// as well once it replaces the list with its local forward.
    var tunnelForwardUsesHTTPS: Bool {
        firstHostListEntry.map { HostListEndpoint.usesHTTPS($0.text) } ?? false
    }

    // The driver's TLS runs through a loopback port the tunnel forwards, so the certificate names the server behind it.
    var dialsTunnelTCPForward: Bool {
        switch activeTunnelKind {
        case .ssh: return sshForwardUnixSocketPath == nil
        case .cloudflare, .socksProxy, .tunnelCommand: return true
        case .cloudSQLProxy, .remoteFile, .remoteDatabaseSession, nil: return false
        }
    }

    // A server on a Unix socket refuses every TLS request, and the Cloud SQL Auth Proxy listens in plaintext and does
    // its own mTLS, so both forwards run without TLS. A TCP forward keeps the mode and the CA, and an https:// node
    // left on Disabled verifies as its direct dial does.
    func sslConfigurationThroughTunnel(listenerSecuresTransport: Bool) -> SSLConfiguration {
        var ssl = sslConfig
        if listenerSecuresTransport {
            ssl.mode = .disabled
            ssl.caCertificatePath = ""
            ssl.clientCertificatePath = ""
            ssl.clientKeyPath = ""
        } else if !ssl.isEnabled, tunnelForwardUsesHTTPS {
            ssl.mode = .verifyIdentity
        }
        return ssl
    }

    var tunneledServerName: String? {
        DriverConnectionConfig(
            host: host,
            port: port,
            username: username,
            password: "",
            database: database,
            additionalFields: additionalFields
        ).tunneledServerName
    }

    var hostListEndpoints: [HostListEndpoint] {
        hostListEntries.map(\.endpoint)
    }

    private var firstHostListEntry: (text: String, endpoint: HostListEndpoint)? {
        hostListEntries.first
    }

    private var hostListEntries: [(text: String, endpoint: HostListEndpoint)] {
        activeHostListFieldIds.flatMap { fieldId in
            (additionalFields[fieldId] ?? "").split(separator: ",").map(String.init).compactMap { text in
                HostListEndpoint.parse(text, defaultPort: port).map { (text, $0) }
            }
        }
    }
}
