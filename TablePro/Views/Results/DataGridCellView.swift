//
//  DataGridCellView.swift
//  TablePro
//

import AppKit

class DataGridCellView: NSTableCellView {
    var fkArrowButton: FKArrowButton?
    var chevronButton: CellChevronButton?
    var textFieldTrailing: NSLayoutConstraint?

    var isFocusedCell: Bool = false {
        didSet {
            guard oldValue != isFocusedCell else { return }
            noteFocusRingMaskChanged()
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
        }
    }

    override var focusRingMaskBounds: NSRect {
        isFocusedCell ? bounds : .zero
    }

    override func drawFocusRingMask() {
        guard isFocusedCell else { return }
        bounds.fill()
    }
}
