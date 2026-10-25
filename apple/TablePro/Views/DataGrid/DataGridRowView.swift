//
//  DataGridRowView.swift
//  TablePro
//

import AppKit
import TableProTheme

// Draws its pane's cells: NSTableView mounts a view for every column of every prepared row, which at 200 columns
// costs 45 ms a frame against 1.5 ms drawn (probe P1).
@MainActor
final class DataGridRowView: NSTableRowView {
    weak var controller: DataGridViewController?
    weak var gridTable: DataGridTableView?

    private let contentView = DataGridRowContentView()

    // The selection mixes AppKit's row emphasis with the grid's own focus rule, so both panes agree (probe P7, critic M4).
    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set {
            let resolved = controller?.gridHasFocus ?? newValue
            guard resolved != super.isEmphasized else { return }
            super.isEmphasized = resolved
            redrawCells()
        }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            redrawCells()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawSubviewsIntoLayer = true
        contentView.rowView = self
        contentView.autoresizingMask = [.width, .height]
        contentView.frame = bounds
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.actions = Self.disabledLayerActions
        return layer
    }

    private static let disabledLayerActions: [String: any CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
    ]

    // Asked of the table rather than remembered: insertRows and removeRows move a row view without asking for it again.
    var rowIndex: Int {
        gridTable?.row(for: self) ?? -1
    }

    func redrawCells() {
        needsDisplay = true
        contentView.needsDisplay = true
    }

    func redrawCells(inTableRect rect: NSRect) {
        guard let gridTable else {
            redrawCells()
            return
        }
        let local = convert(rect, from: gridTable)
        let band = NSRect(x: local.minX, y: bounds.minY, width: local.width, height: bounds.height)
        setNeedsDisplay(band)
        contentView.setNeedsDisplay(band)
    }

    // MARK: - Drawing

    override func drawBackground(in dirtyRect: NSRect) {
        guard let controller, let gridTable else {
            super.drawBackground(in: dirtyRect)
            return
        }
        let row = rowIndex
        let scope = controller.model.themeScope
        DataGridBodyChrome.fillRowBackground(dirtyRect, row: row, of: gridTable, scope: scope)
        if let tint = controller.rowTint(forRow: row) {
            tint.setFill()
            bounds.intersection(dirtyRect).fill(using: .sourceOver)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, let controller, let gridTable else { return }
        let row = rowIndex
        controller.model.themeScope.resolved[isEmphasized ? .gridSelection : .gridInactiveSelection].setFill()
        for rect in controller.selectionRects(forRow: row, in: gridTable, within: convert(dirtyRect, to: gridTable)) {
            let local = convert(rect, from: gridTable)
            let band = NSRect(x: local.minX, y: bounds.minY, width: local.width, height: bounds.height)
            band.intersection(dirtyRect).fill()
        }
    }

    fileprivate func drawContent(in dirtyRect: NSRect, of view: NSView) {
        guard let controller, let gridTable else { return }
        controller.drawCells(ofRow: rowIndex, in: dirtyRect, of: view, table: gridTable, isEmphasized: isEmphasized)
    }

    // MARK: - Hit testing

    // Data cells have no views, so a press goes to the table; a mounted edit field still takes its own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === contentView ? nil : hit
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .row }

    // The row answers for every point no cell covers, so a client never lands on a view outside the tree.
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        DataGridAccessibility.markActive()
        guard let window else { return super.accessibilityHitTest(point) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        for subview in subviews where subview !== contentView && subview.frame.contains(local) {
            if let hit = subview.accessibilityHitTest(point) { return hit }
        }
        return bounds.contains(local) ? self : nil
    }
}

// Its own view so the cells land after the row's background and selection, one view per row whatever the column count.
@MainActor
final class DataGridRowContentView: NSView {
    weak var rowView: DataGridRowView?

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        rowView?.accessibilityHitTest(point) ?? super.accessibilityHitTest(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        rowView?.drawContent(in: dirtyRect, of: self)
    }
}
