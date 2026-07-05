import Foundation

public enum CassandraClientKeyClassifier {
    public static func isEncryptedPrivateKey(_ pem: String) -> Bool {
        pem.contains("ENCRYPTED PRIVATE KEY") || (pem.contains("Proc-Type:") && pem.contains("ENCRYPTED"))
    }

    public static func privateKeyLoadError(keyPEM: String, hasPassphrase: Bool, keyPath: String) -> SSLHandshakeError {
        guard isEncryptedPrivateKey(keyPEM) else {
            return .clientKeyInvalid(serverMessage: "The client key at \(keyPath) is not a valid private key")
        }
        if hasPassphrase {
            return .clientKeyPassphraseIncorrect(serverMessage: "The passphrase for the client key at \(keyPath) is incorrect")
        }
        return .clientKeyPassphraseRequired(serverMessage: "The client key at \(keyPath) is encrypted. Enter its passphrase.")
    }
}
