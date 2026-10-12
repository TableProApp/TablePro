//
//  PluginManager+Validation.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension PluginManager {
    func validateDependencies() {
        let loadedIds = Set(plugins.map(\.id))
        for plugin in plugins {
            guard plugin.bundle.isLoaded else { continue }
            guard let principalClass = plugin.bundle.principalClass as? any TableProPlugin.Type else { continue }
            let deps = principalClass.dependencies
            for dep in deps {
                if !loadedIds.contains(dep) {
                    Self.logger.warning("Plugin '\(plugin.id)' requires '\(dep)' which is not installed")
                }
            }
        }
    }

    /// `Bundle.principalClass` loads the executable too, so enabling a plugin needs this gate as
    /// well. A built-in bundle is sealed inside the app's own signature.
    func assertLoadable(_ bundle: Bundle, source: PluginSource) throws {
        try Self.validateBundleVersions(bundle)
        guard source != .builtIn else { return }
        try PluginCodeSignatureVerifier.verify(bundle: bundle)
    }

    /// Checks the signature of every discovered user plugin, off the main actor.
    ///
    /// This is not the gate. A bundle's code is loaded through `validateAndLoadBundle` when it is
    /// eager and `activateLazyBundle` when it is lazy, and both verify immediately before
    /// `PluginBundleLoader.load` whatever this pass concluded. What it adds is that the Plugins
    /// pane lists a bad bundle before the person tries to use it, which is all the check on the
    /// launch thread ever bought, at a measured 13ms per installed plugin and linear in how many
    /// there are.
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
