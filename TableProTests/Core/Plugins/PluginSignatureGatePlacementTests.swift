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

    @Test("Every path that loads a plugin's executable goes through the gate first")
    func loadPathsVerifySignatures() throws {
        for function in ["activateLazyBundle", "validateAndLoadBundle", "setEnabled"] {
            let body = try Self.functionBody(named: function)
            #expect(
                body.contains("assertLoadable") || body.contains("PluginCodeSignatureVerifier"),
                """
                `\(function)` reaches a plugin's executable without the load gate. Both                 `PluginBundleLoader.load` and `Bundle.principalClass` load it, and discovery now                 publishes an entry before its signature has been checked, so an unverified bundle                 is reachable from here.
                """
            )
        }
    }

    @Test("Nothing outside the gated paths touches principalClass")
    func principalClassIsOnlyReachedFromGatedPaths() throws {
        /// `validateDependencies` is allowed because it reads `principalClass` only for a bundle
        /// that is already `isLoaded`, so the executable it would load is the one a gated path
        /// already loaded.
        let gated = ["setEnabled", "registerBundle", "activateLazyBundle", "validateDependencies"]
        var offenders: [String] = []
        for url in try Self.pluginSources() {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(".principalClass") {
                let owner = Self.enclosingFunction(of: index, in: lines)
                guard !gated.contains(where: { owner.contains($0) }) else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1) in \(owner)")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            `Bundle.principalClass` loads the bundle's executable, so every use of it belongs in a             function that has already called `assertLoadable`: \(offenders.sorted())
            """
        )
    }

    private static func enclosingFunction(of line: Int, in lines: [String]) -> String {
        for index in stride(from: line, through: 0, by: -1) where lines[index].contains("func ") {
            return lines[index].trimmingCharacters(in: .whitespaces)
        }
        return "<file scope>"
    }

    private static func pluginSources(file: StaticString = #filePath) throws -> [URL] {
        let root = try pluginManagerSource(file: file).deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "swift" }
    }

    /// Everything from the declaration line to the first line that closes it at the declaration's
    /// own indentation, which is enough to tell one function's body from its neighbours'.
    private static func functionBody(named name: String) throws -> String {
        for url in try pluginSources() {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else { continue }
            let indent = lines[start].prefix { $0 == " " }.count
            let closing = String(repeating: " ", count: indent) + "}"
            guard let end = lines[(start + 1)...].firstIndex(of: closing) else { continue }
            return lines[start ... end].joined(separator: "\n")
        }
        throw PlacementError.functionNotFound(name)
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
