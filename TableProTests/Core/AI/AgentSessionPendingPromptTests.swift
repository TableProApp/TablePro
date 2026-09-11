//
//  AgentSessionPendingPromptTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AgentSession pending prompt", .serialized)
struct AgentSessionPendingPromptTests {
    /// A final class rather than a captured `var`, because the sender closure is stored on the
    /// session and a local would have to be captured mutably from an escaping closure.
    @MainActor
    private final class SentPrompts {
        var values: [String] = []
    }

    /// The sender is stubbed. The real one opens a provider request, so exercising it here would fire
    /// one against whatever provider the machine running the suite happens to have configured.
    @MainActor
    private func makeSession() -> (AgentSession, DatabaseConnection, SentPrompts, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-pending-prompt-\(UUID().uuidString)", isDirectory: true)
        let connection = TestFixtures.makeConnection()
        let viewModel = AIChatViewModel(
            services: TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: directory)),
            connection: connection
        )
        let sent = SentPrompts()
        let session = AgentSession(
            connectionId: connection.id,
            connectionName: connection.name,
            viewModel: viewModel,
            approvals: ToolApprovalCenter(),
            promptSender: { sent.values.append($0) }
        )
        return (session, connection, sent, directory)
    }

    @Test("A pending prompt becomes the session's first user turn once the connection is up")
    @MainActor
    func pendingPromptSendsOnConnected() {
        let (session, connection, sent, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.pendingPrompt = "how many orders shipped late?"

        session.sendPendingPromptIfReady(connection: connection)

        #expect(session.pendingPrompt == nil)
        #expect(sent.values == ["how many orders shipped late?"])
    }

    @Test("A second connected report does not send the prompt again")
    @MainActor
    func pendingPromptSendsOnce() {
        let (session, connection, sent, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.pendingPrompt = "count the rows"

        session.sendPendingPromptIfReady(connection: connection)
        session.sendPendingPromptIfReady(connection: connection)

        #expect(sent.values == ["count the rows"])
    }

    /// The flush is called from more than one place, because the one that existed only fired when a
    /// connect landed. A connection already open and connected changes nothing about its session,
    /// so nothing adopted it and asking about a database already on screen queued the text and
    /// dropped it. Every flush site has to be safe to call whether or not one already has.
    @Test("Flushing repeatedly, from any number of sites, sends the prompt exactly once")
    @MainActor
    func repeatedFlushesFromEverySiteSendOnce() {
        let (session, connection, sent, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.pendingPrompt = "which customers churned?"

        for _ in 0..<5 {
            session.sendPendingPromptIfReady(connection: connection)
        }

        #expect(sent.values == ["which customers churned?"])
        #expect(session.pendingPrompt == nil)
    }

    @Test("A session with no pending prompt sends nothing")
    @MainActor
    func noPromptSendsNothing() {
        let (session, connection, sent, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.sendPendingPromptIfReady(connection: connection)

        #expect(sent.values.isEmpty)
    }

    @Test("A prompt of only whitespace is discarded rather than sent")
    @MainActor
    func whitespacePromptIsDiscarded() {
        let (session, connection, sent, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.pendingPrompt = "   \n "

        session.sendPendingPromptIfReady(connection: connection)

        #expect(session.pendingPrompt == nil)
        #expect(sent.values.isEmpty)
    }

    @Test("A prompt held through a failed connect is still there for the retry")
    @MainActor
    func promptSurvivesUntilConnected() {
        let (session, _, sent, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.pendingPrompt = "explain the slow query"

        #expect(session.pendingPrompt == "explain the slow query")
        #expect(sent.values.isEmpty)
    }

    @Test("Sending the prompt adopts the connection record it connected with")
    @MainActor
    func sendAdoptsTheConnectionRecord() {
        let (session, connection, sent, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        var renamed = connection
        renamed.name = "production"
        session.pendingPrompt = "hello"

        session.sendPendingPromptIfReady(connection: renamed)

        #expect(session.connectionName == "production")
        #expect(session.viewModel.connection?.name == "production")
        #expect(sent.values == ["hello"])
    }
}
