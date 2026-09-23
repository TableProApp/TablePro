//
//  RecentTabSwitcherSession.swift
//  TablePro
//

import Foundation

internal enum RecentTabSwitchDirection: Equatable {
    case forward
    case backward

    internal var reversed: RecentTabSwitchDirection {
        self == .forward ? .backward : .forward
    }

    fileprivate var offset: Int {
        self == .forward ? 1 : -1
    }
}

/// A row of the switcher: the tab it switches to and what it says about that tab.
internal struct RecentTabCandidate: Identifiable, Equatable {
    internal let reference: RecentTabReference
    internal let title: String
    internal let detail: String
    internal let symbolName: String

    internal var id: RecentTabReference { reference }
}

/// One press-hold-release of the switch command, from its first press to the tab it lands on.
///
/// The list is taken when the switch starts and walked from there, the way the app switcher walks
/// the apps, so pressing the chord again moves through the same order rather than a list the last
/// step just changed. The tab on screen, when there is one, sits at index zero and is part of the
/// cycle, so walking all the way round and releasing stays where the user started.
internal struct RecentTabSwitcherSession: Equatable {
    internal private(set) var candidates: [RecentTabCandidate]
    internal private(set) var highlightedIndex: Int
    private let leadsWithCurrentTab: Bool

    /// Nil when there is nothing to switch to. Forward starts on the tab used before this one,
    /// backward on the one used longest ago.
    ///
    /// `leadsWithCurrentTab` is false when the connection on screen has no tab open, and then every
    /// candidate is somewhere else: forward starts on the most recent of them rather than skipping it.
    internal init?(
        candidates: [RecentTabCandidate],
        direction: RecentTabSwitchDirection,
        leadsWithCurrentTab: Bool = true
    ) {
        guard candidates.count >= Self.minimumCount(leadsWithCurrentTab: leadsWithCurrentTab) else { return nil }
        self.candidates = candidates
        self.leadsWithCurrentTab = leadsWithCurrentTab
        let first = leadsWithCurrentTab ? 1 : 0
        self.highlightedIndex = direction == .forward ? first : candidates.count - 1
    }

    private static func minimumCount(leadsWithCurrentTab: Bool) -> Int {
        leadsWithCurrentTab ? 2 : 1
    }

    internal var highlighted: RecentTabCandidate {
        candidates[highlightedIndex]
    }

    internal mutating func step(_ direction: RecentTabSwitchDirection) {
        let count = candidates.count
        highlightedIndex = ((highlightedIndex + direction.offset) % count + count) % count
    }

    /// Steps over the candidates still open, dropping the ones that closed while the switch was
    /// held. When the highlighted tab itself closed, the step lands where it would have from that
    /// tab: forward on the one after it, backward on the one before. Returns false once nothing is
    /// left to switch to.
    internal mutating func step(_ direction: RecentTabSwitchDirection, keeping isOpen: (RecentTabReference) -> Bool) -> Bool {
        let highlightedReference = highlighted.reference
        let remaining = candidates.filter { isOpen($0.reference) }
        guard remaining.count >= Self.minimumCount(leadsWithCurrentTab: leadsWithCurrentTab) else { return false }

        if let kept = remaining.firstIndex(where: { $0.reference == highlightedReference }) {
            candidates = remaining
            highlightedIndex = kept
            step(direction)
            return true
        }

        let followers = candidates[(highlightedIndex + 1)...].filter { isOpen($0.reference) }.count
        let after = (remaining.count - followers) % remaining.count
        candidates = remaining
        highlightedIndex = after
        if direction == .backward {
            step(.backward)
        }
        return true
    }
}
