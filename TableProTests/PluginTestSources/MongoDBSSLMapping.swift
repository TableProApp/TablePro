import Foundation
import TableProPluginKit

enum MongoDBSSLMapping {
    static func uriParameters(for ssl: SSLConfiguration) -> [String] {
        guard ssl.isEnabled else { return [] }
        var params: [String] = ["tls=true"]
        switch ssl.mode {
        case .preferred, .required:
            params.append("tlsAllowInvalidCertificates=true")
        case .verifyCa:
            params.append("tlsAllowInvalidHostnames=true")
        case .disabled, .verifyIdentity:
            break
        }
        if ssl.verifiesCertificate, !ssl.caCertificatePath.isEmpty {
            let encoded = ssl.caCertificatePath
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? ssl.caCertificatePath
            params.append("tlsCAFile=\(encoded)")
        }
        if !ssl.clientCertificatePath.isEmpty {
            let encoded = ssl.clientCertificatePath
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? ssl.clientCertificatePath
            params.append("tlsCertificateKeyFile=\(encoded)")
        }
        return params
    }
}
