//
//  DatabaseManager+RDSEndpoint.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension DatabaseManager {
    // RDS accepts a token only for the endpoint AWS issued, never a CNAME of the user's own. The connection dials
    // that endpoint as well: signing it while dialling the CNAME would let whoever answers the CNAME's next lookup
    // receive the token. The found name is never saved, so each connect follows the CNAME again.
    //
    // Only a direct dial: behind a tunnel the far end resolves the name, its DNS can disagree with this Mac's, and a
    // bastion's PermitOpen matches the name as typed. The RDS Endpoint field covers a forward.
    //
    // Runs before the connect's deadline starts, as the first sign-in approval does, because it can ask a person.
    internal func resolvingRDSEndpointAlias(
        of connection: DatabaseConnection,
        trigger: ConnectTrigger
    ) async throws -> DatabaseConnection {
        guard ConnectionCredentialResolver.signsRDSToken(for: connection),
              connection.enabledTunnelKinds.isEmpty,
              AWSEndpointHost.isAliasCandidate(connection.host)
        else { return connection }
        let lookupDeadline = ConnectionDeadline(configuredSeconds: connection.connectTimeoutSeconds)
        let lookup = await AWSEndpointHost.rdsEndpoint(
            behind: connection.host,
            resolver: cnameResolver,
            within: lookupDeadline.remainingDuration
        )
        try Task.checkCancellation()
        switch lookup {
        case .notFound:
            return connection
        case .failed:
            // Signing the typed name instead only earns an access denied, which reads as a credential problem and
            // ends a reconnect that a working DNS would have let through.
            throw AWSAuthError.endpointLookupFailed(host: connection.host)
        case .found(let endpoint):
            Self.logger.info("AWS IAM signs in as RDS endpoint \(endpoint, privacy: .private), which \(connection.host, privacy: .private) points to")
            var resolved = connection
            resolved.host = endpoint
            // A definition from someone else was approved for the name it carries, and whoever runs that name's DNS
            // can point it at another database at any time, so each endpoint behind it is approved on its own.
            if connection.origin != .thisMac {
                try await localCredentialConsent.check(resolved, trigger: trigger)
            }
            return resolved
        }
    }
}
