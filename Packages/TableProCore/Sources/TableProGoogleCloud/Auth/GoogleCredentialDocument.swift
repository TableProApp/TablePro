import Foundation

internal enum GoogleCredentialDocument {
    static let pemArmourPrefix = "-----BEGIN"

    private static let byteOrderMark: Character = "\u{FEFF}"
    private static let utf8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])

    static func trimmed(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.first == byteOrderMark {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func object(from data: Data) throws -> [String: Any] {
        let body = data.starts(with: utf8ByteOrderMark) ? data.dropFirst(utf8ByteOrderMark.count) : data[...]
        guard let decoded = String(bytes: body, encoding: .utf8) else {
            throw GoogleAuthError.credentialNotJSON
        }
        let text = trimmed(decoded)
        if text.hasPrefix(pemArmourPrefix) {
            throw GoogleAuthError.credentialIsPEM
        }
        guard text.hasPrefix("{"),
              let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let object = parsed as? [String: Any]
        else {
            throw GoogleAuthError.credentialNotJSON
        }
        return object
    }

    static func requiredString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = optionalString(object, key) else {
            throw GoogleAuthError.credentialMissingField(key)
        }
        return value
    }

    static func optionalString(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static func trustedGoogleURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), GoogleEndpointPolicy.isTrustedGoogleAPI(url) else {
            throw GoogleAuthError.untrustedEndpoint(URL(string: raw)?.host ?? "")
        }
        return url
    }

    static func trustedTokenEndpoint(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), GoogleEndpointPolicy.isTrustedTokenEndpoint(url) else {
            throw GoogleAuthError.untrustedEndpoint(URL(string: raw)?.host ?? "")
        }
        return url
    }

    static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
