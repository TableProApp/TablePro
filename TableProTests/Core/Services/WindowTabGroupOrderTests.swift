//
//  WindowTabGroupOrderTests.swift
//  TableProTests
//
//  Saving and restoring tabs both describe a window by its place in the native tab group. They have to
//  agree: a window with no live session has no coordinator to be counted among, but it still occupies a
//  tab, and numbering around it would hand every window after it somebody else's tabs.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Window tab group order")
@MainActor
struct WindowTabGroupOrderTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
    }

    @Test("A window with no tab group is alone at the first position")
    func windowWithoutTabGroupIsFirst() {
        let window = makeWindow()

        #expect(WindowTabGroupOrder.index(of: window) == 0)
        #expect(WindowTabGroupOrder.size(containing: window) == 1)
        #expect(WindowTabGroupOrder.windows(containing: window) == [window])
    }

    @Test("A window reports its position in the group it belongs to")
    func positionWithinGroup() {
        /// Held in bindings on purpose: an `ObjectIdentifier` taken from a temporary is only unique
        /// while that object is alive, and the next allocation can land on the same address.
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        let thirdWindow = makeWindow()
        let group = [firstWindow, secondWindow, thirdWindow].map(ObjectIdentifier.init)

        #expect(WindowTabGroupOrder.position(of: ObjectIdentifier(firstWindow), in: group) == 0)
        #expect(WindowTabGroupOrder.position(of: ObjectIdentifier(secondWindow), in: group) == 1)
        #expect(WindowTabGroupOrder.position(of: ObjectIdentifier(thirdWindow), in: group) == 2)
    }

    /// A window absent from the list it was asked about is treated as the only one there is, which is
    /// the same answer a connection's single window gets.
    @Test("A window missing from its group falls back to the first position")
    func missingWindowFallsBackToFirst() {
        let absentWindow = makeWindow()
        let presentWindow = makeWindow()
        let absent = ObjectIdentifier(absentWindow)

        #expect(WindowTabGroupOrder.position(of: absent, in: [ObjectIdentifier(presentWindow)]) == 0)
        #expect(WindowTabGroupOrder.position(of: absent, in: []) == 0)
    }
}
