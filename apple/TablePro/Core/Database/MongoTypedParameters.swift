//
//  MongoTypedParameters.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

// The parameters typed into a MongoDB connection (its `mongoParam_` fields) that reach the driver. The connection's own
// fields own their options, so a parameter named like one, in any case or under an old `ssl` name, never overrides it,
// as the plugin's MongoDBConnectionURI rules. Copy Connection String and the backup tools both follow this.
internal enum MongoTypedParameters {
    private static let fieldOwnedKeys: Set<String> = [
        "connecttimeoutms", "serverselectiontimeoutms", "authsource", "authmechanism", "replicaset", "uuidrepresentation",
        "tls", "tlsallowinvalidcertificates", "tlsallowinvalidhostnames", "tlscafile", "tlscertificatekeyfile"
    ]

    // libmongoc and the tools' Go driver still read these as the `tls` options.
    private static let deprecatedAliases = [
        "ssl": "tls",
        "sslinsecure": "tlsinsecure",
        "sslallowinvalidcertificates": "tlsallowinvalidcertificates",
        "sslallowinvalidhostnames": "tlsallowinvalidhostnames",
        "sslcertificateauthorityfile": "tlscafile",
        "sslclientcertificatekeyfile": "tlscertificatekeyfile",
        "sslclientcertificatekeypassword": "tlscertificatekeyfilepassword"
    ]

    static func canonicalKey(_ key: String) -> String {
        let lowered = key.lowercased()
        return deprecatedAliases[lowered] ?? lowered
    }

    // `written` names the options the string already carries. With TLS on, the SSL mode decides certificate checking,
    // and a mode that skips verification already turns off the revocation checks a driver refuses beside it.
    static func sent(
        by connection: DatabaseConnection,
        besides written: [String],
        tls: Bool,
        skipsVerification: Bool
    ) -> [(key: String, value: String)] {
        var taken = fieldOwnedKeys.union(written.map(canonicalKey))
        if tls {
            taken.insert("tlsinsecure")
        }
        if skipsVerification {
            taken.formUnion(["tlsdisableocspendpointcheck", "tlsdisablecertificaterevocationcheck"])
        }
        return connection.additionalFields
            .compactMap { key, value -> (key: String, value: String)? in
                // A credential is never a typed option; the backup tools get the Keychain's copy separately.
                guard key.hasPrefix("mongoParam_"), !value.isEmpty,
                      !ConnectionSecretOptions.isSecret(key: key, value: value) else { return nil }
                let name = String(key.dropFirst("mongoParam_".count))
                return name.isEmpty ? nil : (name, value)
            }
            .sorted { $0.key < $1.key }
            .filter { taken.insert(canonicalKey($0.key)).inserted }
    }
}
