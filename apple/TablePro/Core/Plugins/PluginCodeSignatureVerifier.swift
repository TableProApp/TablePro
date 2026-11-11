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

    static let validationFlags = kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        | kSecCSRestrictSymlinks

    // The app keeps `disable-library-validation` for SQLite and DuckDB extensions, so dyld checks
    // nothing and this is the whole load decision for a plugin bundle.
    static func verify(bundle: Bundle) throws {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TABLEPRO_ALLOW_UNSIGNED_PLUGINS"] == "1" {
            logger.warning(
                "Skipping code-signature verification for \(bundle.bundleURL.lastPathComponent): TABLEPRO_ALLOW_UNSIGNED_PLUGINS=1"
            )
            return
        }
        #endif
        try verify(bundle: bundle, signingTeam: resolvedSigningTeamId)
    }

    static func verify(bundle: Bundle, signingTeam: String) throws {
        let requirement = try firstPartyRequirement(signingTeam: signingTeam)

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw PluginError.signatureInvalid(detail: describeOSStatus(createStatus))
        }

        let flags = SecCSFlags(rawValue: validationFlags)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw PluginError.signatureInvalid(detail: describeOSStatus(status))
        }
    }

    static func firstPartyRequirement(signingTeam team: String) throws -> SecRequirement {
        // The team goes into the requirement text, where a quote could append an `or` clause.
        guard isTeamIdentifier(team) else {
            throw PluginError.signatureInvalid(detail: "TablePro's signing Team ID is not valid")
        }
        return try compiledRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
    }

    static func compiledRequirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement)
        // A nil requirement makes SecStaticCodeCheckValidity accept any valid signature.
        guard status == errSecSuccess, let requirement else {
            throw PluginError.signatureInvalid(
                detail: "TablePro's signing requirement could not be built (OSStatus \(status))"
            )
        }
        return requirement
    }

    private static func isTeamIdentifier(_ team: String) -> Bool {
        team.unicodeScalars.count == 10 && team.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
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
