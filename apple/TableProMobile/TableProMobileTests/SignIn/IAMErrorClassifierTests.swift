import Foundation
import TableProGoogleCloud
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct IAMErrorClassifierTests {
    private func classify(_ error: Error, operation: String = "connect", signsInWithIAM: Bool = false) -> AppError {
        ErrorClassifier.classify(
            error,
            context: ErrorContext(
                operation: operation,
                databaseType: .postgresql,
                host: "ssh-tunnel.example.com",
                sshEnabled: true,
                signsInWithIAM: signsInWithIAM
            )
        )
    }

    @Test("A missing access key says which key and opens the connection, not a password check")
    func accessKeyMissing() {
        let error = classify(IAMSignInError.accessKeyMissing)

        #expect(error.category == .config)
        #expect(error.title == String(localized: "AWS Access Key Needed"))
        #expect(error.message == IAMSignInError.accessKeyMissing.localizedDescription)
        #expect(error.opensEditor)
    }

    @Test("The PluginKit missing-key error reads as the same problem, though its message says authentication")
    func pluginKitMissingAccessKey() {
        let error = classify(AWSAuthError.missingAccessKey)

        #expect(error.title == String(localized: "AWS Access Key Needed"))
        #expect(error.category == .config)
        #expect(error.opensEditor)
    }

    @Test("A Profile connection names its profile and asks for a key on this device")
    func profileNeedsDeviceKey() {
        let error = classify(IAMSignInError.profileNeedsDeviceKey(profile: "analytics"))

        #expect(error.category == .config)
        #expect(error.title == String(localized: "AWS Profile Is on the Mac"))
        #expect(error.message.contains("analytics"))
        #expect(error.opensEditor)
    }

    @Test("Application Default and a Mac key path each point at the key this device needs")
    func googleKeysOnTheMac() {
        let applicationDefault = classify(IAMSignInError.applicationDefaultNeedsDeviceKey)
        let macFile = classify(IAMSignInError.serviceAccountKeyIsMacFile)
        let missing = classify(IAMSignInError.serviceAccountKeyMissing)

        #expect(applicationDefault.title == String(localized: "Google Sign-In Is on the Mac"))
        #expect(macFile.title == String(localized: "Service Account Key Is on the Mac"))
        #expect(missing.title == String(localized: "Service Account Key Needed"))
        #expect([applicationDefault, macFile, missing].allSatisfy { $0.opensEditor })
    }

    @Test("A host whose name says tunnel is still an AWS setting, not an SSH failure")
    func hostWordsAreNotRead() {
        let error = classify(AWSAuthError.regionUnknown(host: "ssh-tunnel.example.com"))

        #expect(error.category == .config)
        #expect(error.title == String(localized: "AWS Region Needed"))
        #expect(error.opensEditor)
    }

    @Test("IAM Identity Center not set up opens the connection; an expired sign-in asks for Retry")
    func identityCenterStates() {
        let notSetUp = classify(IAMSignInError.ssoNotSetUp)
        let expired = classify(IAMSignInError.ssoSignInRequired)

        #expect(notSetUp.title == String(localized: "IAM Identity Center Not Set Up"))
        #expect(notSetUp.opensEditor)
        #expect(expired.category == .auth)
        #expect(expired.title == String(localized: "AWS SSO Sign-In Required"))
        #expect(expired.recovery == String(localized: "Tap Retry to sign in to IAM Identity Center."))
        #expect(!expired.opensEditor)
    }

    @Test("Test Connection's result never points at a Retry button it does not have")
    func testConnectionHasNoRetry() {
        let signInErrors: [Error] = [
            IAMSignInError.ssoSignInRequired,
            AWSSSOError.sessionUnauthorized(profile: "default"),
            AWSSSOLoginError.accessDenied,
            AWSSSOLoginError.authorizationTimedOut,
            EntraOAuthError.signInRequired,
            EntraOAuthError.accessDenied,
            EntraOAuthError.authorizationTimedOut
        ]

        for error in signInErrors {
            #expect(classify(error).recovery?.hasPrefix("Tap Retry") == true)
            #expect(classify(error, operation: "testConnection").recovery == nil)
        }
    }

    @Test("An expired portal session never tells a phone to run the AWS CLI")
    func portalSessionExpired() {
        let error = classify(AWSSSOError.sessionUnauthorized(profile: "default"))

        #expect(error.title == String(localized: "AWS SSO Sign-In Required"))
        #expect(!error.message.contains("aws sso login"))
    }

    @Test("A denied or timed-out browser sign-in says so instead of asking for a password")
    func browserSignInOutcomes() {
        let denied = classify(AWSSSOLoginError.accessDenied)
        let timedOut = classify(AWSSSOLoginError.authorizationTimedOut)
        let entraDenied = classify(EntraOAuthError.accessDenied)
        let entraTimedOut = classify(EntraOAuthError.authorizationTimedOut)

        #expect(denied.title == String(localized: "Sign-In Denied"))
        #expect(entraDenied.title == String(localized: "Sign-In Denied"))
        #expect(timedOut.title == String(localized: "Sign-In Timed Out"))
        #expect(entraTimedOut.title == String(localized: "Sign-In Timed Out"))
        #expect(denied.message == AWSSSOLoginError.accessDenied.localizedDescription)
        #expect(entraTimedOut.message == EntraOAuthError.authorizationTimedOut.localizedDescription)
    }

    @Test("A Google key error shows the Google message, which the error itself does not carry")
    func googleMessages() {
        let pem = classify(GoogleAuthError.credentialIsPEM)
        let offline = classify(GoogleAuthError.transport("offline"))

        #expect(pem.title == String(localized: "Service Account Key Invalid"))
        #expect(pem.message == GoogleAuthErrorMessages.message(for: .credentialIsPEM))
        #expect(pem.opensEditor)
        #expect(offline.category == .network)
        #expect(offline.message == GoogleAuthErrorMessages.message(for: .transport("offline")))
    }

    @Test("A session that came up without TLS is not something the connection form can fix")
    func encryptionNotEstablished() {
        let error = classify(IAMSignInError.encryptionNotEstablished)

        #expect(error.title == String(localized: "Encryption Not Established"))
        #expect(!error.opensEditor)
    }

    @Test("A token the server refuses is not blamed on a password the connection does not have")
    func serverRefusesTheToken() {
        let refused = NSError(
            domain: "PostgreSQL",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "FATAL: PAM authentication failed for user \"iam_user\""]
        )

        let iam = classify(refused, signsInWithIAM: true)
        let password = classify(refused, signsInWithIAM: false)

        #expect(iam.category == .auth)
        #expect(iam.recovery == String(
            localized: "This connection signs in with IAM, not a password. Check that the database user is set up for IAM sign-in."
        ))
        #expect(password.recovery != iam.recovery)
        #expect(!iam.opensEditor)
    }
}
