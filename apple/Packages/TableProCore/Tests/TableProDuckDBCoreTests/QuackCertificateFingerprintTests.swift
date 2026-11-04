import Foundation
import TableProDuckDBCore
import Testing

private let canonical = "34FD9DAA82DDA466FF659D56FA871BADF5324F4FA5BB6A09CD06ED349BB4AD58"
private let colons = "34:FD:9D:AA:82:DD:A4:66:FF:65:9D:56:FA:87:1B:AD:F5:32:4F:4F:A5:BB:6A:09:CD:06:ED:34:9B:B4:AD:58"

struct QuackCertificateFingerprintTests {
    @Test("Every form Quack accepts reads as its canonical 64 uppercase digits", arguments: [
        colons,
        colons.lowercased(),
        canonical,
        canonical.lowercased(),
        colons.replacingOccurrences(of: ":", with: " "),
        "sha256:" + colons,
        "SHA256:" + canonical,
        "Sha256: " + colons,
        "  \(colons)\n",
    ])
    func acceptsQuackForms(input: String) throws {
        #expect(try QuackCertificateFingerprint.normalized(input) == canonical)
    }

    @Test("Anything Quack refuses is refused before dialing", arguments: [
        "SHA256 Fingerprint=" + colons,
        "SHA-256:" + colons,
        "EB:1C:23",
        "zz",
        String(canonical.dropLast()),
        canonical + "A",
        colons.replacingOccurrences(of: ":", with: "-"),
        colons.replacingOccurrences(of: ":", with: "\t"),
        "\u{FF13}" + String(canonical.dropFirst()),
    ])
    func refusesOtherForms(input: String) {
        #expect(throws: QuackConnectError.invalidFingerprint) {
            try QuackCertificateFingerprint.normalized(input)
        }
    }

    @Test("A blank fingerprint asks for one", arguments: ["", "   ", "\n"])
    func blankIsMissing(input: String) {
        #expect(throws: QuackConnectError.missingFingerprint) {
            try QuackCertificateFingerprint.normalized(input)
        }
    }
}
