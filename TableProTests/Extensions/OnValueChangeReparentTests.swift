// A workspace switch takes the outgoing pane out of the window and puts it back on return.
// SwiftUI runs the re-attach's onAppear before a change the pane missed while detached, so a
// modifier that reseeded its previous value there reported that change as old == new and
// dropped it. The main window's tab selection reaches `handleTabChange` this way.

import AppKit
import Combine
import SwiftUI
import Testing

@testable import TablePro
import TableProTestSupport

@MainActor
struct OnValueChangeReparentTests {
    private final class Model: ObservableObject {
        @Published var value = 0
    }

    private final class Changes {
        var pairs: [[Int]] = []
        var appearances = 0
        var disappearances = 0
    }

    private struct Probe: View {
        @ObservedObject var model: Model
        let changes: Changes

        var body: some View {
            Color.clear
                .onValueChange(of: model.value) { old, new in
                    changes.pairs.append([old, new])
                }
                .onAppear { changes.appearances += 1 }
                .onDisappear { changes.disappearances += 1 }
        }
    }

    private enum ChangeTiming {
        case whileDetached
        case afterReattachInSameTurn
    }

    @Test("a change made while the pane is detached reaches the action on return")
    func changeWhileDetachedReachesAction() async throws {
        #expect(try await switchAwayAndBack(changing: .whileDetached) == [[0, 1], [1, 2], [2, 3]])
    }

    @Test("a change made in the same turn as the re-attach reaches the action")
    func changeInReattachTurnReachesAction() async throws {
        #expect(try await switchAwayAndBack(changing: .afterReattachInSameTurn) == [[0, 1], [1, 2], [2, 3]])
    }

    /// Drives the pane through `WorkspacePaneHost.show`, the call a workspace switch makes.
    private func switchAwayAndBack(changing timing: ChangeTiming) async throws -> [[Int]] {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        let host = WorkspacePaneHost()
        window.contentView = host.view

        let model = Model()
        let changes = Changes()
        let pane = NSHostingController(rootView: Probe(model: model, changes: changes))
        pane.sizingOptions = []
        let otherPane = NSViewController()
        otherPane.view = NSView()

        host.show(pane)
        try await settle(window) { changes.appearances == 1 }
        model.value = 1
        try await settle(window) { changes.pairs.count == 1 }

        host.show(otherPane)
        try await settle(window) { changes.disappearances == 1 }
        #expect(pane.view.window == nil)

        switch timing {
        case .whileDetached:
            model.value = 2
            host.show(pane)
        case .afterReattachInSameTurn:
            host.show(pane)
            model.value = 2
        }
        try await settle(window) { changes.pairs.count == 2 }

        model.value = 3
        try await settle(window) { changes.pairs.count == 3 }
        return changes.pairs
    }

    /// The window is never shown, so nothing draws it: the hosting view updates on layout.
    private func settle(_ window: NSWindow, until condition: () -> Bool) async throws {
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return condition()
        }
    }
}
