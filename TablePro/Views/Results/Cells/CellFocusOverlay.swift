//
//  CellFocusOverlay.swift
//  TablePro
//

import AppKit

final class CellFocusOverlay: NSView {
    enum Style {
        case hidden
        case contrastingBorder
    }

    var style: Style = .hidden {
        didSet {
            guard oldValue != style else { return }
            applyStyle()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !isHidden { applyStyle() }
    }

    private func applyStyle() {
        switch style {
        case .hidden:
            isHidden = true
            layer?.borderWidth = 0
        case .contrastingBorder:
            isHidden = false
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.alternateSelectedControlTextColor.cgColor
        }
    }
}
