//
//  PluginCodeSignatureVerifier.swift
//  TablePro
//

import Foundation
import os
import Security

enum PluginCodeSignatureVerifier {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PluginCodeSignature")
    private static let fallbackSigningTeamId = "D7HJ5TFYCU"

    static let resolvedSigningTeamId: String = {
        guard let teamId = teamIdFromBundleSignature() else {
            logger.warning("Could not derive team ID from app signature; using fallback '\(fallbackSigningTeamId)'")
            return fallbackSigningTeamId
        }
        return teamId
    }()

    static func verify(bundle: Bundle) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )

        guard createStatus == errSecSuccess, let code = staticCode else {
            throw PluginError.signatureInvalid(detail: describeOSStatus(createStatus))
        }

        let requirement = createSigningRequirement()

        let checkStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        )

        guard checkStatus == errSecSuccess else {
            throw PluginError.signatureInvalid(detail: describeOSStatus(checkStatus))
        }
    }

    private static func createSigningRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        let teamId = resolvedSigningTeamId
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamId)\"" as CFString
        SecRequirementCreateWithString(requirementString, SecCSFlags(), &requirement)
        return requirement
    }

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

    private static func describeOSStatus(_ status: OSStatus) -> String {
        switch status {
        case -67_062: "bundle is not signed"
        case -67_061: "code signature is invalid"
        case -67_030: "code signature has been modified or corrupted"
        case -67_013: "signing certificate has expired"
        case -67_058: "code signature is missing required fields"
        case -67_028: "resource envelope has been modified"
        default: "verification failed (OSStatus \(status))"
        }
    }
}
