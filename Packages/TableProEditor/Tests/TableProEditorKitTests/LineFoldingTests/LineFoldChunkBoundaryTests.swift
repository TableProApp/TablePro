//
//  LineFoldChunkBoundaryTests.swift
//  TableProEditorKit
//

import AppKit
@testable import TableProEditorKit
import TableProTextEngine
import Testing

/// The fold calculator pulls lines from the provider 50 at a time, threading the running depth between calls. A local
/// variable used to shadow that state and drop it at every chunk boundary, so depth silently reset to zero on the 51st
/// line of any document.
@MainActor
struct LineFoldChunkBoundaryTests {
    /// Reports the depth it was told to report, and records what the calculator passed in as the previous depth.
    @MainActor
    final class DepthEchoProvider: LineFoldProvider {
        private(set) var previousDepths: [Int: Int] = [:]

        func foldLevelAtLine(
            lineNumber: Int,
            lineRange: NSRange,
            previousDepth: Int,
            controller: TextViewController
        ) -> [LineFoldProviderLineInfo] {
            previousDepths[lineNumber] = previousDepth
            if lineNumber == 0 {
                return [.startFold(rangeStart: lineRange.max, newDepth: 1)]
            }
            return []
        }
    }

    let controller: TextViewController

    init() {
        controller = Mock.textViewController(theme: Mock.theme())
        controller.textView.string = (0..<120).map { "line \($0)" }.joined(separator: "\n")
        controller.textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 4_000)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 1_000, height: 4_000))
    }

    @Test("Depth carries across the 50 line chunk boundary")
    func depthSurvivesChunkBoundary() async throws {
        let provider = DepthEchoProvider()
        controller.foldProvider = provider
        let model = LineFoldModel(controller: controller, foldView: NSView())

        // The calculation runs on the main actor, which every other suite in this target shares, so wait for it to
        // reach the last line rather than for a fixed time. The deadline only turns a hang into a failure; it is not
        // a budget, and five seconds of it was not enough once the editor's own suites moved into this target.
        let deadline = ContinuousClock.now + .seconds(60)
        while provider.previousDepths[100] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = model

        #expect(provider.previousDepths[49] == 1)
        #expect(provider.previousDepths[50] == 1, "Depth reset at the chunk boundary")
        #expect(provider.previousDepths[100] == 1)
    }
}
