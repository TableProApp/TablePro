import Foundation
import Security

// The SSL policy refuses a leaf valid for more than 825 days, so these leaves are valid for 2026 only and every trust
// built from them is evaluated at `serverNameEvaluationDate`.
public extension TLSTestFixtures {
    static let serverNameCACertificate = """
    -----BEGIN CERTIFICATE-----
    MIIBlDCCATqgAwIBAgIUNqTdSG8jLZoGQ1M/zshCYpkkdPIwCgYIKoZIzj0EAwIw
    JzElMCMGA1UEAwwcVGFibGVQcm8gU2VydmVyIE5hbWUgVGVzdCBDQTAgFw0yNjAx
    MDEwMDAwMDBaGA8yMTI1MTIzMTAwMDAwMFowJzElMCMGA1UEAwwcVGFibGVQcm8g
    U2VydmVyIE5hbWUgVGVzdCBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLAy
    Wgq50aaMlaHpwSsMPFMxiCAOGkTdMOLOthaxqCyJVH9iXoJisRmtkF/+gwG3xijJ
    D4tcnfYJcClrmR9JHIyjQjBAMB0GA1UdDgQWBBQIQFU8Rfu8nIvJY9TcWxpLMoUb
    3jAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNI
    ADBFAiBSqHBjDAYDgQ/uIUcb+GLVC4d1G0DwkkBqNRJu7uqtJAIhAPLOnFUMqUWO
    OlgBqc6Cj5FI7rDPRB57jj2QA7ZFxczS
    -----END CERTIFICATE-----
    """

    // SAN DNS:db.example.com, signed by `serverNameCACertificate`.
    static let databaseServerCertificate = """
    -----BEGIN CERTIFICATE-----
    MIIB0TCCAXegAwIBAgIUcjcqzL8aL595YJDWNIM528HHadUwCgYIKoZIzj0EAwIw
    JzElMCMGA1UEAwwcVGFibGVQcm8gU2VydmVyIE5hbWUgVGVzdCBDQTAeFw0yNjAx
    MDEwMDAwMDBaFw0yNjEyMzEwMDAwMDBaMBkxFzAVBgNVBAMMDmRiLmV4YW1wbGUu
    Y29tMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE2bMClSUyWzz1yCNYvWu8Vfy4
    OHWJ6PSuf9PJ3ORhQZblCL05bniIgRNaqeiwJG7Q62iYcc58QNsvX64kmD5QsaOB
    jjCBizAJBgNVHRMEAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEF
    BQcDATAZBgNVHREEEjAQgg5kYi5leGFtcGxlLmNvbTAdBgNVHQ4EFgQU+9IRpbi+
    kOeguS+ueo9Q7wvrclMwHwYDVR0jBBgwFoAUCEBVPEX7vJyLyWPU3FsaSzKFG94w
    CgYIKoZIzj0EAwIDSAAwRQIhANWJ4WKMXJRR4hFW1g+X74EgeFVvTYFALxiVXo31
    cUBQAiBPwp07MY+ZrxI8d7m1tcn3YT18ju8E+q1OnB9bbJ3ISQ==
    -----END CERTIFICATE-----
    """

    // SAN DNS:localhost and IP:127.0.0.1, signed by `serverNameCACertificate`: what a tunnel's forward could present.
    static let loopbackServerCertificate = """
    -----BEGIN CERTIFICATE-----
    MIIBzTCCAXOgAwIBAgIUcjcqzL8aL595YJDWNIM528HHadYwCgYIKoZIzj0EAwIw
    JzElMCMGA1UEAwwcVGFibGVQcm8gU2VydmVyIE5hbWUgVGVzdCBDQTAeFw0yNjAx
    MDEwMDAwMDBaFw0yNjEyMzEwMDAwMDBaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDBZ
    MBMGByqGSM49AgEGCCqGSM49AwEHA0IABOB3dy4L4aK2TlfdBtQAdFoJyiw6R7We
    z6klksL8oph8ULvW8fx88K0tuvZDsL+Rp5XZthS+yDxbzsl6AdGUGRujgY8wgYww
    CQYDVR0TBAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEw
    GgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMB0GA1UdDgQWBBTh0Jhnn7bVXnE+
    JvWjneKd5rMEZDAfBgNVHSMEGDAWgBQIQFU8Rfu8nIvJY9TcWxpLMoUb3jAKBggq
    hkjOPQQDAgNIADBFAiAD+2b7+4s2cumUSufV0vEVmrGXWEMCGM8a54kcB7OLwQIh
    APi89Vvv8PLQ7mrzsJbXIr9V6DrR6xor4JDEuzbm3UQR
    -----END CERTIFICATE-----
    """

    static let serverNameEvaluationDate = Date(timeIntervalSince1970: 1_780_272_000)

    // What URLSession hands a delegate after dialing `dialedHost`: the leaf under an SSL policy for that host.
    static func serverTrust(leaf pem: String, dialedHost: String = "127.0.0.1") -> SecTrust? {
        guard let leaf = SecCertificateCreateWithData(nil, der(pem) as CFData) else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, dialedHost as CFString), &trust) == errSecSuccess,
              let trust,
              SecTrustSetVerifyDate(trust, serverNameEvaluationDate as CFDate) == errSecSuccess
        else { return nil }
        return trust
    }
}
