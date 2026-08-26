//
//  EditorTabReorder.swift
//  TablePro
//

import CoreGraphics
import Foundation

/// A reorder in flight: the order the strip draws while the pointer is down, and the order it goes
/// back to if the drag is abandoned.
///
/// The pre-drag order is the whole point. The reorder this replaced committed straight into
/// `QueryTabManager.tabs` as the pointer crossed each neighbour, and every one of those writes
/// bumped `tabStructureVersion`, which saves the tab list to disk. Nothing recorded where the tab
/// started, so an abandoned drag left the strip permanently rearranged with no way back. Holding
/// the live order here instead means the manager is written once, on release, and Escape is just
/// dropping this value.
internal struct EditorTabReorder: Equatable {
    internal let draggedId: UUID
    /// The order before the pointer went down, restored by `cancelled`.
    internal let originalOrder: [UUID]
    /// The order the strip draws right now.
    internal private(set) var order: [UUID]

    internal init(draggedId: UUID, order: [UUID]) {
        self.draggedId = draggedId
        originalOrder = order
        self.order = order
    }

    internal var movedFromOriginal: Bool {
        order != originalOrder
    }

    internal var destinationIndex: Int? {
        order.firstIndex(of: draggedId)
    }

    /// Moves the dragged tab to `destination`, or leaves the order alone when it is already there.
    internal mutating func move(to destination: Int) {
        guard let source = order.firstIndex(of: draggedId) else { return }
        let clamped = min(max(destination, 0), order.count - 1)
        guard clamped != source else { return }
        order.insert(order.remove(at: source), at: clamped)
    }

    /// Drops any tab that closed while the pointer was down, from both orders, so a commit or a
    /// revert cannot resurrect it. Returns false when the dragged tab itself went, which ends the
    /// drag: there is nothing left to move.
    internal mutating func removingClosedTabs(keeping live: [UUID]) -> Bool {
        guard live.contains(draggedId) else { return false }
        let surviving = Set(live)
        order.removeAll { !surviving.contains($0) }
        return true
    }
}

/// Where the dragged tab belongs for a given pointer position, without reference to SwiftUI or to
/// the strip's view tree.
///
/// The rule is the system's, not ours: a tab changes places only once the pointer passes the
/// *centre* of the neighbour it is moving into, never at the moment the two rectangles touch.
/// Swapping on contact puts the displaced neighbour under the pointer, which immediately satisfies
/// the swap back, and the pair flip against each other for as long as the pointer sits near the
/// boundary. The reorder this replaced swapped on contact, in `dropEntered`.
internal enum EditorTabReorderResolver {
    /// `location` is measured in the track's *content* space, so it is unaffected by how far the
    /// track has scrolled. Tabs share the track equally, which is what makes a width enough to
    /// place a point; `EditorTabStripLayout.tabWidth(forTrack:count:)` is the one that produced it.
    internal static func destination(
        forLocation location: CGFloat,
        tabWidth: CGFloat,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        guard tabWidth > 0 else { return 0 }
        let index = Int((location / tabWidth).rounded(.down))
        return min(max(index, 0), count - 1)
    }

    /// The destination the drag should settle on, or nil when it should stay where it is.
    ///
    /// Hysteresis lives here rather than in the caller: a place is taken only once the pointer is
    /// past its midpoint, which is the same thing the system's own tab bar does and the reason a
    /// tab does not oscillate on a boundary.
    ///
    /// It answers with the furthest midpoint the pointer has actually crossed, not with the tab it
    /// happens to be over. macOS coalesces a fast drag, so one event can arrive several tabs along:
    /// at a width of 100, dragging from index 0 to a location of 220 lands in the first half of tab
    /// 2, whose midpoint has not been crossed, while tab 1's midpoint at 150 has been. Answering
    /// for the tab under the pointer alone returns nothing there, and a quick drag then commits a
    /// shorter move than the user made, or none at all.
    internal static func settledDestination(
        forLocation location: CGFloat,
        tabWidth: CGFloat,
        currentIndex: Int,
        count: Int
    ) -> Int? {
        guard count > 1, tabWidth > 0 else { return nil }
        let candidate = destination(forLocation: location, tabWidth: tabWidth, count: count)
        guard candidate != currentIndex else { return nil }

        func hasCrossed(_ index: Int) -> Bool {
            let centre = (CGFloat(index) + 0.5) * tabWidth
            return candidate > currentIndex ? location >= centre : location <= centre
        }

        let crossable = candidate > currentIndex
            ? Array((currentIndex + 1) ... candidate)
            : Array((candidate ... (currentIndex - 1)).reversed())
        return crossable.last(where: hasCrossed)
    }
}
