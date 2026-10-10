//
//  IAMPasswordMinter.swift
//  TablePro
//

import Foundation

/// Mints the token an IAM connection signs in with, for the connect and again for each sign-in the
/// driver makes after it. It never needs the main actor.
enum IAMPasswordMinter: Sendable {
    case aws(AWSIAMTokenSigner)
    case googleCloud(CloudSQLIAMLogin)

    /// A Google token request carries its own 30-second limit, and the connect races the whole
    /// resolution against its deadline, so only the AWS credential requests take the deadline.
    func mint(deadline: ConnectionDeadline?) async throws -> String {
        switch self {
        case .aws(let signer):
            return try await signer.token(deadline: deadline)
        case .googleCloud(let login):
            return try await CloudSQLIAMTokenCache.shared.accessToken(for: login)
        }
    }

    /// For the sign-ins a driver makes after the connect, which the connect's deadline no longer covers.
    var refreshPassword: @Sendable () async throws -> String {
        { try await mint(deadline: nil) }
    }
}
