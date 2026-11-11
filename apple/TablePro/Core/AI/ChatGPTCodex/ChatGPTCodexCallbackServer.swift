//
//  ChatGPTCodexCallbackServer.swift
//  TablePro
//
//  Ephemeral loopback HTTP server that captures the OAuth authorization code
//  redirected to http://localhost:1455/auth/callback during ChatGPT sign-in.
//

import Foundation
import os
import TableProHTTP

// Only the redirect carrying this sign-in's `state` settles it (RFC 6749 section 4.1.2, RFC 8252 section 7.3).
enum ChatGPTCodexCallback: Sendable, Equatable {
    case code(String)
    case denied(error: String, description: String?)
    case ignore

    static let callbackPath = URLComponents(string: ChatGPTCodex.redirectURI)?.path ?? ""

    static let unknownError = "unknown_error"

    private static let maximumErrorLength = 300

    static func parse(requestHead: String, expectedState: String) -> ChatGPTCodexCallback {
        guard !expectedState.isEmpty,
              !callbackPath.isEmpty,
              let target = LoopbackRedirectRequest.getTarget(requestHead),
              let components = URLComponents(string: target),
              components.host == nil,
              components.path == callbackPath
        else {
            return .ignore
        }
        let items = components.queryItems ?? []
        guard let state = LoopbackRedirectRequest.singleValue(named: "state", in: items),
              LoopbackRedirectRequest.constantTimeEquals(state, expectedState)
        else {
            return .ignore
        }
        if items.contains(where: { $0.name == "error" }) {
            let error = LoopbackRedirectRequest.singleValue(named: "error", in: items).flatMap(sanitized) ?? unknownError
            let formItems = LoopbackRedirectRequest.formDecodedItems(in: components)
            let description = LoopbackRedirectRequest.singleValue(named: "error_description", in: formItems).flatMap(sanitized)
            return .denied(error: error, description: description)
        }
        if let code = LoopbackRedirectRequest.singleValue(named: "code", in: items), !code.isEmpty {
            return .code(code)
        }
        return .ignore
    }

    // RFC 6749 allows only printable ASCII other than `"` and `\` in `error` and `error_description`.
    private static func sanitized(_ value: String) -> String? {
        let allowed = value.unicodeScalars.filter { scalar in
            (0x20...0x7E).contains(scalar.value) && scalar != "\"" && scalar != "\\"
        }
        let text = String(String.UnicodeScalarView(allowed.prefix(maximumErrorLength)))
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

final class ChatGPTCodexCallbackServer: Sendable {
    enum ServerError: Error, LocalizedError, Equatable {
        case portInUse
        case timedOut
        case authorizationDenied(error: String, description: String?)

        var errorDescription: String? {
            switch self {
            case .portInUse:
                return String(localized: "Port 1455 is in use. Quit the Codex CLI or another sign-in and try again.")
            case .timedOut:
                return String(localized: "Sign-in timed out. Please try again.")
            case .authorizationDenied(let error, let description):
                if error == "access_denied" {
                    guard let description else { return String(localized: "ChatGPT sign-in was denied.") }
                    return String(format: String(localized: "ChatGPT sign-in was denied: %@"), description)
                }
                return String(format: String(localized: "ChatGPT sign-in failed: %@"), description ?? error)
            }
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatGPTCodexCallbackServer")
    private static let timeout: TimeInterval = 300
    private static let startTimeout: TimeInterval = 10

    private let listener: LoopbackRedirectListener<String>

    init(expectedState: String, port: UInt16 = ChatGPTCodex.redirectPort, headTimeout: TimeInterval = 5) {
        listener = LoopbackRedirectListener(port: port, headTimeout: headTimeout) { head in
            Self.answer(head, expectedState: expectedState)
        }
    }

    @discardableResult
    func start() async throws -> UInt16 {
        do {
            return try await listener.start(readyTimeout: Self.startTimeout)
        } catch LoopbackRedirectListenerError.timedOut {
            throw ServerError.timedOut
        } catch is LoopbackRedirectListenerError {
            throw ServerError.portInUse
        }
    }

    func waitForCode() async throws -> String {
        try await listener.outcome(timeout: Self.timeout, timeoutError: ServerError.timedOut)
    }

    func stop() {
        listener.stop()
    }

    private static func answer(_ head: Data, expectedState: String) -> LoopbackRedirectAnswer<String> {
        let text = LoopbackRedirectRequest.text(of: head)
        switch ChatGPTCodexCallback.parse(requestHead: text, expectedState: expectedState) {
        case .ignore:
            return .ignore(LoopbackRedirectPage.badRequest)
        case .code(let code):
            return .settle(successPage, .success(code))
        case .denied(let error, let description):
            logger.info("The ChatGPT sign-in redirect carried an OAuth error: \(error, privacy: .private)")
            return .settle(failurePage, .failure(ServerError.authorizationDenied(error: error, description: description)))
        }
    }

    private static let successPage = LoopbackRedirectPage.response(
        status: "200 OK",
        title: "Signed in to ChatGPT",
        message: "You can return to TablePro."
    )

    private static let failurePage = LoopbackRedirectPage.response(
        status: "200 OK",
        title: "Sign-in failed",
        message: "Please return to TablePro and try again."
    )
}
