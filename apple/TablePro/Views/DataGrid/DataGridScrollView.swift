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
        guard let wheelTarget else {
            super.scrollWheel(with: event)
            return
        }
        wheelTarget.scrollWheel(with: event)
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
