import Foundation
import os
import TableProDatabase
import TableProPluginKit

// IAM Identity Center sign-in with the device authorization flow, as `EntraSignIn` does it: no
// redirect URI, and the system browser approves the code.
enum AWSSSOSignIn {
    nonisolated struct Setup: Equatable, Sendable {
        let startUrl: String
        let region: String
    }

    typealias Authorize = @Sendable (
        _ setup: Setup,
        _ presentCode: @escaping @Sendable (URL, String) -> Void
    ) async throws -> AWSSSOTokenCacheEntry

    static let liveAuthorize: Authorize = { setup, presentCode in
        try await AWSSSOLogin.authorize(
            region: setup.region,
            startUrl: setup.startUrl,
            presentCode: presentCode,
            session: AWSHTTP.shared
        )
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "AWSSSOSignIn")

    static func needsSignIn(_ error: Error) -> Bool {
        switch error {
        case let iamError as IAMSignInError:
            return iamError.needsSignIn
        case let ssoError as AWSSSOError:
            return endsTheSignIn(ssoError)
        default:
            return false
        }
    }

    // The saved token is gone or the portal no longer takes it, which only a new sign-in replaces.
    static func endsTheSignIn(_ error: AWSSSOError) -> Bool {
        switch error {
        case .tokenCacheNotFound, .tokenCacheMalformed, .tokenExpired, .sessionUnauthorized:
            return true
        case .configReadFailed, .profileNotFound, .profileMissingFields, .sessionNotFound,
             .sessionMissingFields, .profileMissingUrlOrRegion, .urlBuildFailed, .networkFailure,
             .invalidResponse, .roleNotAccessible, .portalError, .responseDecodeFailed,
             .credentialsAlreadyExpired:
            return false
        }
    }

    static func setup(for connectionId: UUID, secureStore: any SecureStore) -> Setup? {
        let device: DeviceIAMCredentials
        do {
            device = try DeviceIAMCredentials.load(for: connectionId, from: secureStore)
        } catch {
            logger.error("Reading the IAM Identity Center settings failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let startUrl = device.ssoStartUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = device.ssoRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !startUrl.isEmpty, !region.isEmpty else { return nil }
        return Setup(startUrl: startUrl, region: region)
    }

    static func method(
        _ setup: Setup,
        tokens: AWSSSOTokenStore = AWSSSOTokenStore(),
        authorize: @escaping Authorize = liveAuthorize
    ) -> SignInMethod {
        SignInMethod(
            question: ConnectionPrompt(
                title: String(localized: "AWS SSO Sign-In Required"),
                message: String(localized: "Sign in to IAM Identity Center with your browser?"),
                confirmTitle: String(localized: "Sign In")
            ),
            signIn: { prompts, generation in
                try await signIn(setup, tokens: tokens, authorize: authorize) { url, userCode in
                    Task { @MainActor in
                        present(code: userCode, url: url, prompts: prompts, generation: generation)
                    }
                }
            }
        )
    }

    // The token is saved by start URL, so every connection on this Identity Center, and Test
    // Connection, uses the one sign-in.
    static func signIn(
        _ setup: Setup,
        tokens: AWSSSOTokenStore = AWSSSOTokenStore(),
        authorize: @escaping Authorize = liveAuthorize,
        presentCode: @escaping @Sendable (URL, String) -> Void
    ) async throws {
        let entry = try await authorize(setup, presentCode)
        try tokens.save(entry, startUrl: setup.startUrl)
    }

    // The verification link carries the code, so the browser only asks to confirm it.
    private static func present(code: String, url: URL, prompts: ConnectionPromptQueue, generation: Int) {
        SignInOffer.showCode(
            String(format: String(localized: "Confirm the code %@ in the browser to finish signing in."), code),
            opening: url,
            prompts: prompts,
            generation: generation
        )
    }
}
