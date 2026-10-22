import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SignInOfferTests {
    private let startUrl = "https://example.awsapps.com/start"

    @MainActor
    private final class Runs {
        var count = 0
    }

    private func ssoConnection(in store: EphemeralSecureStore) throws -> DatabaseConnection {
        let connection = DatabaseConnection(
            type: .postgresql,
            host: "db.abc123.us-east-1.rds.amazonaws.com",
            port: 5_432,
            username: "iam_user",
            additionalFields: [IAMSignIn.Field.method: IAMSignIn.awsSSO.pickerValue]
        )
        try DeviceIAMCredentials(
            ssoStartUrl: startUrl,
            ssoRegion: "us-east-1",
            ssoAccountId: "111122223333",
            ssoRoleName: "ReadOnly"
        ).save(for: connection.id, to: store)
        return connection
    }

    private func method(_ signIn: @escaping @MainActor (ConnectionPromptQueue, Int) async throws -> Void) -> SignInMethod {
        SignInMethod(
            question: ConnectionPrompt(title: "Sign-In Required", message: "Sign in?", confirmTitle: "Sign In"),
            signIn: signIn
        )
    }

    private func answer(_ queue: ConnectionPromptQueue, accepted: Bool) async {
        await ObservedCondition.wait { queue.current != nil }
        guard let prompt = queue.current else { return }
        queue.answer(prompt.id, accepted: accepted)
    }

    private func entry() -> AWSSSOTokenCacheEntry {
        AWSSSOTokenCacheEntry(
            accessToken: "portal-token",
            expiresAt: Date().addingTimeInterval(3_600),
            region: "us-east-1",
            startUrl: startUrl
        )
    }

    @Test("An expired Entra sign-in is offered through Entra")
    func entraSignInIsOffered() {
        let offered = SignInOffer.method(
            for: EntraOAuthError.signInRequired,
            connection: DatabaseConnection(type: .mssql),
            secureStore: EphemeralSecureStore()
        )

        #expect(offered?.question.title == String(localized: "Microsoft Entra ID Sign-In Required"))
    }

    @Test("An IAM Identity Center connection whose sign-in expired is offered the AWS sign-in")
    func identityCenterSignInIsOffered() throws {
        let store = EphemeralSecureStore()
        let connection = try ssoConnection(in: store)

        let offered = SignInOffer.method(for: IAMSignInError.ssoSignInRequired, connection: connection, secureStore: store)

        #expect(offered?.question.title == String(localized: "AWS SSO Sign-In Required"))
        #expect(AWSSSOSignIn.setup(for: connection.id, secureStore: store) == AWSSSOSignIn.Setup(startUrl: startUrl, region: "us-east-1"))
    }

    @Test("Nothing is offered when IAM Identity Center is not set up on this device")
    func noOfferWithoutSetup() {
        let connection = DatabaseConnection(
            type: .postgresql,
            additionalFields: [IAMSignIn.Field.method: IAMSignIn.awsSSO.pickerValue]
        )

        let offered = SignInOffer.method(for: IAMSignInError.ssoSignInRequired, connection: connection, secureStore: EphemeralSecureStore())

        #expect(offered == nil)
    }

    @Test("A failure a sign-in cannot fix is shown, not offered", arguments: [
        EntraOAuthError.accessDenied as Error,
        IAMSignInError.accessKeyMissing,
        IAMSignInError.ssoNotSetUp,
        AWSSSOLoginError.authorizationTimedOut,
        ConnectionError.notConnected,
    ])
    func noOfferForOtherFailures(error: Error) throws {
        let store = EphemeralSecureStore()
        let connection = try ssoConnection(in: store)

        #expect(SignInOffer.method(for: error, connection: connection, secureStore: store) == nil)
    }

    @Test("Declining the question runs no sign-in")
    func declineRunsNothing() async {
        let queue = ConnectionPromptQueue()
        let runs = Runs()
        let offered = method { _, _ in runs.count += 1 }

        async let outcome = SignInOffer.offer(offered, prompts: queue)
        await answer(queue, accepted: false)

        guard case .declined = await outcome else {
            Issue.record("A declined question should report declined")
            return
        }
        #expect(runs.count == 0)
    }

    @Test("A sign-in that finishes reports signed in, so the connect is retried")
    func finishedSignIn() async {
        let queue = ConnectionPromptQueue()
        let runs = Runs()
        let offered = method { _, _ in runs.count += 1 }

        async let outcome = SignInOffer.offer(offered, prompts: queue)
        await answer(queue, accepted: true)

        guard case .signedIn = await outcome else {
            Issue.record("A finished sign-in should report signed in")
            return
        }
        #expect(runs.count == 1)
    }

    @Test("A sign-in that fails reports its own error, not the connect error that asked for it")
    func failedSignInKeepsItsError() async {
        let queue = ConnectionPromptQueue()
        let offered = method { _, _ in throw AWSSSOLoginError.accessDenied }

        async let outcome = SignInOffer.offer(offered, prompts: queue)
        await answer(queue, accepted: true)

        guard case .failed(let error) = await outcome else {
            Issue.record("A failed sign-in should report its error")
            return
        }
        #expect(error as? AWSSSOLoginError == .accessDenied)
    }

    @Test("The AWS sign-in saves its token under the start URL, for every connection on that Identity Center")
    func identityCenterTokenIsSaved() async throws {
        let tokens = AWSSSOTokenStore(items: EphemeralSecureStore())
        let signedIn = entry()

        try await AWSSSOSignIn.signIn(
            AWSSSOSignIn.Setup(startUrl: startUrl, region: "us-east-1"),
            tokens: tokens,
            authorize: { _, _ in signedIn },
            presentCode: { _, _ in }
        )

        #expect(tokens.token(startUrl: startUrl)?.accessToken == signedIn.accessToken)
        #expect(tokens.token(startUrl: startUrl + "/")?.accessToken == signedIn.accessToken)
    }

    @Test("A failed AWS sign-in saves nothing and passes its error on")
    func failedIdentityCenterSignInSavesNothing() async {
        let tokens = AWSSSOTokenStore(items: EphemeralSecureStore())

        await #expect(throws: AWSSSOLoginError.accessDenied) {
            try await AWSSSOSignIn.signIn(
                AWSSSOSignIn.Setup(startUrl: startUrl, region: "us-east-1"),
                tokens: tokens,
                authorize: { _, _ in throw AWSSSOLoginError.accessDenied },
                presentCode: { _, _ in }
            )
        }
        #expect(tokens.token(startUrl: startUrl) == nil)
    }

    @Test("Every portal error the screen calls an expired sign-in is one the connect offers to fix", arguments: [
        AWSSSOError.configReadFailed,
        .profileNotFound("p"),
        .profileMissingFields(profile: "p"),
        .sessionNotFound(profile: "p", session: "s"),
        .sessionMissingFields(session: "s"),
        .profileMissingUrlOrRegion("p"),
        .tokenCacheNotFound(profile: "p"),
        .tokenCacheMalformed(profile: "p"),
        .tokenExpired(profile: "p"),
        .urlBuildFailed(profile: "p"),
        .networkFailure(profile: "p", underlying: "offline"),
        .invalidResponse(profile: "p"),
        .sessionUnauthorized(profile: "p"),
        .roleNotAccessible(role: "r", account: "a"),
        .portalError(profile: "p", status: 500),
        .responseDecodeFailed(profile: "p"),
        .credentialsAlreadyExpired(profile: "p"),
    ])
    func expiredSignInsAreOffered(error: AWSSSOError) {
        let shown = ErrorClassifier.classify(error, context: ErrorContext(operation: "connect"))
        let saysSignInExpired = shown.title == String(localized: "AWS SSO Sign-In Required")

        #expect(AWSSSOSignIn.needsSignIn(error) == saysSignInExpired)
    }
}
