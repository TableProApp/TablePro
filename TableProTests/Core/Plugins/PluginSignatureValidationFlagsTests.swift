//
//  PluginSignatureValidationFlagsTests.swift
//  TableProTests
//

import Foundation
import Security
@testable import TablePro
import Testing

/// The app carries `com.apple.security.cs.disable-library-validation` because it loads plugins
/// signed by other teams, so dyld validates nothing and `SecStaticCodeCheckValidity` is the entire
/// load decision. Two of its flags are what make that decision cover a real bundle: nested code,
/// and the strict resource envelope.
@Suite("Plugin signature validation flags")
struct PluginSignatureValidationFlagsTests {
    @Test("Nested Mach-O inside a plugin bundle is verified")
    func flagsCheckNestedCode() {
        #expect(PluginCodeSignatureVerifier.validationFlags & kSecCSCheckNestedCode != 0)
    }

    @Test("Resource envelope anomalies are rejected rather than permitted")
    func flagsValidateStrictly() {
        #expect(PluginCodeSignatureVerifier.validationFlags & kSecCSStrictValidate != 0)
    }

    @Test("Every architecture is still checked")
    func flagsCheckAllArchitectures() {
        #expect(PluginCodeSignatureVerifier.validationFlags & kSecCSCheckAllArchitectures != 0)
    }

    @Test("No validity check is made with a weaker flag set")
    func everyValidityCheckUsesTheSharedFlags() throws {
        let source = try verifierSource()
        let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: .newlines)

        var checkedCalls = 0
        for (index, line) in lines.enumerated() where line.contains("SecStaticCodeCheckValidity(") {
            checkedCalls += 1
            #expect(
                line.contains("flags"),
                """
                \(source.lastPathComponent):\(index + 1) checks validity with its own flag set. \
                Every call must pass the shared `flags`, or that load path silently drops the \
                nested-code and strict-validation checks.
                """
            )
        }
        #expect(checkedCalls > 0)

        let flagBindings = lines.filter { $0.contains("let flags = SecCSFlags(") }
        #expect(flagBindings.count == 1)
        #expect(flagBindings.first?.contains("Self.validationFlags") == true)
    }

    private func verifierSource(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("TablePro/Core/Plugins/PluginCodeSignatureVerifier.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        throw FlagsTestError.sourceNotFound
    }

    private enum FlagsTestError: Error {
        case sourceNotFound
    }
}
