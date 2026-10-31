import Foundation

// MongoDB connection-string options that hold a credential. A pasted URI keeps unknown options as
// plain `mongoParam_` fields, so these are named here to keep them out of exports, links and sync.
public enum ConnectionSecretOptions {
    public static let mongoOptionPrefix = "mongoParam_"
    public static let mongoSessionTokenFieldId = "mongoAWSSessionToken"

    static let mongoSecretOptions: Set<String> = [
        "tlscertificatekeyfilepassword",
        "sslclientcertificatekeypassword",
        "proxypassword",
    ]
    static let mongoKeyPassphraseOptions: Set<String> = [
        "tlscertificatekeyfilepassword",
        "sslclientcertificatekeypassword",
    ]
    static let mechanismPropertiesOption = "authmechanismproperties"
    static let sessionTokenProperty = "AWS_SESSION_TOKEN"

    public static func isSecret(key: String, value: String) -> Bool {
        if key.caseInsensitiveCompare(mongoSessionTokenFieldId) == .orderedSame { return true }
        guard let option = mongoOption(in: key) else { return false }
        if mongoSecretOptions.contains(option) { return true }
        return option == mechanismPropertiesOption && splitSessionToken(from: value).sessionToken != nil
    }

    // Mechanism properties keep everything but the token.
    public static func removingSecrets(from fields: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        for (key, value) in fields {
            guard isSecret(key: key, value: value) else {
                kept[key] = value
                continue
            }
            if let option = mongoOption(in: key), isMongoMechanismProperties(option: option),
               let remaining = splitSessionToken(from: value).remaining {
                kept[key] = remaining
            }
        }
        return kept
    }

    // The lowercased option name of a `mongoParam_` field, nil for any other field.
    public static func mongoOption(in key: String) -> String? {
        guard key.count > mongoOptionPrefix.count,
              key.lowercased().hasPrefix(mongoOptionPrefix.lowercased())
        else { return nil }
        return String(key.dropFirst(mongoOptionPrefix.count)).lowercased()
    }

    public static func isMongoKeyPassphrase(option: String) -> Bool {
        mongoKeyPassphraseOptions.contains(option.lowercased())
    }

    public static func isMongoProxyPassword(option: String) -> Bool {
        option.lowercased() == "proxypassword"
    }

    public static func isMongoMechanismProperties(option: String) -> Bool {
        option.lowercased() == mechanismPropertiesOption
    }

    // `authMechanismProperties` is `KEY:value` pairs joined by commas; libmongoc reads keys without case.
    public static func splitSessionToken(from properties: String) -> (remaining: String?, sessionToken: String?) {
        var kept: [String] = []
        var token: String?
        for pair in properties.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare(sessionTokenProperty) == .orderedSame {
                let value = parts.count > 1 ? String(parts[1]) : ""
                if !value.isEmpty { token = value }
            } else {
                kept.append(String(pair))
            }
        }
        return (kept.isEmpty ? nil : kept.joined(separator: ","), token)
    }

    public static func joiningSessionToken(_ token: String, to properties: String?) -> String {
        let remaining = properties.flatMap { splitSessionToken(from: $0).remaining }
        let pair = "\(sessionTokenProperty):\(token)"
        guard let remaining else { return pair }
        return "\(remaining),\(pair)"
    }
}
