//
//  ObservedValueChangeTests.swift
//  TableProTests
//
//  A view that observes a parent and reacts to `parent.child.value` never hears the child change,
//  because the child's `@Published` values publish on the child alone. The main window reacts to
//  the sidebar selection and the inspector's view mode that way, each held by a child object.
//

import AppKit
import Combine
import SwiftUI
import Testing

@testable import TablePro

@MainActor
@Suite("Observed value change")
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
    }

    private struct ObservedProbe: View {
        @ObservedObject var parent: Parent
        let changes: Changes

        var body: some View {
            Color.clear.onValueChange(of: \.value, in: parent.child) { old, new in
                changes.pairs.append([old, new])
            }
        }
    }

    private struct ReadThroughProbe: View {
        @ObservedObject var parent: Parent
        let changes: Changes

        var body: some View {
            Color.clear.onValueChange(of: parent.child.value) { old, new in
                changes.pairs.append([old, new])
            }
        }
    }

    private func host(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        settle(window)
        return window
    }

    private func settle(_ window: NSWindow) {
        for _ in 0 ..< 10 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    @Test("a change inside the child reaches the action with both values")
    func childChangeReachesAction() {
        let parent = Parent()
        let changes = Changes()
        let window = host(ObservedProbe(parent: parent, changes: changes))
        defer { window.orderOut(nil) }

        parent.child.value = 1
        settle(window)
        parent.child.value = 2
        settle(window)

        #expect(changes.pairs == [[0, 1], [1, 2]])
    }

    @Test("reading the value through the parent misses the change")
    func readingThroughParentMissesTheChange() {
        let parent = Parent()
        let changes = Changes()
        let window = host(ReadThroughProbe(parent: parent, changes: changes))
        defer { window.orderOut(nil) }

        parent.child.value = 1
        settle(window)

        #expect(changes.pairs.isEmpty)
    }
}
