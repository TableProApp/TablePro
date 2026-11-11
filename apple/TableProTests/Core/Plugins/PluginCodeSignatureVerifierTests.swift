import Foundation
@testable import TablePro
import Testing

struct PluginCodeSignatureVerifierTests {
    private static var verifierIsBypassed: Bool {
        ProcessInfo.processInfo.environment["TABLEPRO_ALLOW_UNSIGNED_PLUGINS"] == "1"
    }

    // Calculator carries a valid Apple signature that is not TablePro's, the same shape as a
    // bundle signed with another developer's Developer ID.
    private static func calculator() throws -> Bundle {
        try #require(Bundle(path: "/System/Applications/Calculator.app"))
    }

    @Test("A validly signed bundle from another signer is refused")
    func refusesAnotherSigner() throws {
        guard !Self.verifierIsBypassed else { return }
        let bundle = try Self.calculator()

        let error = #expect(throws: PluginError.self) {
            try PluginCodeSignatureVerifier.verify(bundle: bundle)
        }
        guard case .signatureInvalid(let detail) = error else {
            Issue.record("Expected signatureInvalid, got \(String(describing: error))")
            return
        }
        #expect(detail == "bundle is not signed by TablePro")
    }

    @Test("An unsigned bundle is refused")
    func refusesUnsignedBundle() throws {
        guard !Self.verifierIsBypassed else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifierTests-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Unsigned.tableplugin/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.unsigned", "CFBundleName": "Unsigned"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: contents.deletingLastPathComponent()))

        let error = #expect(throws: PluginError.self) {
            try PluginCodeSignatureVerifier.verify(bundle: bundle)
        }
        guard case .signatureInvalid = error else {
            Issue.record("Expected signatureInvalid, got \(String(describing: error))")
            return
        }
    }

    @Test("The app's own Team ID builds a signing requirement")
    func resolvedTeamBuildsRequirement() throws {
        _ = try PluginCodeSignatureVerifier.firstPartyRequirement(
            signingTeam: PluginCodeSignatureVerifier.resolvedSigningTeamId
        )
    }

    // A lone quote used to leave no requirement, and the `or anchor apple` team one every Apple-signed bundle meets.
    @Test(
        "A validly signed bundle is refused when the Team ID would break TablePro's requirement",
        arguments: [
            "\"",
            "ABCDEFGHIJ\" or anchor apple or certificate leaf[subject.OU] = \"X"
        ]
    )
    func refusesWhenTeamBreaksRequirement(team: String) throws {
        let bundle = try Self.calculator()

        let error = #expect(throws: PluginError.self) {
            try PluginCodeSignatureVerifier.verify(bundle: bundle, signingTeam: team)
        }
        guard case .signatureInvalid(let detail) = error else {
            Issue.record("Expected signatureInvalid, got \(String(describing: error))")
            return
        }
        #expect(detail == "TablePro's signing Team ID is not valid")
    }

    @Test(
        "A Team ID that is not ten capital letters or digits builds no requirement",
        arguments: ["", "d7hj5tfycu", "D7HJ5TFYC", "D7HJ5TFYCU1", "D7HJ5-FYCU"]
    )
    func refusesMalformedTeam(team: String) {
        let error = #expect(throws: PluginError.self) {
            _ = try PluginCodeSignatureVerifier.firstPartyRequirement(signingTeam: team)
        }
        guard case .signatureInvalid = error else {
            Issue.record("Expected signatureInvalid, got \(String(describing: error))")
            return
        }
    }

    @Test("Requirement text that does not compile is an error, never an empty requirement")
    func uncompilableRequirementThrows() {
        let error = #expect(throws: PluginError.self) {
            _ = try PluginCodeSignatureVerifier.compiledRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\"\""
            )
        }
        guard case .signatureInvalid(let detail) = error else {
            Issue.record("Expected signatureInvalid, got \(String(describing: error))")
            return
        }
        #expect(detail.hasPrefix("TablePro's signing requirement could not be built"))
    }
}
