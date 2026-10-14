import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct CrossProcessApprovalTests {
    private func window<Value: Sendable>(
        hosting rootView: some View,
        gate: ModalDecisionGate<Value>
    ) -> ModalDecisionWindow {
        let host = NSHostingController(rootView: rootView)
        let window = AlertHelper.decisionWindow(
            hosting: host,
            title: "Approval",
            styleMask: [.titled, .closable],
            gate: gate
        )
        host.view.layoutSubtreeIfNeeded()
        return window
    }

    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        return window.performKeyEquivalent(with: event)
    }

    private func approvalView(gate: ModalDecisionGate<Bool>) -> CrossProcessApprovalView {
        CrossProcessApprovalView(
            title: "MCP Access Request",
            message: "A client wants to access 'prod'.",
            allowTitle: "Allow",
            denyTitle: "Deny",
            onDecide: { gate.deliver(.success($0)) }
        )
    }

    @Test("Return denies a cross-process approval")
    func returnDenies() async throws {
        let gate = ModalDecisionGate<Bool>.confirmation()
        let window = window(hosting: approvalView(gate: gate), gate: gate)

        #expect(try press("\r", keyCode: 36, in: window))
        #expect(try await gate.value() == false)
    }

    @Test("Escape denies a cross-process approval")
    func escapeDenies() async throws {
        let gate = ModalDecisionGate<Bool>.confirmation()
        let window = window(hosting: approvalView(gate: gate), gate: gate)

        window.cancelOperation(nil)

        #expect(try await gate.value() == false)
    }

    @Test("Return denies a pairing request")
    func returnDeniesPairing() async throws {
        let gate = ModalDecisionGate<PairingApproval>.pairing()
        let redirect = try #require(URL(string: "http://127.0.0.1:51888/callback"))
        let sheet = PairingApprovalSheet(
            request: PairingRequest(
                clientName: "Launcher",
                challenge: "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY",
                redirectURL: redirect,
                requestedScopes: nil,
                requestedConnectionIds: nil
            ),
            codeExpiresAt: Date(timeIntervalSinceNow: 300),
            allowsHiddenConnectionListing: false,
            onComplete: { gate.deliver($0) }
        )
        let window = window(hosting: sheet, gate: gate)

        #expect(try press("\r", keyCode: 36, in: window))
        await #expect(throws: DatabaseAccessError.self) {
            _ = try await gate.value()
        }
    }

    @Test("The approval prompt is not greedy")
    func approvalViewHasABoundedHeight() {
        let gate = ModalDecisionGate<Bool>.confirmation()
        let host = NSHostingController(rootView: approvalView(gate: gate))
        host.sizingOptions = []
        let size = host.sizeThatFits(in: NSSize(width: CrossProcessApprovalView.width, height: .greatestFiniteMagnitude))
        #expect(size.height.isFinite)
        #expect(size.height < 600)
    }

    @Test("A client name of any length leaves the connection it asks for on screen")
    func longClientNameKeepsTheConnectionVisible() {
        let message = MCPApprovalAlertPresenter.message(for: MCPApprovalRequest(
            connectionName: "prod",
            databaseType: "PostgreSQL",
            clientLabel: String(repeating: "x", count: 5_000),
            memory: .untilRevoked
        ))

        #expect(message.contains("'prod' (PostgreSQL)"))
        #expect(message.count < MCPApprovalAlertPresenter.maximumClientLabelLength + 300)
    }
}
