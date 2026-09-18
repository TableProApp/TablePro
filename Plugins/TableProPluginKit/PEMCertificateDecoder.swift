//
//  PEMCertificateDecoder.swift
//  TableProPluginKit
//
//  Security framework certificate APIs take DER only. A user pointing a "Verify CA"
//  setting at a PEM file is the common case, so the DER has to be recovered first.
//

import Foundation

public enum PEMCertificateDecoder {
    private static let beginMarker = "-----BEGIN CERTIFICATE"
    private static let endMarker = "-----END CERTIFICATE"

    /// The DER bytes of the first certificate in a PEM document, or nil when the text
    /// carries no complete certificate block.
    public static func firstCertificateDER(inPEM text: String) -> Data? {
        var base64 = ""
        var insideCertificate = false
        var sawEndMarker = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix(beginMarker) {
                insideCertificate = true
                continue
            }
            if trimmed.hasPrefix(endMarker) {
                sawEndMarker = true
                break
            }
            if insideCertificate {
                base64 += trimmed
            }
        }

        guard insideCertificate, sawEndMarker, !base64.isEmpty else { return nil }
        return Data(base64Encoded: base64)
    }

    /// The DER bytes for a certificate file that may be either DER or PEM encoded. A file that
    /// announces a certificate block it cannot decode yields nil rather than its own raw bytes,
    /// so a caller cannot mistake undecodable text for a usable anchor.
    public static func certificateDER(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8), text.contains(beginMarker) else {
            return data
        }
        return firstCertificateDER(inPEM: text)
    }
}
