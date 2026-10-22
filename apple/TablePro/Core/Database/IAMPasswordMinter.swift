//
//  IAMPasswordMinter.swift
//  TablePro
//

import Foundation

// Mints for the connect and again for every later sign-in the driver makes, never on the main actor.
enum IAMPasswordMinter: Sendable {
    case aws(AWSIAMTokenSigner)
    case redshift(RedshiftIAMSignIn)
    case googleCloud(CloudSQLIAMLogin)

    // Only AWS requests take the deadline: a Google token request carries its own 30-second limit.
    func mint(deadline: ConnectionDeadline?) async throws -> ResolvedSignIn {
        switch self {
        case .aws(let signer):
            return ResolvedSignIn(username: nil, password: try await signer.token(deadline: deadline))
        case .redshift(let signIn):
            return try await signIn.signIn(deadline: deadline)
        case .googleCloud(let login):
            return ResolvedSignIn(username: nil, password: try await CloudSQLIAMTokenCache.shared.accessToken(for: login))
        }
    }

    // A later sign-in is past the connect's deadline.
    var refreshPassword: @Sendable () async throws -> String {
        { try await mint(deadline: nil).password }
    }
}
