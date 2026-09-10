//
//  DataGridCellAccessoryGlyph.swift
//  TablePro
//

import AppKit

/// The symbol a cell draws at its trailing edge, rasterised once per appearance.
///
/// Shared by every cell in the grid, so the cache is static: the glyph depends on the role and the
/// appearance it is drawn into, never on which cell asked for it.
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

        /// The bare arrow spends its whole point size on the arrow itself, where the circled variant
        /// spent most of it on the ring, so 14 here would draw an arrow half again as large as the
        /// one it replaced. 12 keeps the ink at 11 x 9 in the 16 x 16 accessory rect, close to the
        /// dropdown chevron's weight and to the 13pt cell text.
        var pointSize: CGFloat {
            switch self {
            case .foreignKeyNormal, .foreignKeyEmphasized:
                return 12
            case .chevronNormal, .chevronEmphasized, .chevronDisabled:
                return 10
            }
        }

        var color: NSColor {
            switch self {
            case .foreignKeyNormal, .chevronNormal:
                return .secondaryLabelColor
            case .foreignKeyEmphasized, .chevronEmphasized:
                return .alternateSelectedControlTextColor
            case .chevronDisabled:
                return .tertiaryLabelColor
            }
        }
    }

    struct Glyph {
        let image: CGImage
        let pointSize: NSSize
    }

    private struct Key: Hashable {
        let role: Role
        let appearance: NSAppearance.Name
        let increasedContrast: Bool
    }

    private static var glyphs: [Key: Glyph] = [:]

    /// Rasterizing resolves the dynamic symbol color, so a cached bitmap belongs to exactly one
    /// appearance. Keying on the appearance is what keeps a dark window from being served the
    /// light bitmap, and `NSAppearance.currentDrawing()` only reports the drawing appearance while
    /// AppKit is inside `draw(_:)`, `updateLayer` or `layout`.
    static func image(for role: Role) -> Glyph? {
        let key = Key(
            role: role,
            appearance: NSAppearance.currentDrawing().name,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        if let cached = glyphs[key] { return cached }
        guard let glyph = make(role) else { return nil }
        glyphs[key] = glyph
        return glyph
    }

    private static func make(_ role: Role) -> Glyph? {
        let config = NSImage.SymbolConfiguration(pointSize: role.pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: role.color))
        guard let image = NSImage(systemSymbolName: role.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return Glyph(image: cgImage, pointSize: image.size)
    }

    /// A symbol stretched to fill the accessory rect stops looking like a system symbol, so the
    /// glyph draws at its own point size and the rect only ever clamps it. The clamp is one factor
    /// across both axes, because clamping each axis on its own would distort the glyph exactly the
    /// way filling the rect did. The origin rounds to whole points so a glyph narrower than its rect
    /// by an odd number of points does not land on a half point and blur at 1x.
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
