//
//  DataGridHeaderTypeLine.swift
//  TablePro
//

import AppKit
import TableProTheme

// The second line of a column heading: the type in the engine's own spelling, led by its category's glyph.
@MainActor
struct DataGridHeaderTypeLine {
    let text: String
    let category: ColumnTypeCategory

    // The category comes from the result's type, which the grid reads its values as, and from the definition only when
    // the result named no type.
    init?(_ type: ColumnType?, declaredType: String? = nil) {
        guard let text = Self.typeName(of: type, declaredType: declaredType) else { return nil }
        self.text = text
        if let type {
            category = ColumnTypeCategory(type)
        } else {
            category = ColumnTypeCategory(ColumnTypeClassifier().classify(rawTypeName: text))
        }
    }

    // The table's definition in its own casing (`int unsigned`, `decimal(12,2)`), else the engine's spelling of the
    // result's type (`varchar(255)`), else the app's name for the type.
    static func typeName(of type: ColumnType?, declaredType: String? = nil) -> String? {
        if let declared = declaredType?.trimmingCharacters(in: .whitespacesAndNewlines), !declared.isEmpty {
            return declared
        }
        guard let type else { return nil }
        if let raw = type.rawType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        return type.displayName
    }

    // MARK: - Metrics

    static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
    static let lineHeight = (font.ascender - font.descender).rounded(.up)
    // AppKit starts the title's ink 3 pt into its interior band (measured on macOS 27), so the glyph lines up under it.
    static let leadingInset: CGFloat = 3
    static let glyphSpacing: CGFloat = 3
    // Room for the divider and the gap before it.
    static let trailingInset: CGFloat = 4
    static let glyphPointSize: CGFloat = 9

    // The width the line needs inside its cell, insets included.
    var width: CGFloat {
        let textWidth = (text as NSString).size(withAttributes: [.font: Self.font]).width
        let glyphWidth = Self.glyphWidth(category)
        let glyphRun = glyphWidth > 0 ? glyphWidth + Self.glyphSpacing : 0
        return (Self.leadingInset + glyphRun + textWidth + Self.trailingInset).rounded(.up)
    }

    // The glyph is dropped before the text is when the column is too narrow for both.
    func draw(in rect: NSRect, color: NSColor) {
        let font = Self.font
        let limit = rect.maxX - Self.trailingInset
        var x = rect.minX + Self.leadingInset
        guard x < limit else { return }
        if let glyph = Self.glyph(category, color: color), x + glyph.size.width <= limit {
            let size = glyph.size
            let capMidY = rect.minY + font.ascender - font.capHeight / 2
            let glyphRect = NSRect(x: x, y: capMidY - size.height / 2, width: size.width, height: size.height)
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += size.width + Self.glyphSpacing
        }
        guard x < limit else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textRect = NSRect(x: x, y: rect.minY, width: limit - x, height: rect.height)
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    // MARK: - Glyph

    private static var glyphWidths: [ColumnTypeCategory: CGFloat] = [:]

    static func glyphWidth(_ category: ColumnTypeCategory) -> CGFloat {
        if let width = glyphWidths[category] { return width }
        let width = glyph(category, color: nil)?.size.width ?? 0
        glyphWidths[category] = width
        return width
    }

    // A symbol image keeps the color it was built with, so it takes the line's color here.
    static func glyph(_ category: ColumnTypeCategory, color: NSColor?) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .regular)
        if let color {
            configuration = configuration.applying(.init(hierarchicalColor: color))
        }
        return NSImage(systemSymbolName: category.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    // Secondary to the title: the theme's header text faded where a theme sets it, else the system's secondary label.
    static func color(in scope: ThemeScope) -> NSColor {
        let resolved = scope.resolved
        guard resolved.isOverridden(.gridHeaderText) else { return .secondaryLabelColor }
        return resolved[.gridHeaderText].withAlphaComponent(secondaryAlpha)
    }

    static let secondaryAlpha: CGFloat = 0.6
}

extension ColumnTypeCategory {
    // SF Symbols that ship with macOS 11, below the deployment target.
    var symbolName: String {
        switch self {
        case .text: return "textformat.abc"
        case .number: return "textformat.123"
        case .dateTime: return "calendar"
        case .boolean: return "checkmark.square"
        case .binary: return "doc"
        case .document: return "curlybraces"
        case .spatial: return "mappin.and.ellipse"
        case .other: return "square.on.circle"
        }
    }
}
