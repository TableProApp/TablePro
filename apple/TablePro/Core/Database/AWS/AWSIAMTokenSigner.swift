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
        let credentials = try await resolveCredentials(deadline: deadline)
        return try target.token(username: username, fields: fields, credentials: credentials)
    }

    private func resolveCredentials(deadline: ConnectionDeadline?) async throws -> AWSCredentials {
        guard let deadline else {
            return try await AWSCredentialResolver.resolve(source: source, fields: fields)
        }
        let timeout = ConnectionCredentialResolver.credentialRequestTimeout(for: deadline)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await AWSCredentialResolver.resolve(source: source, fields: fields, session: session)
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
