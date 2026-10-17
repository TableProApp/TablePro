import Foundation
import os

extension PluginManager {
    func assertLoadable(_ bundle: Bundle, source: PluginSource) throws {
        try Self.validateBundleVersions(bundle)
        // A built-in bundle is sealed inside the app's own signature.
        guard source != .builtIn else { return }
        try PluginCodeSignatureVerifier.verify(bundle: bundle)
    }

    // Not the load gate: it lets the Plugins pane list a bad bundle before anyone uses it.
    func sweepPluginSignatures() async {
        let urls = pendingSignatureChecks
        pendingSignatureChecks.removeAll()
        guard !urls.isEmpty else { return }

        for url in urls {
            guard let failure = await Self.signatureFailure(at: url) else { continue }
            Self.logger.error(
                "Plugin '\(url.lastPathComponent, privacy: .private(mask: .hash))' failed code-sign check: \(failure.publicLogShape, privacy: .public)"
            )
            withdrawPlugin(at: url, reason: failure)
        }
    }

    @concurrent
    nonisolated private static func signatureFailure(at url: URL) async -> Error? {
        guard let bundle = Bundle(url: url) else {
            return PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }
        do {
            try PluginCodeSignatureVerifier.verify(bundle: bundle)
            return nil
        } catch {
            return error
        }
    }
}
