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

    @Test("An older iOS build's require keeps its spelling in the library file and goes to the Mac as Required")
    func legacyRequireSpelling() throws {
        let config = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: Data(#"{"mode":"require"}"#.utf8))
        #expect(config.mode == .require)
        #expect(config.isLegacyRequire)
        #expect(!config.isMacPreferred)

        let libraryEncoder = JSONEncoder()
        libraryEncoder.userInfo[.deviceLibraryFile] = true
        let stored = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: libraryEncoder.encode(config))
        #expect(stored.isLegacyRequire)

        let wire = try JSONEncoder().encode(config)
        let mac = try JSONDecoder().decode(TableProPluginKit.SSLConfiguration.self, from: wire)
        #expect(mac.mode == .required)
        #expect(!(try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: wire)).isLegacyRequire)
    }

    @Test("A Required written with the Mac's name, or set on this device, is explicit")
    func explicitRequired() throws {
        let blob = #"{"mode":"Required","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#
        let decoded = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: Data(blob.utf8))
        #expect(!decoded.isLegacyRequire)
        #expect(!TableProModels.SSLConfiguration(mode: .require).isLegacyRequire)

        var changed = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: Data(#"{"mode":"require"}"#.utf8))
        changed.mode = .verifyCa
        changed.mode = .require
        #expect(!changed.isLegacyRequire)
    }

    @Test("Only a copy an older iOS build stored takes the server's Preferred", arguments: [
        (#"{"mode":"require"}"#, true),
        (#"{"mode":"Required","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#, false),
        (#"{"mode":"Preferred","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#, true)
    ])
    func agreesWithServerPreferred(_ localJSON: String, _ agrees: Bool) throws {
        let server = TableProModels.SSLConfiguration(mode: .require, isMacPreferred: true)
        let local = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: Data(localJSON.utf8))
        #expect(local.agrees(withServer: server) == agrees)
    }

    @Test("Settling an older copy records what the server holds")
    func settleLegacyRequire() throws {
        var preferred = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: Data(#"{"mode":"require"}"#.utf8))
        preferred.settleLegacyRequire(asMacPreferred: true)
        #expect(preferred.isMacPreferred)
        #expect(!preferred.isLegacyRequire)

        var required = try JSONDecoder().decode(TableProModels.SSLConfiguration.self, from: Data(#"{"mode":"require"}"#.utf8))
        required.settleLegacyRequire(asMacPreferred: false)
        #expect(!required.isMacPreferred)
        #expect(!required.isLegacyRequire)

        var explicit = TableProModels.SSLConfiguration(mode: .require)
        explicit.settleLegacyRequire(asMacPreferred: true)
        #expect(!explicit.isMacPreferred)
    }

    @Test("A blob an older iOS build wrote is not in the Mac's form")
    func olderIOSBlobIsNotMacForm() {
        #expect(!TableProModels.SSLConfiguration.isMacWireForm(Data(#"{"mode":"require"}"#.utf8)))
        let allKeys = #"{"mode":"Preferred","caCertificatePath":"","clientCertificatePath":"","clientKeyPath":""}"#
        #expect(TableProModels.SSLConfiguration.isMacWireForm(Data(allKeys.utf8)))
    }
}
