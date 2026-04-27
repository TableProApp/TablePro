//
//  DataGridCellView.swift
//  TablePro
//

import AppKit

/// Custom cell view that uses a background subview for change-state coloring.
/// AppKit's `NSTableRowView` sets `backgroundStyle` to `.emphasized` when the
/// row is selected — we hide the background view so the native selection highlight
/// shows through.
final class DataGridCellView: NSTableCellView {
    var fkArrowButton: FKArrowButton?
    var chevronButton: CellChevronButton?
    var textFieldTrailing: NSLayoutConstraint?

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
}
