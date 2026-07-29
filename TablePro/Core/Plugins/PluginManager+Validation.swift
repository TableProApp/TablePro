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

    func verifyCodeSignature(bundle: Bundle) throws {
        try PluginCodeSignatureVerifier.verify(bundle: bundle)
    }
}
