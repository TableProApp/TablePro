import Foundation
import TableProPluginKit

enum TLSFailureFixtures {
    static let configurationFailures: [SSLHandshakeError] = [
        .serverRejectedPlaintext(serverMessage: "no pg_hba.conf entry for host, no encryption"),
        .serverRequiresPlaintext(serverMessage: "server does not support SSL"),
        .clientCertRequired(serverMessage: "tlsv13 alert certificate required"),
        .clientKeyPassphraseRequired(serverMessage: "private key is encrypted"),
        .clientKeyPassphraseIncorrect(serverMessage: "bad decrypt"),
        .clientKeyInvalid(serverMessage: "no start line")
    ]

    static let certificateFailures: [SSLHandshakeError] = [
        .untrustedCertificate(serverMessage: "self-signed certificate in certificate chain"),
        .hostnameMismatch(serverMessage: "certificate is not valid for db.example.com")
    ]

    static let transientFailures: [SSLHandshakeError] = [
        .cipherMismatch(serverMessage: "A TLS error caused the secure connection to fail."),
        .unknown(serverMessage: "ssl handshake failed")
    ]
}
