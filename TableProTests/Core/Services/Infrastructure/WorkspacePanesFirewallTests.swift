//
//  WorkspacePanesFirewallTests.swift
//  TableProTests
//
//  `WorkspacePanes` applies `sizingOptions = []` and tears its panes down by walking one hand-written
//  list. A hosting controller stored beside the others but left off that list publishes its
//  content's minimum width to the split view, which pins the window's dividers (#1872), and outlives
//  its connection, keeping the coordinator it retains answering the app about tabs nobody can see.
//  These read the stored controllers off the instance, so the next pane cannot be forgotten.
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

private final class PaneMountRecorder {
    var makeCount = 0
    var dismantleCount = 0
}

private struct PaneMountProbe: NSViewRepresentable {
    let recorder: PaneMountRecorder

    func makeNSView(context: Context) -> NSView {
        recorder.makeCount += 1
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: PaneMountRecorder) {
        coordinator.dismantleCount += 1
    }

    func makeCoordinator() -> PaneMountRecorder {
        recorder
    }
}

@Suite("Workspace panes firewall", .serialized)
@MainActor
struct WorkspacePanesFirewallTests {
    private static func storedPanes(of panes: WorkspacePanes) -> [(label: String, pane: NSHostingController<AnyView>)] {
        Mirror(reflecting: panes).children.compactMap { child in
            guard let label = child.label, let pane = child.value as? NSHostingController<AnyView> else { return nil }
            return (label, pane)
        }
    }

    @Test("Agent mode's rail and conversation are panes of their own, beside the browse ones")
    func agentPanesAreStoredBesideTheOthers() {
        let panes = WorkspacePanes()
        let labels = Set(Self.storedPanes(of: panes).map(\.label))

        #expect(labels.isSuperset(of: ["agentRail", "agentConversation", "agentResult", "sidebar", "detail"]))
        #expect(panes.agentRail !== panes.sidebar)
        #expect(panes.agentConversation !== panes.detail)
    }

    @Test("Every stored pane publishes no size of its own")
    func everyStoredPaneCarriesTheFirewall() {
        let panes = WorkspacePanes()
        let stored = Self.storedPanes(of: panes)

        #expect(stored.count >= 7)
        for entry in stored {
            #expect(entry.pane.sizingOptions.isEmpty, "\(entry.label) would publish its content's minimum width")
        }
    }

    /// Mounted in a window first, because a pane nothing ever laid out has nothing to dismantle and
    /// would pass having proved nothing.
    @Test("Teardown dismantles and unparents every stored pane, Agent mode's included")
    func teardownReachesEveryStoredPane() throws {
        let panes = WorkspacePanes()
        let stored = Self.storedPanes(of: panes)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        defer { window.orderOut(nil) }

        var recorders: [String: PaneMountRecorder] = [:]
        for entry in stored {
            let recorder = PaneMountRecorder()
            recorders[entry.label] = recorder
            entry.pane.rootView = AnyView(PaneMountProbe(recorder: recorder))
            entry.pane.view.frame = container.bounds
            container.addSubview(entry.pane.view)
        }
        window.orderFront(nil)
        let deadline = Date(timeIntervalSinceNow: 10)
        while recorders.values.contains(where: { $0.makeCount == 0 }), Date() < deadline {
            container.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        for (label, recorder) in recorders {
            try #require(recorder.makeCount == 1, "\(label) never mounted, so the case proves nothing about it")
        }

        panes.teardown()

        for entry in stored {
            #expect(recorders[entry.label]?.dismantleCount == 1, "\(entry.label) kept its content")
            #expect(entry.pane.view.superview == nil, "\(entry.label) stayed in the window")
            #expect(entry.pane.parent == nil, "\(entry.label) stayed a child")
        }
    }

    @Test("Each column draws its browse pane while browsing and its agent pane in Agent mode")
    func columnPaneFollowsTheMode() {
        let panes = WorkspacePanes()

        #expect(panes.sidebarPane(for: .browse) === panes.sidebar)
        #expect(panes.sidebarPane(for: .agent) === panes.agentRail)
        #expect(panes.detailPane(for: .browse) === panes.detail)
        #expect(panes.detailPane(for: .agent) === panes.agentConversation)
    }
}
