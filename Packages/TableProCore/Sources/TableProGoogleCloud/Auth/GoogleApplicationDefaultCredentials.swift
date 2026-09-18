import Foundation

public enum GoogleApplicationDefaultCredentials: Sendable, Equatable {
    case serviceAccount(GoogleServiceAccountKey)
    case authorizedUser(clientId: String, clientSecret: String, refreshToken: String, quotaProjectId: String?)
    indirect case impersonatedServiceAccount(
        impersonationURL: URL,
        source: GoogleApplicationDefaultCredentials,
        quotaProjectId: String?,
        delegates: [String] = []
    )

    public static let environmentVariable = "GOOGLE_APPLICATION_CREDENTIALS"

    private static let authorizedUserType = "authorized_user"
    private static let impersonatedType = "impersonated_service_account"

    public static var defaultPath: String {
        GoogleCredentialDocument.expandedPath("~/.config/gcloud/application_default_credentials.json")
    }

    public static func load(
        path: String?,
        readFile: (String) -> Data?,
        environment: [String: String]
    ) throws -> GoogleApplicationDefaultCredentials {
        if let configured = configuredPath(explicit: path, environment: environment) {
            guard let contents = readFile(GoogleCredentialDocument.expandedPath(configured)) else {
                throw GoogleAuthError.credentialFileUnreadable
            }
            return try parse(json: contents)
        }
        guard let contents = readFile(defaultPath) else {
            throw GoogleAuthError.applicationDefaultCredentialsNotFound
        }
        return try parse(json: contents)
    }

    public static func parse(json: Data) throws -> GoogleApplicationDefaultCredentials {
        let object = try GoogleCredentialDocument.object(from: json)
        let type = try GoogleCredentialDocument.requiredString(object, "type")
        switch type {
        case GoogleServiceAccountKey.credentialType:
            return .serviceAccount(try GoogleServiceAccountKey.parse(object: object))
        case authorizedUserType:
            return try authorizedUser(from: object)
        case impersonatedType:
            return try impersonated(from: object)
        default:
            throw GoogleAuthError.unsupportedCredentialType(type)
        }
    }

    public var projectHint: String? {
        switch self {
        case .serviceAccount(let key):
            return key.projectId
        case .authorizedUser(_, _, _, let quotaProjectId):
            return quotaProjectId
        case .impersonatedServiceAccount(_, let source, let quotaProjectId, _):
            return quotaProjectId ?? source.projectHint
        }
    }

    private static func configuredPath(explicit: String?, environment: [String: String]) -> String? {
        let candidates = [explicit, environment[environmentVariable]]
        return candidates
            .compactMap { $0.map(GoogleCredentialDocument.trimmed) }
            .first { !$0.isEmpty }
    }

    private static func authorizedUser(from object: [String: Any]) throws -> GoogleApplicationDefaultCredentials {
        .authorizedUser(
            clientId: try GoogleCredentialDocument.requiredString(object, "client_id"),
            clientSecret: try GoogleCredentialDocument.requiredString(object, "client_secret"),
            refreshToken: try GoogleCredentialDocument.requiredString(object, "refresh_token"),
            quotaProjectId: GoogleCredentialDocument.optionalString(object, "quota_project_id")
        )
    }

    private static func impersonated(from object: [String: Any]) throws -> GoogleApplicationDefaultCredentials {
        let rawURL = try GoogleCredentialDocument.requiredString(object, "service_account_impersonation_url")
        let impersonationURL = try GoogleCredentialDocument.trustedGoogleURL(rawURL)
        guard let sourceObject = object["source_credentials"] as? [String: Any] else {
            throw GoogleAuthError.credentialMissingField("source_credentials")
        }
        return .impersonatedServiceAccount(
            impersonationURL: impersonationURL,
            source: try impersonationSource(from: sourceObject),
            quotaProjectId: GoogleCredentialDocument.optionalString(object, "quota_project_id"),
            delegates: delegates(in: object)
        )
    }

    private static func delegates(in object: [String: Any]) -> [String] {
        guard let values = object["delegates"] as? [Any] else { return [] }
        return values
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func impersonationSource(from object: [String: Any]) throws -> GoogleApplicationDefaultCredentials {
        let type = try GoogleCredentialDocument.requiredString(object, "type")
        switch type {
        case GoogleServiceAccountKey.credentialType:
            return .serviceAccount(try GoogleServiceAccountKey.parse(object: object))
        case authorizedUserType:
            return try authorizedUser(from: object)
        default:
            throw GoogleAuthError.unsupportedCredentialType(type)
        }
    }
}

extension GoogleApplicationDefaultCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .serviceAccount(let key):
            return "GoogleApplicationDefaultCredentials.serviceAccount(\(key))"
        case .authorizedUser(let clientId, _, _, let quotaProjectId):
            return "GoogleApplicationDefaultCredentials.authorizedUser(clientId: \(clientId), "
                + "quotaProjectId: \(quotaProjectId ?? "nil"), secrets: <redacted>)"
        case .impersonatedServiceAccount(let url, let source, let quotaProjectId, let delegates):
            return "GoogleApplicationDefaultCredentials.impersonatedServiceAccount(\(url.absoluteString), "
                + "source: \(source), quotaProjectId: \(quotaProjectId ?? "nil"), delegates: \(delegates))"
        }
    }

    public var debugDescription: String {
        description
    }
}
