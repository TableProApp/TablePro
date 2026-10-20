import Foundation
import Testing

@testable import TableProModels
import TableProPluginKit

struct SSLConfigurationWireTests {
    @Test(
        "Each iOS mode with nil paths decodes as the Mac's SSL configuration",
        arguments: [
            (TableProModels.SSLConfiguration.SSLMode.disable, TableProPluginKit.SSLMode.disabled),
            (TableProModels.SSLConfiguration.SSLMode.require, TableProPluginKit.SSLMode.required),
            (TableProModels.SSLConfiguration.SSLMode.verifyCa, TableProPluginKit.SSLMode.verifyCa),
            (TableProModels.SSLConfiguration.SSLMode.verifyFull, TableProPluginKit.SSLMode.verifyIdentity)
        ]
    )
    func decodesAsMacConfiguration(
        _ mode: TableProModels.SSLConfiguration.SSLMode,
        _ expected: TableProPluginKit.SSLMode
    ) throws {
        let data = try JSONEncoder().encode(TableProModels.SSLConfiguration(mode: mode))
        let mac = try JSONDecoder().decode(TableProPluginKit.SSLConfiguration.self, from: data)
        #expect(mac.mode == expected)
        #expect(mac.caCertificatePath.isEmpty)
        #expect(mac.clientCertificatePath.isEmpty)
        #expect(mac.clientKeyPath.isEmpty)
        #expect(TableProModels.SSLConfiguration.isMacWireForm(data))
    }

    @Test("Nil paths round-trip to nil")
    func nilPathsRoundTrip() throws {
        let original = TableProModels.SSLConfiguration(mode: .verifyCa)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: data)
        #expect(decoded == original)
        #expect(decoded.caCertificatePath == nil)
        #expect(decoded.clientCertificatePath == nil)
        #expect(decoded.clientKeyPath == nil)
    }

    @Test("Set paths reach the Mac and round-trip")
    func setPathsRoundTrip() throws {
        let original = TableProModels.SSLConfiguration(
            mode: .verifyFull,
            caCertificatePath: "/certs/ca.pem",
            clientCertificatePath: "/certs/client.crt",
            clientKeyPath: "/certs/client.key"
        )
        let data = try JSONEncoder().encode(original)
        let mac = try JSONDecoder().decode(TableProPluginKit.SSLConfiguration.self, from: data)
        #expect(mac.caCertificatePath == "/certs/ca.pem")
        #expect(mac.clientCertificatePath == "/certs/client.crt")
        #expect(mac.clientKeyPath == "/certs/client.key")
        let decoded = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: data)
        #expect(decoded == original)
    }

    @Test("A Mac Preferred reads as require, writes back as Preferred, and a new mode replaces it")
    func macPreferredRoundTrips() throws {
        let blob = #"{"mode":"Preferred","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#
        var config = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: Data(blob.utf8))
        #expect(config.mode == .require)
        #expect(config.isMacPreferred)
        let mac = try JSONDecoder().decode(TableProPluginKit.SSLConfiguration.self, from: JSONEncoder().encode(config))
        #expect(mac.mode == .preferred)

        config.mode = .require
        #expect(config.isMacPreferred)
        config.mode = .verifyCa
        config.mode = .require
        #expect(!config.isMacPreferred)
        #expect(!TableProModels.SSLConfiguration(mode: .verifyCa, isMacPreferred: true).isMacPreferred)
    }

    @Test("A blob an older iOS build wrote is not in the Mac's form")
    func olderIOSBlobIsNotMacForm() {
        #expect(!TableProModels.SSLConfiguration.isMacWireForm(Data(#"{"mode":"require"}"#.utf8)))
        let allKeys = #"{"mode":"Preferred","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#
        #expect(TableProModels.SSLConfiguration.isMacWireForm(Data(allKeys.utf8)))
    }
}
