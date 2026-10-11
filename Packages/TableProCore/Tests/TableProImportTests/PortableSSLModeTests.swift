import Foundation
import TableProImport
import Testing

@Suite("SSL modes read the same on the Mac and iPhone")
struct PortableSSLModeTests {
    @Test("Every canonical spelling reads as itself", arguments: PortableSSLMode.allCases)
    func canonicalSpellingReadsAsItself(_ mode: PortableSSLMode) {
        #expect(PortableSSLMode(carrying: mode.rawValue) == mode)
    }

    @Test("The iOS spellings read as the matching mode")
    func iosSpellingsRead() {
        let cases: [(raw: String, expected: PortableSSLMode)] = [
            ("disable", .disabled),
            ("prefer", .preferred),
            ("require", .required),
            ("verifyCa", .verifyCA),
            ("verifyFull", .verifyIdentity)
        ]
        for entry in cases {
            #expect(PortableSSLMode(carrying: entry.raw) == entry.expected, "\(entry.raw)")
        }
    }

    @Test("Case, spaces, underscores and hyphens are ignored")
    func spellingNoiseIsIgnored() {
        let cases: [(raw: String, expected: PortableSSLMode)] = [
            ("REQUIRED", .required),
            (" Required ", .required),
            ("VERIFY_CA", .verifyCA),
            ("verify-full", .verifyIdentity),
            ("verify identity", .verifyIdentity),
            ("Dis abled", .disabled)
        ]
        for entry in cases {
            #expect(PortableSSLMode(carrying: entry.raw) == entry.expected, "\(entry.raw)")
        }
    }

    @Test("An unknown mode is not guessed", arguments: ["", "allow", "sometimes", "verify"])
    func unknownModeIsNil(_ raw: String) {
        #expect(PortableSSLMode(carrying: raw) == nil)
    }

    @Test("The config stores the canonical spelling of a known mode")
    func configCanonicalizesKnownMode() {
        let config = ExportableSSLConfig(mode: "require")

        #expect(config.mode == "Required")
        #expect(config.portableMode == .required)
    }

    @Test("The config keeps an unknown mode as written")
    func configKeepsUnknownMode() {
        let config = ExportableSSLConfig(mode: "allow")

        #expect(config.mode == "allow")
        #expect(config.portableMode == nil)
    }

    @Test("Decoding canonicalizes an iOS spelling and keeps the paths")
    func decodingCanonicalizes() throws {
        let json = Data(#"{"mode":"verifyFull","caCertificatePath":"~/ca.pem"}"#.utf8)

        let config = try JSONDecoder().decode(ExportableSSLConfig.self, from: json)

        #expect(config.mode == "Verify Identity")
        #expect(config.caCertificatePath == "~/ca.pem")
        #expect(config.clientCertificatePath == nil)
    }

    @Test("Decoding keeps an unknown mode rather than failing")
    func decodingKeepsUnknownMode() throws {
        let json = Data(#"{"mode":"allow"}"#.utf8)

        let config = try JSONDecoder().decode(ExportableSSLConfig.self, from: json)

        #expect(config.mode == "allow")
    }
}
