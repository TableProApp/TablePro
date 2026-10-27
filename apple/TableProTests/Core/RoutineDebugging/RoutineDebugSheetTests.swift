//
//  RoutineDebugSheetTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct RoutineDebugSheetTests {
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func present(on window: NSWindow, setup: RoutineDebugSetup) -> Task<Int?, Never> {
        Task {
            await RoutineDebugSheet.present(on: window, setup: setup) { (_: @escaping @MainActor (Int?) -> Void) in
                Text(verbatim: "Sheet")
            }
        }
    }

    @Test("Closing the window under the sheet answers it as cancelled")
    func parentCloseAnswersTheSheet() async throws {
        let window = Self.makeWindow()
        let setup = RoutineDebugSetup()
        let answer = Self.present(on: window, setup: setup)
        try await waitUntil { setup.dismissPresentation != nil }

        window.close()

        #expect(await answer.value == nil)
        #expect(setup.dismissPresentation == nil)
    }

    @Test("A sheet already answered ignores its window closing afterwards")
    func parentCloseAfterAnswerResumesNothing() async throws {
        let window = Self.makeWindow()
        let setup = RoutineDebugSetup()
        let answer = Self.present(on: window, setup: setup)
        try await waitUntil { setup.dismissPresentation != nil }

        setup.cancel()
        #expect(await answer.value == nil)
        window.close()
    }
}
