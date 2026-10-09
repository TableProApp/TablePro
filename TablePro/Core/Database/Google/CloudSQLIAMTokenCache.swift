//
//  CloudSQLIAMTokenCache.swift
//  TablePro
//

import Foundation
import TableProGoogleCloud
import TableProPluginKit

/// What a Cloud SQL IAM connection signs in with, copied from the connection so a token can be
/// minted off the main actor.
struct CloudSQLIAMLogin: Sendable, Equatable {
    let connectionId: UUID
    let source: GoogleCredentialSource
}

/// One token provider per connection, so the connect, each metadata connection, a reconnect and a
/// backup share a token until five minutes before it expires.
actor CloudSQLIAMTokenCache {
    static let shared = CloudSQLIAMTokenCache()

    /// The scope `gcloud sql generate-login-token` and the Cloud SQL connectors ask for. It allows a
    /// database sign-in and nothing else, so a token that leaks cannot call another Google API.
    static let scopes = ["https://www.googleapis.com/auth/sqlservice.login"]

    /// The credential bytes a provider was built from. An edited key or a new gcloud login reads
    /// different bytes, which replaces the provider and the token it holds.
    private struct Fingerprint: Equatable {
        let source: GoogleCredentialSource
        let documents: [String: Data]
    }

    private struct Entry {
        let fingerprint: Fingerprint
        let provider: any GoogleAccessTokenProviding
    }

    private let readFile: @Sendable (String) -> Data?
    private let environment: @Sendable () -> [String: String]
    private let http: any GoogleHTTPClient
    private var entries: [UUID: Entry] = [:]

    init(
        readFile: @escaping @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) },
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        http: any GoogleHTTPClient = URLSessionGoogleHTTPClient()
    ) {
        self.readFile = readFile
        self.environment = environment
        self.http = http
    }

    func accessToken(for login: CloudSQLIAMLogin) async throws -> String {
        let provider = try provider(for: login)
        do {
            return try await provider.accessToken()
        } catch let error as GoogleAuthError {
            throw CloudSQLIAMAuthError.authentication(error)
        }
    }

    private func provider(for login: CloudSQLIAMLogin) throws -> any GoogleAccessTokenProviding {
        let readFile = readFile
        var documents: [String: Data] = [:]
        let credentials: GoogleCredentials
        do {
            credentials = try GoogleTokenProviders.credentials(
                from: login.source,
                scopes: Self.scopes,
                restrictsUserLogin: true,
                readFile: { path in
                    let contents = readFile(path)
                    documents[path] = contents
                    return contents
                },
                environment: environment(),
                http: http
            )
        } catch let error as GoogleAuthError {
            entries[login.connectionId] = nil
            throw CloudSQLIAMAuthError.authentication(error)
        }
        let fingerprint = Fingerprint(source: login.source, documents: documents)
        if let entry = entries[login.connectionId], entry.fingerprint == fingerprint {
            return entry.provider
        }
        entries[login.connectionId] = Entry(fingerprint: fingerprint, provider: credentials.tokenProvider)
        return credentials.tokenProvider
    }
}

enum CloudSQLIAMAuthError: LocalizedError, Equatable {
    case authentication(GoogleAuthError)

    var errorDescription: String? {
        switch self {
        case .authentication(.tokenRequestRejected(_, .some("invalid_scope"))):
            return String(localized: "The gcloud login does not allow Cloud SQL sign-in. Run gcloud auth application-default login again, without --scopes.")
        case .authentication(let error):
            return GoogleAuthErrorMessages.message(for: error)
        }
    }
}
