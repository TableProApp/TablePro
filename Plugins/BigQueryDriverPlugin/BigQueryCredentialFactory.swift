import Foundation
import TableProGoogleCloud
import TableProPluginKit

internal enum BigQueryConnectionFields {
    static let authMethod = "bqAuthMethod"
    static let serviceAccountKey = "bqServiceAccountJson"
    static let projectId = "bqProjectId"
    static let location = "bqLocation"
    static let oauthClientId = "bqOAuthClientId"
    static let oauthClientSecret = "bqOAuthClientSecret"
    static let oauthRefreshToken = "bqOAuthRefreshToken"
    static let maximumBytesBilled = "bqMaxBytesBilled"
}

internal enum BigQueryAuthMethod: String, Sendable {
    case serviceAccount
    case applicationDefault = "adc"
    case oauth
}

internal struct BigQueryCredentials: Sendable {
    let projectId: String
    let tokenProvider: any GoogleAccessTokenProviding
}

internal enum BigQueryCredentialFactory {
    static let scopes = ["https://www.googleapis.com/auth/bigquery"]

    static func credentials(config: DriverConnectionConfig) throws -> BigQueryCredentials {
        try credentials(
            fields: config.additionalFields,
            password: config.password,
            readFile: { FileManager.default.contents(atPath: $0) },
            environment: ProcessInfo.processInfo.environment,
            http: URLSessionGoogleHTTPClient(),
            refreshTokenStore: GoogleKeychainRefreshTokenStore()
        )
    }

    static func credentials(
        fields: [String: String],
        password: String,
        readFile: (String) -> Data?,
        environment: [String: String],
        http: any GoogleHTTPClient,
        refreshTokenStore: any GoogleRefreshTokenStore
    ) throws -> BigQueryCredentials {
        switch try authMethod(fields: fields) {
        case .serviceAccount:
            let key = try GoogleServiceAccountKey.parse(
                fieldValue: try serviceAccountValue(fields: fields, password: password),
                readFile: readFile
            )
            return BigQueryCredentials(
                projectId: try projectId(fields: fields, hint: key.projectId),
                tokenProvider: GoogleTokenProviders.serviceAccount(key, scopes: scopes, http: http)
            )
        case .applicationDefault:
            let credentials = try GoogleApplicationDefaultCredentials.load(
                path: nil,
                readFile: readFile,
                environment: environment
            )
            return BigQueryCredentials(
                projectId: try projectId(fields: fields, hint: credentials.projectHint),
                tokenProvider: GoogleTokenProviders.applicationDefault(credentials, scopes: scopes, http: http)
            )
        case .oauth:
            let client = GoogleOAuthClient(
                clientId: try required(BigQueryConnectionFields.oauthClientId, in: fields),
                clientSecret: try required(BigQueryConnectionFields.oauthClientSecret, in: fields)
            )
            return BigQueryCredentials(
                projectId: try projectId(fields: fields, hint: nil),
                tokenProvider: GoogleTokenProviders.oauthClient(
                    client,
                    pastedRefreshToken: trimmed(fields[BigQueryConnectionFields.oauthRefreshToken]),
                    store: refreshTokenStore,
                    http: http
                )
            )
        }
    }

    static func authMethod(fields: [String: String]) throws -> BigQueryAuthMethod {
        guard let raw = trimmed(fields[BigQueryConnectionFields.authMethod]) else {
            return .serviceAccount
        }
        guard let method = BigQueryAuthMethod(rawValue: raw) else {
            throw BigQueryConfigurationError.unknownAuthMethod
        }
        return method
    }

    static func projectId(fields: [String: String], hint: String?) throws -> String {
        if let configured = trimmed(fields[BigQueryConnectionFields.projectId]) {
            return configured
        }
        if let hinted = trimmed(hint) {
            return hinted
        }
        throw BigQueryConfigurationError.missingField(BigQueryConnectionFields.projectId)
    }

    private static func serviceAccountValue(fields: [String: String], password: String) throws -> String {
        if let value = trimmed(fields[BigQueryConnectionFields.serviceAccountKey]) {
            return value
        }
        if let value = trimmed(password) {
            return value
        }
        throw BigQueryConfigurationError.missingField(BigQueryConnectionFields.serviceAccountKey)
    }

    private static func required(_ key: String, in fields: [String: String]) throws -> String {
        guard let value = trimmed(fields[key]) else {
            throw BigQueryConfigurationError.missingField(key)
        }
        return value
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
