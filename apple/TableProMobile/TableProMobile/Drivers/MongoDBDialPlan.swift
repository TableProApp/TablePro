import Foundation
import TableProConnectionLibrary
import TableProDatabase
import TableProModels

// What the MongoDB driver is handed to dial, with the Mac's tunnel rules (DatabaseManager+Tunnel.swift).
nonisolated enum MongoDBDialPlan {
    static let hostsField = "mongoHosts"
    static let srvField = "mongoUseSrv"
    static let authSourceField = "mongoAuthSource"
    static let authMechanismField = "mongoAuthMechanism"
    static let replicaSetField = "mongoReplicaSet"
    static let directConnectionField = "mongoParam_directConnection"

    static let srvBehindTunnelMessage = String(localized: """
        An SRV record names servers the tunnel cannot reach, so the connection would go around it. Turn the tunnel \
        off, or list the servers under Hosts and turn off Use SRV Record.
        """)

    static let verifyNeedsCAMessage = String(localized: """
        MongoDB on this device checks the server's certificate only against a CA certificate you add. Add one in \
        the connection's SSL settings, or set SSL Mode to Required.
        """)

    // The plugin turns SRV on by itself for an Atlas name, which behind a tunnel only the host before it carries.
    static func usesSRV(_ connection: DatabaseConnection, preTunnelHost: String?) -> Bool {
        connection.additionalFields[srvField] == "true" || (preTunnelHost ?? connection.host).hasSuffix(".mongodb.net")
    }

    static func seedHosts(of connection: DatabaseConnection) -> [String] {
        let listed = HostListEndpoint.parseList(connection.additionalFields[hostsField] ?? "", defaultPort: connection.port)
        return listed.isEmpty ? [connection.host] : listed.map(\.host)
    }

    // A tunnel forwards one port, so the seed list goes and discovery stops at the forward. An SRV name resolves to
    // the cluster's own servers, which the driver would dial around the tunnel, so it is refused.
    static func additionalFields(of connection: DatabaseConnection, preTunnelHost: String?) throws -> [String: String] {
        var fields = connection.additionalFields
        guard let preTunnelHost else { return fields }
        guard !usesSRV(connection, preTunnelHost: preTunnelHost) else {
            throw DatabaseError(message: srvBehindTunnelMessage)
        }
        fields[hostsField] = nil
        fields[directConnectionField] = "true"
        return fields
    }

    // OpenSSL on iOS has no trust store, so a verify mode needs the user's CA. Behind a tunnel the dialed name is the
    // loopback, so Verify Identity keeps the chain check and drops only the name check.
    static func ssl(_ ssl: DriverSSLConfiguration, tunneled: Bool) throws -> DriverSSLConfiguration {
        guard ssl.verifiesCertificate else { return ssl }
        guard ssl.existingCACertificatePath != nil else {
            throw DatabaseError(message: verifyNeedsCAMessage)
        }
        guard tunneled, ssl.verifiesHostname else { return ssl }
        return DriverSSLConfiguration(
            mode: .verifyCa,
            caCertificatePath: ssl.caCertificatePath,
            clientCertificatePath: ssl.clientCertificatePath,
            clientKeyPath: ssl.clientKeyPath,
            serverName: ssl.serverName
        )
    }
}
