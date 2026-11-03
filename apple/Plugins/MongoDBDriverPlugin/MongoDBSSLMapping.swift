import Foundation
import TableProPluginKit

// What the stream initiator hands libmongoc for a tunnel's forward, as `mongoc_ssl_opt_t` takes it.
nonisolated struct MongoDBTunnelTLS: Equatable, Sendable {
    let serverName: String
    let caFile: String?
    let certificateKeyFile: String?
    let certificateKeyPassword: String?
    let allowsInvalidHostname: Bool
    let allowsInvalidCertificate: Bool

    static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
}

nonisolated enum MongoDBSSLMapping {
    static func uriOptions(for ssl: SSLConfiguration, certificateKeyFile: String? = nil) -> [MongoDBURIOption] {
        guard ssl.isEnabled else { return [] }
        var options = [MongoDBURIOption(key: "tls", value: "true")]
        switch ssl.mode {
        case .preferred, .required:
            options.append(MongoDBURIOption(key: "tlsAllowInvalidCertificates", value: "true"))
        case .verifyCa:
            options.append(MongoDBURIOption(key: "tlsAllowInvalidHostnames", value: "true"))
        case .disabled, .verifyIdentity:
            break
        }
        if let caFile = caFile(for: ssl) {
            options.append(MongoDBURIOption(key: "tlsCAFile", value: caFile))
        }
        if let keyFile = keyFile(for: ssl, combined: certificateKeyFile) {
            options.append(MongoDBURIOption(key: "tlsCertificateKeyFile", value: keyFile))
        }
        return options
    }

    // libmongoc checks, and sends as SNI, the host it dials, and no URI option names another, so on a forward the
    // initiator does the TLS against the server behind the tunnel. The URI's TLS options no longer apply there.
    static func tunnelTLS(
        for ssl: SSLConfiguration,
        serverName: String?,
        certificateKeyFile: String? = nil,
        certificateKeyPassword: String? = nil
    ) -> MongoDBTunnelTLS? {
        guard ssl.isEnabled, let serverName, !serverName.isEmpty else { return nil }
        return MongoDBTunnelTLS(
            serverName: serverName,
            caFile: caFile(for: ssl),
            certificateKeyFile: keyFile(for: ssl, combined: certificateKeyFile),
            certificateKeyPassword: certificateKeyPassword?.isEmpty == false ? certificateKeyPassword : nil,
            allowsInvalidHostname: !ssl.verifiesHostname,
            allowsInvalidCertificate: !ssl.verifiesCertificate
        )
    }

    private static func caFile(for ssl: SSLConfiguration) -> String? {
        ssl.verifiesCertificate && !ssl.caCertificatePath.isEmpty ? ssl.caCertificatePath : nil
    }

    private static func keyFile(for ssl: SSLConfiguration, combined: String?) -> String? {
        let keyFile = combined ?? ssl.clientCertificatePath
        return keyFile.isEmpty ? nil : keyFile
    }
}
