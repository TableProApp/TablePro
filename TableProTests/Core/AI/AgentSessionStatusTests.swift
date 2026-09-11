//
//  AgentSessionStatusTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("AgentSessionStatus", .serialized)
struct AgentSessionStatusTests {
    @MainActor
    private func makeSession() -> (AgentSession, ToolApprovalCenter, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-status-\(UUID().uuidString)", isDirectory: true)
        let services = TestFixtures.makeServices(aiChatStorage: AIChatStorage(directory: directory))
        let connection = TestFixtures.makeConnection()
        let viewModel = AIChatViewModel(services: services, connection: connection)
        let approvals = ToolApprovalCenter()
        let session = AgentSession(
            connectionId: connection.id,
            connectionName: connection.name,
            viewModel: viewModel,
            approvals: approvals
        )
        return (session, approvals, directory)
    }

    @Test("A fresh session is idle")
    @MainActor
    func freshSessionIsIdle() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(session.status == .idle)
    }

    @Test("Streaming reads as running")
    @MainActor
    func streamingIsRunning() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.viewModel.streamingState = .streaming(assistantID: UUID())
        session.refreshFromEngine()

        #expect(session.status == .running)
    }

    @Test("A provider wait outranks streaming, because a queued turn has not started")
    @MainActor
    func providerWaitIsQueued() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.viewModel.streamingState = .streaming(assistantID: UUID())
        session.viewModel.providerWaitReason = "Waiting for another session on Copilot"
        session.refreshFromEngine()

        #expect(session.status == .queued)
        #expect(session.statusDetail == "Waiting for another session on Copilot")
    }

    @Test("The schema-access consent alert reads as waiting on you")
    @MainActor
    func consentAlertIsWaitingOnYou() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.viewModel.streamingState = .awaitingApproval
        session.refreshFromEngine()

        #expect(session.status == .waitingOnYou)
    }

    @Test("The tool roundtrip limit reads as waiting on you")
    @MainActor
    func toolLimitPauseIsWaitingOnYou() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.viewModel.streamingState = .pausedAtToolLimit(count: 500)
        session.refreshFromEngine()

        #expect(session.status == .waitingOnYou)
    }

    @Test("A failed turn reads as failed")
    @MainActor
    func failedTurnIsFailed() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.viewModel.streamingState = .failed(nil)
        session.refreshFromEngine()

        #expect(session.status == .failed)
    }

    @Test("A stopped session stays stopped when its engine goes idle")
    @MainActor
    func stoppedSurvivesAnIdleEngine() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.stop()
        session.viewModel.streamingState = .idle
        session.refreshFromEngine()

        #expect(session.status == .stopped)
    }

    @Test("A stopped session leaves the terminal status once it works again")
    @MainActor
    func stoppedClearsWhenWorkResumes() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.stop()
        session.viewModel.streamingState = .loading
        session.refreshFromEngine()

        #expect(session.status == .running)
    }

    @Test("Status changes travel from the engine without an explicit refresh")
    @MainActor
    func engineTransitionsPublishThemselves() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.viewModel.streamingState = .loading

        #expect(session.status == .running)
    }

    @Test("A session's title comes from its own first user turn")
    @MainActor
    func titleComesFromTheTranscript() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        session.viewModel.messages.append(
            ChatTurn(role: .user, blocks: [.text("How many orders shipped late?")])
        )
        session.adoptTitleFromTranscript()

        #expect(session.title == "How many orders shipped late?")
        #expect(session.displayTitle == "How many orders shipped late?")
    }

    @Test("A session with no turns is named after its connection")
    @MainActor
    func emptySessionUsesTheConnectionName() {
        let (session, _, directory) = makeSession()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(session.displayTitle == session.connectionName)
    }

    @Test("Only stopped and failed are terminal")
    func terminalStatuses() {
        let terminal = AgentSessionStatus.allCases.filter(\.isTerminal)
        #expect(Set(terminal) == Set([.stopped, .failed]))
    }
}
