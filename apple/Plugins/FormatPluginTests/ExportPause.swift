//
//  ExportPause.swift
//  FormatPluginTests
//

import Foundation

// Holds an export where its data source calls `hold()` until the test resumes it, so a second export on the same
// plugin can run to its end in between.
actor ExportPause {
    private var reached = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var released = false
    private var release: CheckedContinuation<Void, Never>?

    func hold() async {
        reached = true
        arrival?.resume()
        arrival = nil
        guard !released else { return }
        await withCheckedContinuation { release = $0 }
    }

    func untilReached() async {
        guard !reached else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func resume() {
        released = true
        release?.resume()
        release = nil
    }
}
