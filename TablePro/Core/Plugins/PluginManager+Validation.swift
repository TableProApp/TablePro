//
//  PluginManager+Validation.swift
//  TablePro
//

import Foundation
import os
import Security
import SwiftUI
import TableProPluginKit

// MARK: - Dependency Validation

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

    // MARK: - Code Signature Verification

    private static let fallbackSigningTeamId = "D7HJ5TFYCU"

    private static let resolvedSigningTeamId: String = {
        guard let teamId = teamIdFromBundleSignature() else {
            logger.warning("Could not derive team ID from app signature; using fallback '\(fallbackSigningTeamId)'")
            return fallbackSigningTeamId
        }
        return teamId
    }()

    private static func teamIdFromBundleSignature() -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else { return nil }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard infoStatus == errSecSuccess,
              let infoDict = info as? [String: Any],
              let teamId = infoDict[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamId.isEmpty
        else { return nil }
        return teamId
    }

    private func createSigningRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        let teamId = Self.resolvedSigningTeamId
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamId)\"" as CFString
        SecRequirementCreateWithString(requirementString, SecCSFlags(), &requirement)
        return requirement
    }

    func verifyCodeSignature(bundle: Bundle) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )

        guard createStatus == errSecSuccess, let code = staticCode else {
            throw PluginError.signatureInvalid(
                detail: Self.describeOSStatus(createStatus)
            )
        }

        let requirement = createSigningRequirement()

        let checkStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        )

        guard checkStatus == errSecSuccess else {
            throw PluginError.signatureInvalid(
                detail: Self.describeOSStatus(checkStatus)
            )
        }
    }

    private static func describeOSStatus(_ status: OSStatus) -> String {
        switch status {
        case -67_062: return "bundle is not signed"
        case -67_061: return "code signature is invalid"
        case -67_030: return "code signature has been modified or corrupted"
        case -67_013: return "signing certificate has expired"
        case -67_058: return "code signature is missing required fields"
        case -67_028: return "resource envelope has been modified"
        default: return "verification failed (OSStatus \(status))"
        }
    }
}
