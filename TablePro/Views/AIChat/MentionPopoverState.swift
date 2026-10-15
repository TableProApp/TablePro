//
//  MentionPopoverState.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class MentionPopoverState: ObservableObject {
    @Published var isVisible = false
    @Published var candidates: [MentionCandidate] = []
    @Published var selectedIndex = 0
    @Published var query = ""
    @Published var anchorRange = NSRange(location: 0, length: 0)

    /// Called on every keystroke without a mention in progress, so it writes only when there is something to clear:
    /// each write publishes, and the composer's owner redraws on every publish.
    func reset() {
        guard isVisible || !candidates.isEmpty || selectedIndex != 0 || !query.isEmpty || anchorRange.length != 0
            || anchorRange.location != 0 else { return }
        isVisible = false
        candidates = []
        selectedIndex = 0
        query = ""
        anchorRange = NSRange(location: 0, length: 0)
    }

    func clampSelection() {
        guard !candidates.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = max(0, min(selectedIndex, candidates.count - 1))
    }

    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        let count = candidates.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    var selectedCandidate: MentionCandidate? {
        guard candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }
}
