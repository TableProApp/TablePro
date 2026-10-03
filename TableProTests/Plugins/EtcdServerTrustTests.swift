//
//  EtcdServerTrustTests.swift
//  TableProTests
//

import Foundation
import Security
import TableProPluginKit
import Testing

@testable import TablePro

struct EtcdServerTrustTests {
    private static let caCertificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIBKDCBzgIJAItYmqrR5A5nMAoGCCqGSM49BAMCMBsxGTAXBgNVBAMMEFRhYmxl
        UHJvIFRlc3QgQ0EwIBcNMjYwOTI4MTU1MzMyWhgPMjEyNjA5MDQxNTUzMzJaMBsx
        GTAXBgNVBAMMEFRhYmxlUHJvIFRlc3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMB
        BwNCAASaYfImiB+IzxPGowAQoY7FJ+pMBUH44UT+xAYLv5daFRxN2UyT9OVoblbw
        eckn8xKUHUudi7CXcAYRCK37s4lzMAoGCCqGSM49BAMCA0kAMEYCIQCSluC20xFq
        Low0L94hZ8kUnPyvB0Lr+BaeqDo8XQD2+wIhAJvEM/BlLmzZoWm9acV24GaQ8/uy
        cC5Nd9tqoj6nWEbU
        -----END CERTIFICATE-----
        """

    private func temporaryFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("etcd-ca-\(UUID().uuidString).pem")
        try contents.write(to: url)
        return url
    }

    private func refusal(tlsMode: String, caPath: String?) -> EtcdTLSConfigurationError? {
        do {
            _ = try EtcdServerTrust.make(tlsMode: tlsMode, caCertificatePath: caPath)
            return nil
        } catch {
            return error as? EtcdTLSConfigurationError
        }
    }

    @Test("Verify CA with no CA certificate is refused, since it checks no hostname")
    func verifyCAWithoutCAIsRefused() {
        #expect(refusal(tlsMode: "VerifyCA", caPath: nil) == .verifyCANeedsCertificate)
        #expect(refusal(tlsMode: "VerifyCA", caPath: "") == .verifyCANeedsCertificate)
        #expect(refusal(tlsMode: "VerifyCA", caPath: "  ") == .verifyCANeedsCertificate)
    }

    @Test("The Verify CA refusal points at the form section where the CA Certificate field is")
    func verifyCARefusalNamesTheOptionsTab() throws {
        let message = try #require(EtcdTLSConfigurationError.verifyCANeedsCertificate.errorDescription)
        #expect(!message.contains("Advanced"))
        #expect(message.contains("etcd section of the Options tab"))
    }

    @Test("Verify Identity with no CA certificate checks the system trust store and the hostname")
    func verifyIdentityWithoutCAUsesSystemTrust() throws {
        let trust = try #require(try EtcdServerTrust.make(tlsMode: "VerifyIdentity", caCertificatePath: nil))
        #expect(trust.anchor == nil)
        #expect(trust.checksHostname)
    }

    @Test("Modes that verify nothing build no server trust")
    func nonVerifyingModesBuildNothing() throws {
        #expect(try EtcdServerTrust.make(tlsMode: "Disabled", caCertificatePath: nil) == nil)
        #expect(try EtcdServerTrust.make(tlsMode: "Required", caCertificatePath: nil) == nil)
    }

    @Test("A PEM or DER CA certificate becomes the anchor, and only Verify Identity checks the hostname")
    func readableCABecomesAnchor() throws {
        let pem = Data(Self.caCertificatePEM.utf8)
        let der = try #require(PEMCertificateDecoder.certificateDER(from: pem))
        for contents in [pem, der] {
            let file = try temporaryFile(contents)
            defer { try? FileManager.default.removeItem(at: file) }
            let verifyCA = try #require(try EtcdServerTrust.make(tlsMode: "VerifyCA", caCertificatePath: file.path))
            #expect(verifyCA.anchor != nil)
            #expect(!verifyCA.checksHostname)
            let verifyIdentity = try #require(
                try EtcdServerTrust.make(tlsMode: "VerifyIdentity", caCertificatePath: file.path)
            )
            #expect(verifyIdentity.anchor != nil)
            #expect(verifyIdentity.checksHostname)
        }
    }

    @Test("A CA path that does not load is refused rather than widened to the system roots")
    func unreadableCAIsRefused() throws {
        let missing = "/nonexistent/etcd-ca-\(UUID().uuidString).pem"
        let garbage = try temporaryFile(Data("not a certificate".utf8))
        defer { try? FileManager.default.removeItem(at: garbage) }
        for mode in ["VerifyCA", "VerifyIdentity"] {
            for path in [missing, garbage.path] {
                #expect(refusal(tlsMode: mode, caPath: path) == .unreadableCACertificate(path: path), "\(mode) \(path)")
            }
        }
    }
}
