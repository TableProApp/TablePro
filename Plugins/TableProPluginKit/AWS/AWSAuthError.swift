//
//  AWSAuthError.swift
//  TablePro
//

import Foundation

public enum AWSAuthError: Error, LocalizedError, Equatable {
    case missingAccessKey
    case credentialsFileUnreadable
    case profileIncomplete(String)
    case regionUnknown(host: String)
    case credentialProcessInvalid(String)
    case credentialProcessLaunchFailed(profile: String, underlying: String)
    case credentialProcessFailed(profile: String, status: Int, message: String)
    case credentialProcessBadOutput(String)
    case credentialProcessUnsupportedVersion(profile: String, version: Int)
    case credentialProcessUnsupportedOnPlatform(String)
    case assumeRoleMissingSource(String)
    case assumeRoleChainTooDeep(String)
    case assumeRoleFailed(role: String, message: String)
    case mfaUnsupported(String)
    case credentialSourceUnsupported(profile: String, source: String)
    case missingConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .missingAccessKey:
            return String(localized: "Access Key ID and Secret Access Key are required for AWS IAM authentication.")
        case .credentialsFileUnreadable:
            return String(localized: "Cannot read ~/.aws/credentials.")
        case .profileIncomplete(let profile):
            return String(
                format: String(localized: "Profile \"%@\" was not found, or has no access keys or credential_process, in ~/.aws/config or ~/.aws/credentials."),
                profile
            )
        case .regionUnknown(let host):
            return String(
                format: String(localized: "Could not determine an AWS region for \"%@\". Set the AWS Region field."),
                host
            )
        case .credentialProcessInvalid(let profile):
            return String(
                format: String(localized: "The credential_process command for profile \"%@\" is empty or invalid."),
                profile
            )
        case .credentialProcessLaunchFailed(let profile, let underlying):
            return String(
                format: String(localized: "Could not run the credential_process command for profile \"%@\": %@"),
                profile, underlying
            )
        case .credentialProcessFailed(let profile, let status, let message):
            let detail = message.isEmpty ? "" : "\n\(message)"
            return String(
                format: String(localized: "The credential_process command for profile \"%@\" exited with status %lld.%@"),
                profile, status, detail
            )
        case .credentialProcessBadOutput(let profile):
            return String(
                format: String(localized: "The credential_process command for profile \"%@\" did not return valid credentials JSON."),
                profile
            )
        case .credentialProcessUnsupportedVersion(let profile, let version):
            return String(
                format: String(localized: "The credential_process command for profile \"%@\" returned unsupported Version %lld (expected 1)."),
                profile, version
            )
        case .credentialProcessUnsupportedOnPlatform(let profile):
            return String(
                format: String(localized: "The credential_process command for profile \"%@\" is only supported on macOS."),
                profile
            )
        case .assumeRoleMissingSource(let profile):
            return String(
                format: String(localized: "Profile \"%@\" sets role_arn but has no source_profile or credential_source to provide base credentials."),
                profile
            )
        case .assumeRoleChainTooDeep(let profile):
            return String(
                format: String(localized: "Profile \"%@\" has a source_profile chain that is too long to resolve."),
                profile
            )
        case .assumeRoleFailed(let role, let message):
            return String(
                format: String(localized: "Could not assume role \"%@\": %@"),
                role, message
            )
        case .mfaUnsupported(let profile):
            return String(
                format: String(localized: "Profile \"%@\" requires an MFA token code, which is not supported yet. Use a profile without mfa_serial."),
                profile
            )
        case .credentialSourceUnsupported(let profile, let source):
            return String(
                format: String(localized: "Profile \"%@\" uses credential_source \"%@\", which is not supported on the desktop app."),
                profile, source
            )
        case .missingConfiguration(let message):
            return message
        }
    }
}
