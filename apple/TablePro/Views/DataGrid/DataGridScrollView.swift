//
//  DataGridScrollView.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridScrollView: NSScrollView {
    let paneKind: DataGridPane.Kind
    var onTile: (() -> Void)?
    // The frozen pane hands every wheel event to the main pane, so one momentum engine moves both.
    weak var wheelTarget: NSScrollView?
    private var wheelRouting = DataGridWheelRouting()

    // The page the grid sits in scrolls vertically for it, so the main pane keeps only its sideways scroll.
    var fitsRows = false {
        didSet {
            guard fitsRows != oldValue, paneKind == .main else { return }
            hasVerticalScroller = !fitsRows
            verticalScrollElasticity = fitsRows ? .none : .automatic
        }
    }

    init(kind: DataGridPane.Kind) {
        paneKind = kind
        super.init(frame: .zero)
        borderType = .noBorder
        autohidesScrollers = true
        contentView.wantsLayer = true
        contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        contentView.postsBoundsChangedNotifications = true
        switch kind {
        case .main:
            hasVerticalScroller = true
            hasHorizontalScroller = true
        case .frozen:
            hasVerticalScroller = false
            hasHorizontalScroller = false
            horizontalScrollElasticity = .none
            setAccessibilityElement(false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tile() {
        super.tile()
        onTile?()
    }

    override func scrollWheel(with event: NSEvent) {
        if let wheelTarget {
            wheelTarget.scrollWheel(with: event)
            return
        }
        if fitsRows, let page = superview?.enclosingScrollView {
            let axis = wheelRouting.axis(
                phase: event.phase,
                momentumPhase: event.momentumPhase,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY
            )
            if axis == .vertical {
                page.scrollWheel(with: event)
                return
            }
        }
        super.scrollWheel(with: event)
    }

    // The frozen pane repeats cells the main table already publishes, so VoiceOver sees one table.
    override func accessibilityChildren() -> [Any]? {
        paneKind == .frozen ? [] : super.accessibilityChildren()
    }

    var legacyHorizontalScrollerHeight: CGFloat {
        guard scrollerStyle == .legacy, hasHorizontalScroller,
              let scroller = horizontalScroller, !scroller.isHidden else { return 0 }
        return scroller.frame.height
    }
}

// One axis per trackpad gesture, momentum included, so a swipe never splits between the grid and its page.
// A wheel with no phases is a mouse, and each notch decides alone.
struct DataGridWheelRouting {
    enum Axis {
        case vertical
        case horizontal
    }

    private var gestureAxis: Axis?

    mutating func axis(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat) -> Axis {
        if phase.isEmpty, momentumPhase.isEmpty {
            return Self.axis(deltaX: deltaX, deltaY: deltaY) ?? .vertical
        }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            gestureAxis = Self.axis(deltaX: deltaX, deltaY: deltaY)
        } else if gestureAxis == nil, !phase.isEmpty {
            // A gesture can begin with no movement; its first move decides.
            gestureAxis = Self.axis(deltaX: deltaX, deltaY: deltaY)
        }
        return gestureAxis ?? .vertical
    }

    static func axis(deltaX: CGFloat, deltaY: CGFloat) -> Axis? {
        guard deltaX != 0 || deltaY != 0 else { return nil }
        return abs(deltaY) >= abs(deltaX) ? .vertical : .horizontal
    }
}
