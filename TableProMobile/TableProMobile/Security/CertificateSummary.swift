import Foundation
import Security

nonisolated enum CertificateSummary {
    static func subject(ofFirstCertificateIn pem: String) -> String? {
        guard let block = PEMDocument.inspect(pem).certificates.first,
              let der = der(from: block.text),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    static func der(from blockText: String) -> Data? {
        let body = blockText
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.contains(":") }
            .joined()
        return Data(base64Encoded: body)
    }
}
