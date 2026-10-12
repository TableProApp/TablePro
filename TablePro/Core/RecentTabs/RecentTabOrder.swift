//
//  RecentTabOrder.swift
//  TablePro
//

import Foundation

/// One editor tab in a window that may host several connections. A tab id alone is not enough,
/// because committing a switch has to know which connection to bring on screen first.
internal struct RecentTabReference: Hashable {
    internal let connectionId: UUID
    internal let tabId: UUID
}

/// What one connection in the window contributes: its tabs in strip order and when each was last
/// selected.
internal struct RecentTabSource: Equatable {
    internal let connectionId: UUID
    internal let tabIds: [UUID]
    internal let activationSequence: [UUID: UInt64]
}

/// The window's tabs in the order they were last used, which is what Control-Tab walks.
///
/// Derived on demand from each tab manager's activation record rather than kept as a list of its
/// own, so a tab that closes, moves to another window or arrives from a restore can never leave a
/// stale entry behind: whatever is open is exactly what is ordered.
internal enum RecentTabOrder {
    /// The tab on screen always leads, whatever its sequence says. A connection restored in the
    /// background selects its tab after the one the window shows, and without this the first
    /// press would land on a tab the user never looked at.
    ///
    /// A tab never selected since it opened has no sequence, and follows the used ones in the order
    /// the rail and the strips show them.
    internal static func order(sources: [RecentTabSource], current: RecentTabReference?) -> [RecentTabReference] {
        var used: [(reference: RecentTabReference, sequence: UInt64)] = []
        var unused: [RecentTabReference] = []

        for source in sources {
            for tabId in source.tabIds {
                let reference = RecentTabReference(connectionId: source.connectionId, tabId: tabId)
                guard let sequence = source.activationSequence[tabId] else {
                    unused.append(reference)
                    continue
                }
                used.append((reference, sequence))
            }
        }

        let ordered = used.sorted { $0.sequence > $1.sequence }.map(\.reference) + unused
        guard let current, let index = ordered.firstIndex(of: current), index > 0 else { return ordered }

        var reordered = ordered
        reordered.remove(at: index)
        reordered.insert(current, at: 0)
        return reordered
    }
}
