//
//  HighlightColor+AppKit.swift
//  TablePro
//

import AppKit

extension HighlightColor {
    static let washAlpha: CGFloat = 0.2

    var systemColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    var washColor: NSColor {
        systemColor.withAlphaComponent(Self.washAlpha)
    }

    func swatchImage(diameter: CGFloat = 12) -> NSImage {
        let color = systemColor
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.separatorColor.setStroke()
            let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 0.5
            outline.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = displayName
        return image
    }
}
