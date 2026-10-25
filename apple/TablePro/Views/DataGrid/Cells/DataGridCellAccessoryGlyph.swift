//
//  DataGridCellAccessoryGlyph.swift
//  TablePro
//

import AppKit

// Rasterised once per role and appearance, shared by every cell in every grid.
@MainActor
enum DataGridCellAccessoryGlyph {
    enum Role: Hashable {
        case foreignKeyNormal
        case foreignKeyEmphasized
        case chevronNormal
        case chevronEmphasized
        case chevronDisabled

        init?(accessory: DataGridCellAccessory, isEmphasized: Bool, isDisabled: Bool) {
            switch accessory {
            case .none:
                return nil
            case .foreignKey:
                self = isEmphasized ? .foreignKeyEmphasized : .foreignKeyNormal
            case .chevron:
                if isDisabled {
                    self = .chevronDisabled
                } else {
                    self = isEmphasized ? .chevronEmphasized : .chevronNormal
                }
            }
        }

        var symbolName: String {
            switch self {
            case .foreignKeyNormal, .foreignKeyEmphasized:
                return "arrow.forward"
            case .chevronNormal, .chevronEmphasized, .chevronDisabled:
                return "chevron.up.chevron.down"
            }
        }

        var pointSize: CGFloat {
            switch self {
            case .foreignKeyNormal, .foreignKeyEmphasized:
                return 12
            case .chevronNormal, .chevronEmphasized, .chevronDisabled:
                return 10
            }
        }

        func color(selectionText: NSColor) -> NSColor {
            switch self {
            case .foreignKeyNormal, .chevronNormal:
                return .secondaryLabelColor
            case .foreignKeyEmphasized, .chevronEmphasized:
                return selectionText
            case .chevronDisabled:
                return .tertiaryLabelColor
            }
        }
    }

    struct Glyph {
        let image: CGImage
        let pointSize: NSSize
        // Held so the color cannot be freed and its address reused while the bitmap is cached.
        fileprivate let color: NSColor
    }

    private struct Key: Hashable {
        let role: Role
        let appearance: NSAppearance.Name
        let increasedContrast: Bool
    }

    private static var glyphs: [Key: Glyph] = [:]
    private static var glyphsRevision: Int?

    // NSAppearance.currentDrawing() names the drawing appearance only inside draw, updateLayer or layout.
    static func image(for role: Role, color: NSColor) -> Glyph? {
        let revision = ThemeEngine.shared.revision
        if glyphsRevision != revision {
            glyphs.removeAll()
            glyphsRevision = revision
        }
        let key = Key(
            role: role,
            appearance: NSAppearance.currentDrawing().name,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        if let cached = glyphs[key], cached.color === color { return cached }
        guard let glyph = make(role, color: color) else { return nil }
        glyphs[key] = glyph
        return glyph
    }

    private static func make(_ role: Role, color: NSColor) -> Glyph? {
        let config = NSImage.SymbolConfiguration(pointSize: role.pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        guard let image = NSImage(systemSymbolName: role.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return Glyph(image: cgImage, pointSize: image.size, color: color)
    }

    // Drawn at its own point size and only ever shrunk, by one factor on both axes, onto whole points.
    static func centeredRect(pointSize: NSSize, in rect: NSRect) -> NSRect {
        let scale = min(1, rect.width / pointSize.width, rect.height / pointSize.height)
        let size = NSSize(width: pointSize.width * scale, height: pointSize.height * scale)
        return NSRect(
            x: (rect.midX - size.width / 2).rounded(),
            y: (rect.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}
