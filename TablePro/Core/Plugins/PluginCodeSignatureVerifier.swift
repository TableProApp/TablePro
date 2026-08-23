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
        _ = try evaluate(bundle: bundle)
    }

    /// Classifies a bundle's signature. Throws when the bundle is unsigned, ad-hoc signed, tampered
    /// with, or signed by a certificate that is neither TablePro's own nor a Developer ID.
    ///
    /// `SecStaticCodeCheckValidity` verifies the seal and matches the certificate chain against the
    /// requirement it is given. It does **not** establish that the bundle was notarized, and neither
    /// does anything else reachable from in-process API: `SecRequirementCreateWithString("notarized")`
    /// answers `errSecCSReqFailed` for a bundle that was never notarized and for one whose ticket was
    /// revoked alike, and `SecAssessmentTicketLookup` is not in the public SDK. So what a passing
    /// Developer ID bundle proves is that Apple issued that certificate and the bundle has not been
    /// altered since it was signed, not that Apple has scanned it.
    ///
    /// The gate that carries the weight is therefore the user's own decision: a Developer ID bundle
    /// reaches `PluginDeveloperTrustStore` and installs only once the user trusts that team by name.
    /// Do not narrow that prompt on the strength of a notarization claim this code cannot make.
    static func evaluate(bundle: Bundle) throws -> PluginSignatureTrust {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TABLEPRO_ALLOW_UNSIGNED_PLUGINS"] == "1" {
            logger.warning(
                "Skipping code-signature verification for \(bundle.bundleURL.lastPathComponent): TABLEPRO_ALLOW_UNSIGNED_PLUGINS=1"
            )
            return .firstParty
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

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)

        if SecStaticCodeCheckValidity(code, flags, requirement(Self.firstPartyRequirement)) == errSecSuccess {
            return .firstParty
        }

        let developerIDStatus = SecStaticCodeCheckValidity(code, flags, requirement(Self.developerIDRequirement))
        guard developerIDStatus == errSecSuccess else {
            throw PluginError.signatureInvalid(detail: describeOSStatus(developerIDStatus))
        }

        guard let identity = developerIdentity(of: code) else {
            throw PluginError.signatureInvalid(detail: "signature carries no team identifier")
        }
        return .developerID(identity)
    }

    private static var firstPartyRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(resolvedSigningTeamId)\""
    }

    /// `1.2.840.113635.100.6.1.13` is Apple's Developer ID Application marker OID. Verified against a
    /// Developer ID signed app with `codesign -R`.
    private static let developerIDRequirement =
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    private static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement)
        return requirement
    }

    private static func developerIdentity(of code: SecStaticCode) -> PluginDeveloperIdentity? {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess,
              let infoDict = info as? [String: Any],
              let teamID = infoDict[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty
        else { return nil }

        let name = signerCommonName(from: infoDict) ?? teamID
        return PluginDeveloperIdentity(teamID: teamID, name: name)
    }

    private static func signerCommonName(from info: [String: Any]) -> String? {
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess else { return nil }
        return commonName as String?
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
