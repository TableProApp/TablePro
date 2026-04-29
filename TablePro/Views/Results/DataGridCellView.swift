//
//  DataGridCellView.swift
//  TablePro
//

import AppKit

final class DataGridCellView: NSTableCellView {
    var fkArrowButton: FKArrowButton?
    var chevronButton: CellChevronButton?
    var textFieldTrailing: NSLayoutConstraint?

    var isFocusedCell: Bool = false {
        didSet {
            guard oldValue != isFocusedCell else { return }
            updateFocusRing()
        }
    }

    private lazy var backgroundView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: subviews.first)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return view
    }()

    var changeBackgroundColor: NSColor? {
        didSet {
            if let color = changeBackgroundColor {
                backgroundView.layer?.backgroundColor = color.cgColor
                backgroundView.isHidden = (backgroundStyle == .emphasized)
            } else {
                backgroundView.layer?.backgroundColor = nil
                backgroundView.isHidden = true
            }
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            backgroundView.isHidden = (backgroundStyle == .emphasized) || (changeBackgroundColor == nil)
            if isFocusedCell { updateFocusRing() }
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(rect: bounds).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isFocusedCell, backgroundStyle != .emphasized else { return }
        NSGraphicsContext.saveGraphicsState()
        NSFocusRingPlacement.only.set()
        drawFocusRingMask()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isFocusedCell {
            needsDisplay = true
        }
    }

    private func updateFocusRing() {
        focusRingType = isFocusedCell ? .exterior : .none
        noteFocusRingMaskChanged()
        needsDisplay = true
    }
}
