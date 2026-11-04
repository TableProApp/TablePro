import Foundation

public enum QuackTrustBundle {
    /// Where httpfs looks for its default bundle when `ca_cert_file` is empty, in its order
    /// (`CERT_FILE_LOCATIONS`, httpfs_certificates.cpp:13-23 at 77392a7). The first that exists wins. On
    /// macOS that is the last one, which never holds a CA added to the keychain.
    public static let defaultBundleLocations = [
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
        "/etc/ssl/cert.pem"
    ]

    private static let pemCertificateMarker = Data("-----BEGIN CERTIFICATE-----".utf8)

    /// The bundle `ca_cert_file` points at for Verify Identity with a CA.
    ///
    /// `SET GLOBAL ca_cert_file` replaces httpfs's default bundle for every HTTPS read of the DuckDB
    /// instance, not only Quack's, so a bundle of the user's CA alone would stop `read_parquet('https://…')`
    /// in the editor from trusting any public server. The default bundle goes first, then the CA.
    ///
    /// httpfs reads the file as PEM only and reports a DER file as "Problem with the SSL CA cert", which
    /// names neither the field nor the fix, so the CA is checked here instead.
    public static func combined(defaultBundle: Data?, caCertificate: Data, caCertificatePath: String) throws -> Data {
        guard caCertificate.range(of: pemCertificateMarker) != nil else {
            throw QuackConnectError.caCertificateNotPEM(path: caCertificatePath)
        }
        var bundle = defaultBundle ?? Data()
        if let last = bundle.last, last != UInt8(ascii: "\n") {
            bundle.append(UInt8(ascii: "\n"))
        }
        bundle.append(caCertificate)
        return bundle
    }
}
