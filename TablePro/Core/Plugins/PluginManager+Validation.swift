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
        for plugin in plugins where plugin.isEnabled {
            guard plugin.bundle.isLoaded else { continue }
            guard let principalClass = plugin.bundle.principalClass as? any TableProPlugin.Type else { continue }
            let deps = principalClass.dependencies
            for dep in deps {
                if !loadedIds.contains(dep) {
                    Self.logger.warning("Plugin '\(plugin.id)' requires '\(dep)' which is not installed")
                } else if let depEntry = plugins.first(where: { $0.id == dep }), !depEntry.isEnabled {
                    Self.logger.warning("Plugin '\(plugin.id)' requires '\(dep)' which is disabled")
                }
            }
        }
    }

    /// The one check in front of every path that can load a plugin's executable.
    ///
    /// `Bundle.principalClass` loads that executable, so a caller that only means to *enable* a
    /// plugin is a code-loading path too and needs the same gate as `activateLazyBundle`. Discovery
    /// and lazy registration publish an entry before its signature has been checked, so nothing may
    /// reach the executable on the strength of being published.
    func assertLoadable(_ bundle: Bundle, source: PluginSource) throws {
        try Self.validateBundleVersions(bundle)
        guard source != .builtIn else { return }
        try verifyCodeSignature(bundle: bundle)
    }

    func verifyCodeSignature(bundle: Bundle) throws {
        let trust = try PluginCodeSignatureVerifier.evaluate(bundle: bundle)
        guard case .developerID(let identity) = trust else { return }
        guard PluginDeveloperTrustStore.shared.isTrusted(identity) else {
            throw PluginError.developerNotTrusted(identity: identity)
        }
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
                "Plugin '\(url.lastPathComponent, privacy: .public)' failed code-sign check: \(failure.localizedDescription, privacy: .public)"
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
            let trust = try PluginCodeSignatureVerifier.evaluate(bundle: bundle)
            guard case .developerID(let identity) = trust else { return nil }
            guard PluginDeveloperTrustStore.shared.isTrusted(identity) else {
                return PluginError.developerNotTrusted(identity: identity)
            }
            return nil
        } catch {
            return error
        }
    }
}
