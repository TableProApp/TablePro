import Foundation
import TableProPluginKit

nonisolated enum MongoDBSSLMapping {
    static func uriParameters(for ssl: SSLConfiguration, certificateKeyFile: String? = nil) -> [String] {
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
        let certificateKeyFile = certificateKeyFile ?? ssl.clientCertificatePath
        if !certificateKeyFile.isEmpty {
            let encoded = certificateKeyFile
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                ?? certificateKeyFile
            params.append("tlsCertificateKeyFile=\(encoded)")
        }
        return params
    }
}
