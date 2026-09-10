//
//  EditorTabStripInteraction.swift
//  TablePro
//

import AppKit
import Foundation
import Observation

/// What a press on the strip turned out to be.
internal enum EditorTabGesture: Equatable {
    case click(count: Int)
    case reorder
    case tearOff
}

/// The one piece of state the strip's two halves share: AppKit owns the pointer and writes here,
/// SwiftUI reads it and draws.
///
/// The split exists because the two jobs have different owners on macOS. Which control receives a
/// press inside a titlebar accessory was previously decided by SwiftUI gesture arbitration between
/// a `Button`, a `ScrollView` and a `DragGesture`, with AppKit's own window drag as a fourth
/// claimant, and the winner depended on timing: measured on this strip, a plain one-place drag did
/// nothing about one time in seven, and the four UI tests covering it have never passed CI. A
/// press has exactly one owner now, and it is `EditorTabInteractionView`.
///
/// Geometry lives here rather than in the SwiftUI layout for the same reason. The tab a user sees,
/// the tab the pointer hits and the tab a drag targets are one rectangle out of
/// `EditorTabRunLayout`, so they cannot disagree.
@MainActor
@Observable
internal final class EditorTabStripInteraction {
    /// The run the strip draws, measured by the view that owns the pointer.
    internal private(set) var run: EditorTabRunLayout = .empty
    /// How far the track has scrolled, in points. Always zero when the run wraps, because a
    /// wrapped run never overflows.
    internal private(set) var contentOffset: CGFloat = 0
    internal private(set) var hoveredTabId: UUID?
    /// Set while the pointer is over a tab's close button, because the button no longer receives
    /// the mouse and cannot light itself.
    internal private(set) var hoveredCloseTabId: UUID?
    /// The reorder in flight, holding both the order the strip draws and the order it came from.
    /// The manager is not written until the pointer comes up, so an abandoned drag leaves nothing
    /// behind and Escape is just dropping this value.
    internal private(set) var reorder: EditorTabReorder?
    internal private(set) var tearingOffTabId: UUID?
    /// The track's visible width, measured by the view that owns the pointer. SwiftUI reads it so
    /// a reveal and a clamp use the same number the pointer does.
    internal private(set) var viewportWidth: CGFloat = 0
    /// The last width the pointer's owner measured, kept so a tab opening or closing can re-lay
    /// the run without waiting for AppKit to schedule another layout pass.
    private var trackWidth: CGFloat = 0

    internal var overflow: EditorTabStripOverflow = .scroll {
        didSet {
            guard overflow != oldValue else { return }
            contentOffset = 0
            updateRun(trackWidth: trackWidth, count: tabIds.count)
        }
    }

    /// Rebuilt on every render, because the closures reach through the workspace to a coordinator
    /// that only exists once the detail pane has appeared.
    internal var commands: EditorTabCommands?

    internal var tabIds: [UUID] = []

    /// Raised whenever a rebuild changes how many rows the run takes, from any path. The band's
    /// height follows it, and a tab opened or closed while the strip is wrapped can cross a row
    /// boundary without any layout pass having run.
    internal var onRowCountChanged: ((Int) -> Void)?
    private var reportedRowCount = 1

    /// The order the strip draws: the reorder's while one is in flight, the manager's otherwise.
    internal var displayedIds: [UUID] {
        reorder?.order ?? tabIds
    }

    internal func updateRun(trackWidth: CGFloat, count: Int) {
        self.trackWidth = trackWidth
        viewportWidth = max(trackWidth - EditorTabStripLayout.trackPadding * 2, 0)
        let rebuilt = EditorTabRunLayoutBuilder.run(
            forTrack: trackWidth,
            count: count,
            overflow: overflow
        )
        guard rebuilt != run else { return }
        run = rebuilt
        clampContentOffset()
        guard run.rowCount != reportedRowCount else { return }
        reportedRowCount = run.rowCount
        onRowCountChanged?(run.rowCount)
    }

