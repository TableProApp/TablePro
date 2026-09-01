//
//  PluginSignatureGatePlacementTests.swift
//  TableProTests
//

import Foundation
import Testing

/// Where the plugin signature check runs is a launch-time budget decision and a security decision
/// at once, and only one of the two is visible in a diff.
///
/// `SecStaticCodeCheckValidity` hashes the whole bundle: measured at 13ms per user-installed plugin
/// on the launch thread, linear in how many are installed. Discovery and lazy registration load no
/// code, so a check there buys nothing but the Plugins pane's rejected list, which
/// `sweepPluginSignatures()` now fills off the main actor after the first frame. The two calls that
/// do load code must keep verifying, immediately before `PluginBundleLoader.load`.
@Suite("Plugin signature gate placement")
struct PluginSignatureGatePlacementTests {
    @Test("Discovery and lazy registration do not verify signatures")
    func launchPathDoesNotVerifySignatures() throws {
        for function in ["discoverPlugin", "registerLazyManifest"] {
            let body = try Self.functionBody(named: function)
            #expect(
                !body.contains("verifyCodeSignature") && !body.contains("PluginCodeSignatureVerifier"),
                """
                `\(function)` verifies a signature again. It loads no code, so the check costs the \
                launch 13ms per installed plugin and gates nothing. Leave it to \
                `sweepPluginSignatures()`.
                """
            )
        }
    }

    @Test("Every path that loads a bundle verifies its signature first")
    func loadPathsVerifySignatures() throws {
        for function in ["activateLazyBundle", "validateAndLoadBundle"] {
            let body = try Self.functionBody(named: function)
            #expect(
                body.contains("verifyCodeSignature") || body.contains("PluginCodeSignatureVerifier"),
                """
                `\(function)` loads a plugin's code without verifying its signature. This is the \
                gate; the sweep is not.
                """
            )
            #expect(body.contains("PluginBundleLoader.load"), "`\(function)` no longer loads a bundle")
        }
    }

    /// Everything from the declaration line to the first line that closes it at the declaration's
    /// own indentation, which is enough to tell one function's body from its neighbours'.
    private static func functionBody(named name: String) throws -> String {
        let lines = try String(contentsOf: try pluginManagerSource(), encoding: .utf8)
            .components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else {
            throw PlacementError.functionNotFound(name)
        }
        let indent = lines[start].prefix { $0 == " " }.count
        let closing = String(repeating: " ", count: indent) + "}"
        guard let end = lines[(start + 1)...].firstIndex(of: closing) else {
            throw PlacementError.functionNotFound(name)
        }
        return lines[start ... end].joined(separator: "\n")
    }

    private static func pluginManagerSource(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("TablePro/Core/Plugins/PluginManager.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        throw PlacementError.sourceNotFound
    }

    private enum PlacementError: Error {
        case functionNotFound(String)
        case sourceNotFound
    }
}
