import Foundation
import TableProPluginKit

// Holds its own copy of the connection's settings, so a driver can ask for a new token without the main actor.
struct AWSIAMTokenSigner: Sendable {
    typealias Target = AWSIAMTokenTarget

    let source: String
    // AWS checks the username inside the token against the one the connection signs in as.
    let username: String
    let fields: [String: String]
    let target: Target

    func token(deadline: ConnectionDeadline?) async throws -> String {
        let credentials = try await AWSDeadlineSession.run(within: deadline) { session in
            try await AWSCredentialResolver.resolve(source: source, fields: fields, session: session)
        }
        return try target.token(username: username, fields: fields, credentials: credentials)
    }
}

extension AWSIAMTokenSigner {
    init(connection: DatabaseConnection, source: String, username: String, fields: [String: String]) {
        self.source = source
        self.username = username
        self.fields = fields
        if connection.type == .redis {
            target = .elastiCache(host: connection.host, tlsDisabled: connection.sslConfig.mode == .disabled)
        } else {
            target = .rds(
                configuredHost: connection.host,
                configuredPort: connection.port,
                preTunnelHost: connection.preTunnelHost,
                preTunnelPort: connection.preTunnelPort,
                defaultPort: PluginMetadataRegistry.shared.snapshot(for: connection.type)?.defaultPort ?? connection.port
            )
        }
    }
}
