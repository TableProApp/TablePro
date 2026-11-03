import Foundation
@testable import TablePro
import Testing

@MainActor
struct AIProviderStatusTests {
    private func status(
        _ type: AIProviderType,
        endpoint: String? = nil,
        hasAPIKey: Bool = false,
        oauthState: OAuthAuthState? = nil,
        serviceError: String? = nil,
        claudeAgent: ClaudeAgentService.InstallState = .unknown
    ) -> AIProviderStatus {
        var provider = AIProviderConfig(name: "", type: type)
        if let endpoint { provider.endpoint = endpoint }
        return AIProviderStatus.resolve(
            provider: provider,
            hasAPIKey: hasAPIKey,
            oauthState: oauthState,
            serviceError: serviceError,
            claudeAgent: claudeAgent
        )
    }

    @Test("A provider that needs a key says so with a warning")
    func missingKey() {
        let missing = status(.openAI)
        #expect(missing == .needsAPIKey)
        #expect(missing.severity == .warning)
        #expect(status(.openAI, hasAPIKey: true).isReady)
    }

    @Test("A provider whose key is optional is ready without one")
    func optionalKeyIsReadyWithoutOne() {
        #expect(status(.openCode).isReady)
        #expect(status(.custom, endpoint: "https://llm.example.com/v1") == .ready(detail: "llm.example.com"))
        #expect(status(.custom, endpoint: "") == .notConfigured)
    }

    @Test("A Copilot error shows on the row, not only in the sheet")
    func serviceErrorWins() {
        let failed = status(.copilot, oauthState: .signedIn(identity: "octocat"), serviceError: "Copilot subscription inactive")
        #expect(failed == .failed(message: "Copilot subscription inactive"))
        #expect(failed.severity == .error)
    }

    @Test("Sign-in states read from the service, and an unanswered service is still checking")
    func oauthStates() {
        #expect(status(.copilot) == .checking)
        #expect(status(.copilot, oauthState: .signedOut) == .needsSignIn)
        #expect(status(.chatgptCodex, oauthState: .signingIn) == .signingIn)
        #expect(status(.chatgptCodex, oauthState: .signedIn(identity: "me@example.com")).isReady)
    }

    @Test("Claude Code states map one to one")
    func claudeAgentStates() {
        #expect(status(.claudeAgent, claudeAgent: .unknown) == .checking)
        #expect(status(.claudeAgent, claudeAgent: .notInstalled) == .needsInstall)
        #expect(status(.claudeAgent, claudeAgent: .outdated(version: "1.0.0")) == .needsUpdate(version: "1.0.0"))
        #expect(status(.claudeAgent, claudeAgent: .signedOut) == .needsSignIn)
        #expect(status(.claudeAgent, claudeAgent: .signedIn(account: "me", plan: "Max")).isReady)
    }

    @Test("A local server reads as local")
    func localServer() {
        #expect(status(.ollama) == .ready(detail: String(localized: "Local")))
    }

    @Test("Only states the user has to fix carry a symbol")
    func readyAndBusyStatesAreQuiet() {
        for quiet in [AIProviderStatus.checking, .signingIn, .ready(detail: nil)] {
            #expect(quiet.severity == nil)
        }
    }
}
