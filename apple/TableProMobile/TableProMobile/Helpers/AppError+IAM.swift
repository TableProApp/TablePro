import Foundation
import TableProGoogleCloud
import TableProPluginKit

// Sign-in errors are read by their case: their messages embed the user's host, profile or start
// URL, which the substring rules would file as an SSH or password failure.
nonisolated extension ErrorClassifier {
    static func signInFailure(_ error: Error, context: ErrorContext) -> AppError? {
        // Test Connection's result has no Retry button, so it gets no recovery that names one.
        let retries = context.operation != "testConnection"
        switch error {
        case let iamError as IAMSignInError:
            return iamFailure(iamError, retries: retries)
        case let awsError as AWSAuthError:
            return awsFailure(awsError)
        case let ssoError as AWSSSOError:
            return ssoFailure(ssoError, retries: retries)
        case let loginError as AWSSSOLoginError:
            return ssoLoginFailure(loginError, retries: retries)
        case let googleError as GoogleAuthError:
            return googleFailure(googleError)
        case let entraError as EntraOAuthError:
            return entraFailure(entraError, retries: retries)
        default:
            return nil
        }
    }

    private static func iamFailure(_ error: IAMSignInError, retries: Bool) -> AppError {
        switch error {
        case .accessKeyMissing:
            return accessKeyNeeded(error)
        case .profileNeedsDeviceKey:
            return awsProfileOnMac(error, title: String(localized: "AWS Profile Is on the Mac"))
        case .applicationDefaultNeedsDeviceKey:
            return applicationDefaultOnMac(error, message: error.localizedDescription)
        case .serviceAccountKeyMissing:
            return failure(
                error,
                .config,
                title: String(localized: "Service Account Key Needed"),
                recovery: String(localized: "Paste the service account JSON key in this connection's Authentication section."),
                opensEditor: true
            )
        case .serviceAccountKeyIsMacFile:
            return failure(
                error,
                .config,
                title: String(localized: "Service Account Key Is on the Mac"),
                recovery: String(localized: "Paste the JSON key on this device in the connection's Authentication section."),
                opensEditor: true
            )
        case .ssoNotSetUp:
            return ssoNotSetUp(error)
        case .ssoSignInRequired:
            return ssoSignInRequired(error, message: error.localizedDescription, retries: retries)
        case .encryptionNotEstablished:
            return failure(
                error,
                .config,
                title: String(localized: "Encryption Not Established"),
                recovery: String(localized: "Check that the server accepts TLS connections.")
            )
        }
    }

    private static func awsFailure(_ error: AWSAuthError) -> AppError {
        switch error {
        case .missingAccessKey:
            return accessKeyNeeded(error)
        case .regionUnknown:
            return failure(
                error,
                .config,
                title: String(localized: "AWS Region Needed"),
                recovery: String(localized: "Set the AWS Region in this connection's Authentication section."),
                opensEditor: true
            )
        case .rdsEndpointUnresolved:
            return failure(
                error,
                .config,
                title: String(localized: "RDS Endpoint Needed"),
                recovery: String(localized: "Enter the RDS Endpoint in this connection's Authentication section."),
                opensEditor: true
            )
        case .rdsEndpointInvalid:
            return failure(
                error,
                .config,
                title: String(localized: "RDS Endpoint Invalid"),
                recovery: String(localized: "Enter the RDS Endpoint in this connection's Authentication section."),
                opensEditor: true
            )
        case .missingConfiguration:
            return failure(
                error,
                .config,
                title: String(localized: "AWS IAM Setup Incomplete"),
                recovery: String(localized: "Check this connection's Authentication section."),
                opensEditor: true
            )
        case .assumeRoleFailed:
            return failure(
                error,
                .auth,
                title: String(localized: "AWS Sign-In Failed"),
                recovery: String(localized: "Check that these AWS credentials are allowed to assume the role.")
            )
        case .credentialsFileUnreadable, .profileIncomplete, .credentialProcessInvalid,
             .credentialProcessLaunchFailed, .credentialProcessFailed, .credentialProcessBadOutput,
             .credentialProcessUnsupportedVersion, .credentialProcessUnsupportedOnPlatform,
             .assumeRoleMissingSource, .assumeRoleChainTooDeep, .mfaUnsupported,
             .webIdentityUnsupported, .credentialSourceUnsupported:
            return awsProfileOnMac(error, title: String(localized: "AWS Profile Unavailable"))
        }
    }

    // The PluginKit messages for an expired session say to run the AWS CLI, which a phone does not have.
    private static func ssoFailure(_ error: AWSSSOError, retries: Bool) -> AppError {
        switch error {
        case .configReadFailed, .profileNotFound, .profileMissingFields, .sessionNotFound,
             .sessionMissingFields, .profileMissingUrlOrRegion:
            return ssoNotSetUp(error)
        case .tokenCacheNotFound, .tokenCacheMalformed, .tokenExpired, .sessionUnauthorized:
            return ssoSignInRequired(
                error,
                message: String(localized: "The IAM Identity Center sign-in on this device has expired."),
                retries: retries
            )
        case .credentialsAlreadyExpired:
            return failure(
                error,
                .system,
                title: String(localized: "AWS SSO Sign-In Failed"),
                message: String(localized: "IAM Identity Center returned role credentials that had already expired."),
                recovery: String(localized: "Check the date and time on this device.")
            )
        case .roleNotAccessible:
            return failure(
                error,
                .permission,
                title: String(localized: "Role Not Accessible"),
                recovery: String(localized: "Pick another account or role in this connection's Authentication section."),
                opensEditor: true
            )
        case .networkFailure:
            return unreachable(error, title: String(localized: "Can't Reach IAM Identity Center"))
        case .urlBuildFailed, .invalidResponse, .portalError, .responseDecodeFailed:
            return failure(
                error,
                .system,
                title: String(localized: "AWS SSO Sign-In Failed"),
                recovery: String(localized: "Try again in a moment.")
            )
        }
    }

    private static func ssoLoginFailure(_ error: AWSSSOLoginError, retries: Bool) -> AppError {
        switch error {
        case .network:
            return unreachable(error, title: String(localized: "Can't Reach IAM Identity Center"))
        case .unexpectedResponse, .serverError:
            return failure(
                error,
                .config,
                title: String(localized: "AWS SSO Sign-In Failed"),
                recovery: String(localized: "Check the start URL and SSO Region in this connection's Authentication section."),
                opensEditor: true
            )
        case .authorizationTimedOut:
            return signInTimedOut(error, retries: retries)
        case .accessDenied:
            return signInDenied(error, retries: retries)
        }
    }

    private static func googleFailure(_ error: GoogleAuthError) -> AppError {
        let message = GoogleAuthErrorMessages.message(for: error)
        switch error {
        case .credentialNotJSON, .credentialIsPEM, .credentialFileUnreadable, .credentialMissingField,
             .malformedPrivateKey, .unsupportedCredentialType, .untrustedEndpoint:
            return failure(
                error,
                .config,
                title: String(localized: "Service Account Key Invalid"),
                message: message,
                recovery: String(localized: "Paste the whole service account JSON key in this connection's Authentication section."),
                opensEditor: true
            )
        case .applicationDefaultCredentialsNotFound:
            return applicationDefaultOnMac(error, message: message)
        case .tokenRequestRejected:
            return failure(
                error,
                .auth,
                title: String(localized: "Google Sign-In Failed"),
                message: message,
                recovery: String(localized: "Check that the service account key is still active, then paste it again in this connection's Authentication section."),
                opensEditor: true
            )
        case .transport:
            return unreachable(error, title: String(localized: "Can't Reach Google"), message: message)
        case .invalidTokenResponse, .signingFailed:
            return failure(
                error,
                .system,
                title: String(localized: "Google Sign-In Failed"),
                message: message,
                recovery: String(localized: "Try again in a moment.")
            )
        case .signInRequired, .oauthTimedOut, .oauthDenied, .oauthStateMismatch, .oauthCancelled:
            return failure(
                error,
                .auth,
                title: String(localized: "Google Sign-In Failed"),
                message: message,
                recovery: nil
            )
        }
    }

    private static func entraFailure(_ error: EntraOAuthError, retries: Bool) -> AppError {
        switch error {
        case .notConfigured:
            return failure(
                error,
                .config,
                title: String(localized: "Microsoft Entra ID Not Set Up"),
                recovery: String(localized: "Set the application (client) ID for this connection on the Mac.")
            )
        case .signInRequired, .interactionRequired, .refreshRejected:
            return failure(
                error,
                .auth,
                title: String(localized: "Microsoft Entra ID Sign-In Required"),
                recovery: retries ? String(localized: "Tap Retry to sign in again.") : nil
            )
        case .network:
            return unreachable(error, title: String(localized: "Can't Reach Microsoft Entra ID"))
        case .unexpectedResponse, .serverError:
            return failure(
                error,
                .system,
                title: String(localized: "Microsoft Entra ID Sign-In Failed"),
                recovery: String(localized: "Try again in a moment.")
            )
        case .authorizationTimedOut:
            return signInTimedOut(error, retries: retries)
        case .accessDenied:
            return signInDenied(error, retries: retries)
        }
    }

    private static func accessKeyNeeded(_ error: Error) -> AppError {
        failure(
            error,
            .config,
            title: String(localized: "AWS Access Key Needed"),
            recovery: String(
                localized: "Enter the access key in this connection's Authentication section, or turn on Sync Passwords on the Mac and save the connection there again."
            ),
            opensEditor: true
        )
    }

    private static func awsProfileOnMac(_ error: Error, title: String) -> AppError {
        failure(
            error,
            .config,
            title: title,
            recovery: String(
                localized: "Add an access key for this device in the connection's Authentication section. The connection on the Mac does not change."
            ),
            opensEditor: true
        )
    }

    private static func applicationDefaultOnMac(_ error: Error, message: String) -> AppError {
        failure(
            error,
            .config,
            title: String(localized: "Google Sign-In Is on the Mac"),
            message: message,
            recovery: String(
                localized: "Add a service account key for this device in the connection's Authentication section. The connection on the Mac does not change."
            ),
            opensEditor: true
        )
    }

    private static func ssoNotSetUp(_ error: Error) -> AppError {
        failure(
            error,
            .config,
            title: String(localized: "IAM Identity Center Not Set Up"),
            recovery: String(localized: "Enter the start URL and SSO Region in this connection's Authentication section, then sign in."),
            opensEditor: true
        )
    }

    private static func ssoSignInRequired(_ error: Error, message: String, retries: Bool) -> AppError {
        failure(
            error,
            .auth,
            title: String(localized: "AWS SSO Sign-In Required"),
            message: message,
            recovery: retries ? String(localized: "Tap Retry to sign in to IAM Identity Center.") : nil
        )
    }

    private static func signInTimedOut(_ error: Error, retries: Bool) -> AppError {
        failure(
            error,
            .auth,
            title: String(localized: "Sign-In Timed Out"),
            recovery: retries
                ? String(localized: "Tap Retry, then approve the sign-in in the browser before the code expires.")
                : nil
        )
    }

    private static func signInDenied(_ error: Error, retries: Bool) -> AppError {
        failure(
            error,
            .auth,
            title: String(localized: "Sign-In Denied"),
            recovery: retries ? String(localized: "Tap Retry to sign in again.") : nil
        )
    }

    private static func unreachable(_ error: Error, title: String, message: String? = nil) -> AppError {
        failure(
            error,
            .network,
            title: title,
            message: message,
            recovery: String(localized: "Check your network connection and try again.")
        )
    }

    private static func failure(
        _ error: Error,
        _ category: AppErrorCategory,
        title: String,
        message: String? = nil,
        recovery: String?,
        opensEditor: Bool = false
    ) -> AppError {
        AppError(
            category: category,
            title: title,
            message: message ?? error.localizedDescription,
            recovery: recovery,
            underlying: error,
            opensEditor: opensEditor
        )
    }
}
