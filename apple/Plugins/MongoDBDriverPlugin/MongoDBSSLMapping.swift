import Foundation
import TableProPluginKit

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
        if ssl.verifiesCertificate, !ssl.caCertificatePath.isEmpty {
            options.append(MongoDBURIOption(key: "tlsCAFile", value: ssl.caCertificatePath))
        }
        let certificateKeyFile = certificateKeyFile ?? ssl.clientCertificatePath
        if !certificateKeyFile.isEmpty {
            options.append(MongoDBURIOption(key: "tlsCertificateKeyFile", value: certificateKeyFile))
        }
        return options
    }
}
