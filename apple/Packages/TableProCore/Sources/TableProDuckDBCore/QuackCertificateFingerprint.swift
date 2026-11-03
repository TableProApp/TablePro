import Foundation

public enum QuackCertificateFingerprint {
    /// Quack's own reading of a pin (`QuackUri::NormalizeFingerprint`, quack_uri.cpp:14-38 at f96420ed): an
    /// optional `sha256:` prefix in any case, then 64 hex digits in any case, with colons or spaces between
    /// them as `openssl x509 -fingerprint` and Keychain Access print them. Read here so a typo is refused
    /// before the connection opens, in words that name the field, rather than after the tunnel and the
    /// extension download. The result is Quack's canonical form, 64 uppercase digits.
    public static func normalized(_ input: String) throws -> String {
        var text = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { throw QuackConnectError.missingFingerprint }
        let prefix = "sha256:"
        if text.prefix(prefix.count).lowercased() == prefix {
            text = text.dropFirst(prefix.count)
        }
        var digits = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != ":" && scalar != " " {
            guard scalar.properties.isASCIIHexDigit else { throw QuackConnectError.invalidFingerprint }
            digits.append(scalar)
        }
        guard digits.count == 64 else { throw QuackConnectError.invalidFingerprint }
        return String(digits).uppercased()
    }
}
