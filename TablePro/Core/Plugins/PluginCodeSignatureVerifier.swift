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

    /// The app keeps `disable-library-validation` for SQLite and DuckDB extensions, so dyld checks
    /// nothing and this is the whole load decision for a plugin bundle.
    static func verify(bundle: Bundle) throws {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TABLEPRO_ALLOW_UNSIGNED_PLUGINS"] == "1" {
            logger.warning(
                "Skipping code-signature verification for \(bundle.bundleURL.lastPathComponent): TABLEPRO_ALLOW_UNSIGNED_PLUGINS=1"
            )
            return
        }
        #endif
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )

        guard createStatus == errSecSuccess, let code = staticCode else {
            throw PluginError.signatureInvalid(detail: describeOSStatus(createStatus))
        }

        let flags = SecCSFlags(rawValue: Self.validationFlags)
        let status = SecStaticCodeCheckValidity(code, flags, requirement(Self.firstPartyRequirement))
        guard status == errSecSuccess else {
            throw PluginError.signatureInvalid(detail: describeOSStatus(status))
        }
    }

    static let validationFlags = kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        | kSecCSRestrictSymlinks

    private static var firstPartyRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(resolvedSigningTeamId)\""
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement)
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
        case errSecCSUnsigned: "bundle is not signed"
        case errSecCSReqFailed: "bundle is not signed by TablePro"
        case errSecCSSignatureInvalid: "code signature is invalid"
        case errSecCSSignatureFailed, errSecCSInfoPlistFailed: "code signature has been modified or corrupted"
        case errSecCSBadResource: "a sealed resource is missing or has been modified"
        case errSecCSUnsignedNestedCode: "nested code is unsigned"
        case errSecCSInvalidSymlink: "bundle has a symbolic link that points outside it"
        default: "verification failed (OSStatus \(status))"
        }
    }
}