    internal func setHovered(_ id: UUID?, overCloseButton: Bool = false) {
        if hoveredTabId != id { hoveredTabId = id }
        let close = overCloseButton ? id : nil
        if hoveredCloseTabId != close { hoveredCloseTabId = close }
    }

    internal func scroll(by delta: CGFloat) {
        guard overflow == .scroll else { return }
        contentOffset += delta
        clampContentOffset()
    }

    internal func clampContentOffset() {
        let maximum = max(run.contentSize.width - viewportWidth, 0)
        contentOffset = min(max(contentOffset, 0), maximum)
    }

    /// Brings a tab fully into the viewport, which is what a selection made from the keyboard, the
    /// sidebar or a closed neighbour needs.
    internal func revealTab(id: UUID) {
        guard overflow == .scroll, viewportWidth > 0 else { return }
        guard let index = displayedIds.firstIndex(of: id), let placement = run.placement(at: index) else { return }
        if placement.frame.minX < contentOffset {
            contentOffset = placement.frame.minX
        } else if placement.frame.maxX > contentOffset + viewportWidth {
            contentOffset = placement.frame.maxX - viewportWidth
        }
        clampContentOffset()
    }

    internal func beginReorder(of id: UUID) {
        guard reorder == nil else { return }
        reorder = EditorTabReorder(draggedId: id, order: tabIds)
    }

    /// Moves the dragged tab as the pointer passes each neighbour's centre. Returns true when the
    /// order changed, so the caller can animate only then.
    @discardableResult
    internal func updateReorder(toLinearLocation location: CGFloat) -> Bool {
        guard var live = reorder, let currentIndex = live.destinationIndex else { return false }
        let destination = EditorTabReorderResolver.settledDestination(
            forLocation: location,
            tabWidth: run.tabWidth,
            currentIndex: currentIndex,
            count: live.order.count
        )
        guard let destination else { return false }
        live.move(to: destination)
        reorder = live
        return true
    }

    internal func markTearingOff(_ id: UUID?) {
        guard tearingOffTabId != id else { return }
        tearingOffTabId = id
    }

    /// Writes the order to the manager once, on release, or not at all when nothing moved.
    internal func commitReorder() {
        defer { clearReorder() }
        guard let reorder, reorder.movedFromOriginal, let destination = reorder.destinationIndex else { return }
        commands?.moveTab(reorder.draggedId, destination)
    }

    internal func clearReorder() {
        reorder = nil
        tearingOffTabId = nil
    }

    /// A tab that closed under the pointer leaves both orders, and the drag ends outright when the
    /// tab being dragged is the one that went.
    internal func dropClosedTabs(keeping ids: [UUID]) {
        tabIds = ids
        updateRun(trackWidth: trackWidth, count: ids.count)
        guard var live = reorder else { return }
        guard live.removingClosedTabs(keeping: ids), Set(live.order) == Set(ids) else {
            clearReorder()
            return
        }
        reorder = live
    }
}

/// Everything the strip can ask the app to do, in one place, so the AppKit view that owns the
/// pointer never reaches into a view model of its own.
internal struct EditorTabCommands {
    internal let activate: (UUID) -> Void
    internal let keepOpen: (UUID) -> Void
    internal let canKeepOpen: (UUID) -> Bool
    internal let close: (UUID) -> Void
    internal let closeOthers: (UUID) -> Void
    internal let closeAll: () -> Void
    internal let moveTab: (UUID, Int) -> Void
    internal let canMove: (UUID, Int) -> Bool
    internal let moveBy: (UUID, Int) -> Void
    internal let tearOff: (UUID) -> Void
    internal let canTearOff: (UUID) -> Bool
    /// The pointer's owner sets the view's tooltip from this, because the tab's own `.help` never
    /// sees a mouse now.
    internal let tooltip: (UUID) -> String
}
