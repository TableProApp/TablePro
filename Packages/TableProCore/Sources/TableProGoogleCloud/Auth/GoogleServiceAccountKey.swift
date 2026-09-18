import Foundation

public struct GoogleServiceAccountKey: Sendable, Equatable {
    public let clientEmail: String
    public let privateKeyPEM: String
    public let projectId: String?
    public let tokenURI: URL

    static let credentialType = "service_account"

    public static func parse(fieldValue: String, readFile: (String) -> Data?) throws -> GoogleServiceAccountKey {
        let text = GoogleCredentialDocument.trimmed(fieldValue)
        if text.hasPrefix("{") {
            return try parse(json: Data(text.utf8))
        }
        if text.hasPrefix(GoogleCredentialDocument.pemArmourPrefix) {
            throw GoogleAuthError.credentialIsPEM
        }
        guard !text.isEmpty, let contents = readFile(GoogleCredentialDocument.expandedPath(text)) else {
            throw GoogleAuthError.credentialFileUnreadable
        }
        return try parse(json: contents)
    }

    public static func parse(json: Data) throws -> GoogleServiceAccountKey {
        try parse(object: GoogleCredentialDocument.object(from: json))
    }

    static func parse(object: [String: Any]) throws -> GoogleServiceAccountKey {
        if let type = GoogleCredentialDocument.optionalString(object, "type"), type != credentialType {
            throw GoogleAuthError.unsupportedCredentialType(type)
        }
        let clientEmail = try GoogleCredentialDocument.requiredString(object, "client_email")
        let privateKey = try GoogleCredentialDocument.requiredString(object, "private_key")
        let tokenURI = try GoogleCredentialDocument.optionalString(object, "token_uri")
            .map(GoogleCredentialDocument.trustedTokenEndpoint) ?? GoogleOAuthClient.tokenEndpoint
        return GoogleServiceAccountKey(
            clientEmail: clientEmail,
            privateKeyPEM: privateKey,
            projectId: GoogleCredentialDocument.optionalString(object, "project_id"),
            tokenURI: tokenURI
        )
    }
}

extension GoogleServiceAccountKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "GoogleServiceAccountKey(clientEmail: \(clientEmail), projectId: \(projectId ?? "nil"), privateKey: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}
