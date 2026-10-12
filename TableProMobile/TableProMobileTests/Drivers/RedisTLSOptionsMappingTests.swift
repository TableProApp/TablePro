import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct RedisTLSOptionsMappingTests {
    @Test("Verify Full checks the certificate against the host being dialed")
    func verifyFullChecksHostname() {
        let options = RedisTLSOptions(ssl: DriverSSLConfiguration(mode: .verifyFull), host: "redis.example.com")
        #expect(options.verifiesCertificate)
        #expect(options.checksHostname)
        #expect(options.expectedHost == "redis.example.com")
        #expect(options.serverName == "redis.example.com")
    }

    @Test("Verify CA checks the chain but not the hostname")
    func verifyCaSkipsHostname() {
        let options = RedisTLSOptions(ssl: DriverSSLConfiguration(mode: .verifyCa), host: "redis.example.com")
        #expect(options.verifiesCertificate)
        #expect(options.checksHostname == false)
    }

    @Test("Require encrypts without verifying the certificate or the hostname")
    func requireVerifiesNothing() {
        let options = RedisTLSOptions(ssl: DriverSSLConfiguration(mode: .require), host: "redis.example.com")
        #expect(options.verifiesCertificate == false)
        #expect(options.checksHostname == false)
    }
}
