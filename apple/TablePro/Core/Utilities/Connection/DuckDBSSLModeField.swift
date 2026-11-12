//
//  DuckDBSSLModeField.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The `sslmode` of a `quack://` URL, carried by the DuckDB driver's own SSL Mode field rather than
/// the built-in SSL section it never reads.
///
/// Automatic is Quack's own default and has no URL value. A pinned certificate travels as
/// `ssl_fingerprint`, Quack's own ATTACH option name, since no `sslmode` value says "pin": a copy that
/// dropped it would reopen as Automatic, which is plain HTTP on a loopback host.
internal enum DuckDBSSLModeField {
    static let fieldId = "duckdbSSLMode"
    static let fingerprintFieldId = "duckdbCertificateFingerprint"
    static let fingerprintQueryName = "ssl_fingerprint"

    static let automatic = "automatic"
    static let disabled = "disabled"
    static let required = "required"
    static let verifyIdentity = "verifyIdentity"
    static let verifyFingerprint = "verifyFingerprint"

    // Hex digits and colons are all a fingerprint holds; anything else is escaped so it cannot start another parameter.
    private static let fingerprintAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":"))

    static func fields(for mode: SSLMode?, disablesTLS: Bool, fingerprint: String?) -> [String: String] {
        let pinned = fingerprint?.trimmingCharacters(in: .whitespaces) ?? ""
        guard pinned.isEmpty else {
            return [fieldId: verifyFingerprint, fingerprintFieldId: pinned]
        }
        return [fieldId: fieldValue(for: mode, disablesTLS: disablesTLS)]
    }

    static func fingerprintParam(for fields: [String: String]) -> String? {
        guard fields[fieldId] == verifyFingerprint else { return nil }
        let pinned = (fields[fingerprintFieldId] ?? "").trimmingCharacters(in: .whitespaces)
        guard !pinned.isEmpty else { return nil }
        let encoded = pinned.addingPercentEncoding(withAllowedCharacters: fingerprintAllowed) ?? pinned
        return "\(fingerprintQueryName)=\(encoded)"
    }

    // Quack has no opportunistic or chain-only check: Preferred falls to Required as etcd's does, and Verify CA to the
    // one verifying mode, which refuses what Verify CA would refuse and more.
    static func fieldValue(for mode: SSLMode?, disablesTLS: Bool) -> String {
        if disablesTLS { return disabled }
        switch mode {
        case nil:
            return automatic
        case .disabled:
            return disabled
        case .preferred, .required:
            return required
        case .verifyCa, .verifyIdentity:
            return verifyIdentity
        }
    }

    static func sslMode(forFieldValue value: String?) -> SSLMode? {
        switch value {
        case disabled:
            return .disabled
        case required:
            return .required
        case verifyIdentity:
            return .verifyIdentity
        default:
            return nil
        }
    }
}
