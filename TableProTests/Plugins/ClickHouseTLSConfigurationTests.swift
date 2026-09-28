//
//  ClickHouseTLSConfigurationTests.swift
//  TableProTests
//

import Foundation
import Security
import TableProPluginKit
import Testing

@testable import TablePro

struct ClickHouseTLSConfigurationTests {
    private func configuration(_ mode: SSLMode, caPath: String = "") -> SSLConfiguration {
        SSLConfiguration(mode: mode, caCertificatePath: caPath)
    }

    private func refusal(_ ssl: SSLConfiguration) -> String? {
        do {
            _ = try ClickHouseTLSDelegate.make(for: ssl)
            return nil
        } catch let error as ClickHouseError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    @Test("Verify CA with no CA certificate is refused before any request, since it checks no hostname")
    func verifyCAWithoutCAIsRefused() {
        #expect(refusal(configuration(.verifyCa)) == ClickHouseError.verifyCaNeedsCertificate.message)
        #expect(refusal(configuration(.verifyCa, caPath: "   ")) == ClickHouseError.verifyCaNeedsCertificate.message)
    }

    @Test("Verify Identity with no CA certificate checks the system trust store and is allowed")
    func verifyIdentityWithoutCAIsAllowed() throws {
        #expect(try ClickHouseTLSDelegate.make(for: configuration(.verifyIdentity)) == nil)
        #expect(try ClickHouseTLSDelegate.make(for: configuration(.disabled)) == nil)
        #expect(try ClickHouseTLSDelegate.make(for: configuration(.required)) != nil)
    }

    @Test("A CA path that does not load is refused in both verify modes rather than widened to the system roots")
    func unreadableCAIsRefused() throws {
        let missing = "/nonexistent/ca-\(UUID().uuidString).pem"
        let notACertificate = FileManager.default.temporaryDirectory
            .appendingPathComponent("ca-\(UUID().uuidString).pem")
        try Data("not a certificate".utf8).write(to: notACertificate)
        defer { try? FileManager.default.removeItem(at: notACertificate) }
        for mode in [SSLMode.verifyCa, .verifyIdentity] {
            for path in [missing, notACertificate.path] {
                #expect(refusal(configuration(mode, caPath: path))?.contains(path) == true, "\(mode) \(path)")
            }
        }
    }

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

    @Test("A readable PEM CA certificate builds a verifying delegate in both verify modes")
    func readableCABuildsDelegate() throws {
        let caFile = FileManager.default.temporaryDirectory.appendingPathComponent("ca-\(UUID().uuidString).pem")
        try Data(Self.caCertificatePEM.utf8).write(to: caFile)
        defer { try? FileManager.default.removeItem(at: caFile) }
        for mode in [SSLMode.verifyCa, .verifyIdentity] {
            #expect(try ClickHouseTLSDelegate.make(for: configuration(mode, caPath: caFile.path)) != nil, "\(mode)")
        }
    }

    @Test("A certificate that fails its host check is reported as a hostname mismatch, anything else as untrusted")
    func refusalKinds() {
        let hostname = CFErrorCreate(nil, NSOSStatusErrorDomain as CFString, CFIndex(errSecHostNameMismatch), nil)
        let untrusted = CFErrorCreate(nil, NSOSStatusErrorDomain as CFString, CFIndex(errSecNotTrusted), nil)
        guard case .hostnameMismatch = ClickHouseTLSDelegate.refusal(for: hostname) else {
            Issue.record("Expected a hostname mismatch")
            return
        }
        guard case .untrustedCertificate = ClickHouseTLSDelegate.refusal(for: untrusted) else {
            Issue.record("Expected an untrusted certificate")
            return
        }
    }
}
