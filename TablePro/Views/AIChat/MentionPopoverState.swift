//
//  MentionPopoverState.swift
//  TablePro
//

import Foundation

@Observable
@MainActor
final class MentionPopoverState {
    var isVisible = false
    var candidates: [MentionCandidate] = []
    var selectedIndex = 0
    var query = ""
    var anchorRange = NSRange(location: 0, length: 0)

    func reset() {
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
