// A view that observes a parent and reacts to `parent.child.value` never hears the child change,
// because the child's `@Published` values publish on the child alone. The main window reacts to
// the sidebar selection and the inspector's view mode that way, each held by a child object.

import AppKit
import Combine
import SwiftUI
import Testing

@testable import TablePro
import TableProTestSupport

@MainActor
struct ObservedValueChangeTests {
    private final class Child: ObservableObject {
        @Published var value = 0
    }

    private final class Parent: ObservableObject {
        @Published var title = ""
        let child = Child()
    }

    private final class Changes {
        var pairs: [[Int]] = []
        var appeared = false
    }

    private struct ObservedProbe: View {
        @ObservedObject var parent: Parent
        let changes: Changes

        var body: some View {
            Color.clear
                .onValueChange(of: \.value, in: parent.child) { old, new in
                    changes.pairs.append([old, new])
                }
                .onAppear { changes.appeared = true }
        }
    }

    private struct ReadThroughProbe: View {
        @ObservedObject var parent: Parent
        let changes: Changes

        var body: some View {
            Color.clear
                .onValueChange(of: parent.child.value) { old, new in
                    changes.pairs.append([old, new])
                }
                .onAppear { changes.appeared = true }
        }
    }

    /// A sibling the window does hear. Its change lands in the same update a change to the probe
    /// would have, so once it is reported, a probe that stayed silent heard nothing.
    private struct BarrierProbe: View {
        @ObservedObject var barrier: Child
        let changes: Changes

        var body: some View {
            Color.clear
                .onValueChange(of: barrier.value) { old, new in
                    changes.pairs.append([old, new])
                }
                .onAppear { changes.appeared = true }
        }
    }

    private func host(_ view: some View, appeared: [Changes]) async throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        try await settle(window) { appeared.allSatisfy(\.appeared) }
        return window
    }

    /// The window is never shown, so nothing draws it: the hosting view updates on layout.
    private func settle(_ window: NSWindow, until condition: () -> Bool) async throws {
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return condition()
        }
    }

    @Test("a change inside the child reaches the action with both values")
    func childChangeReachesAction() async throws {
        let parent = Parent()
        let changes = Changes()
        let window = try await host(ObservedProbe(parent: parent, changes: changes), appeared: [changes])
        defer { window.orderOut(nil) }

        parent.child.value = 1
        try await settle(window) { changes.pairs.count == 1 }
        parent.child.value = 2
        try await settle(window) { changes.pairs.count == 2 }

        #expect(changes.pairs == [[0, 1], [1, 2]])
    }

    @Test("reading the value through the parent misses the change")
    func readingThroughParentMissesTheChange() async throws {
        let parent = Parent()
        let changes = Changes()
        let barrier = Child()
        let barrierChanges = Changes()
        let window = try await host(
            VStack {
                ReadThroughProbe(parent: parent, changes: changes)
                BarrierProbe(barrier: barrier, changes: barrierChanges)
            },
            appeared: [changes, barrierChanges]
        )
        defer { window.orderOut(nil) }

        parent.child.value = 1
        barrier.value = 1
        try await settle(window) { barrierChanges.pairs == [[0, 1]] }

        #expect(changes.pairs.isEmpty)
    }
}
