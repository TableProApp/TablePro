//
//  PluginCodeSignatureVerifierTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct PluginCodeSignatureVerifierTests {
    private static var verifierIsBypassed: Bool {
        ProcessInfo.processInfo.environment["TABLEPRO_ALLOW_UNSIGNED_PLUGINS"] == "1"
    }

    // Calculator carries a valid Apple signature that is not TablePro's, the same shape as a
    // bundle signed with another developer's Developer ID.
    @Test("A validly signed bundle from another signer is refused")
    func refusesAnotherSigner() throws {
        guard !Self.verifierIsBypassed else { return }
        let bundle = try #require(Bundle(path: "/System/Applications/Calculator.app"))

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
}
