import AppKit

/// Renders table nodes with CoreGraphics into the current flipped drawing context.
///
/// This used to draw into a SwiftUI `Canvas`. A `Canvas` cannot be the drawing surface of a
/// magnifying `NSScrollView`: below 50% magnification SwiftUI truncates the Canvas's own drawing
/// region to `contentSize * magnification + 128` document points and paints nothing past it, which
/// is what left the diagram half painted at its fit-to-window zoom (#2692). AppKit draws a plain
/// view at every scale, so the diagram owns its pixels the way the data grid owns its cells.
@MainActor
enum ERDiagramNodeRenderer {
    private static var headerTextXOffset: CGFloat { 28 * ERDiagramLayout.typeScale }
    private static var iconXOffset: CGFloat { 10 * ERDiagramLayout.typeScale }
    private static var badgeXOffset: CGFloat { 14 * ERDiagramLayout.typeScale }
    private static var columnNameXOffset: CGFloat { 24 * ERDiagramLayout.typeScale }
    private static var typeRightMargin: CGFloat { 8 * ERDiagramLayout.typeScale }
    private static var nameTypeGap: CGFloat { 8 * ERDiagramLayout.typeScale }
    /// How much of a type stays readable beside a long name: enough for "varchar" or "timestam".
    private static let typeFloorCharacters = 8
    private static let maxTableNameChars = 24
    private static let cornerRadius: CGFloat = 6

    private static var headerPointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .caption1).pointSize
    }

    private static var iconPointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .caption2).pointSize
    }

    private static var badgePointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .caption2).pointSize * 0.75
    }

    private static var columnNamePointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .caption1).pointSize * (11.0 / 12.0)
    }

    private static var columnTypePointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .caption2).pointSize
    }

    static func drawNode(
        node: ERTableNode,
        rect: CGRect,
        isSelected: Bool,
        clusterColor: NSColor?,
        in context: CGContext
    ) {
        let scale = ERDiagramLayout.typeScale
        let body = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        context.addPath(body)
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fillPath()

        let headerHeight = ERDiagramLayout.headerHeight
        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
        let headerTint = clusterColor ?? NSColor.controlAccentColor

        context.saveGState()
        context.addPath(body)
        context.clip()
        context.setFillColor(headerTint.withAlphaComponent(clusterColor == nil ? 0.15 : 0.22).cgColor)
        context.fill(headerRect)
        context.restoreGState()

        context.addPath(body)
        context.setStrokeColor((isSelected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor)
        context.setLineWidth(isSelected ? 2 : 1)
        context.strokePath()

        let displayName = (node.tableName as NSString).length > maxTableNameChars
            ? String(node.tableName.prefix(maxTableNameChars)) + "\u{2026}"
            : node.tableName
        ERDiagramTextRenderer.draw(
            displayName,
            font: .monospacedSystemFont(ofSize: headerPointSize * scale, weight: .semibold),
            color: .labelColor,
            at: CGPoint(x: rect.minX + headerTextXOffset, y: rect.minY + headerHeight / 2),
            anchor: .leading,
            in: context
        )

        ERDiagramSymbolRenderer.draw(
            named: node.isJunctionTable ? "arrow.left.arrow.right" : "tablecells",
            pointSize: iconPointSize * scale,
            color: .secondaryLabelColor,
            at: CGPoint(x: rect.minX + iconXOffset, y: rect.minY + headerHeight / 2),
            anchor: .leading
        )

        let dividerY = rect.minY + headerHeight
        context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: rect.minX, y: dividerY))
        context.addLine(to: CGPoint(x: rect.maxX, y: dividerY))
        context.strokePath()

        context.saveGState()
        context.addPath(body)
        context.clip()
        drawColumns(node: node, rect: rect, dividerY: dividerY, scale: scale, in: context)
        context.restoreGState()
    }

    private static func drawColumns(
        node: ERTableNode,
        rect: CGRect,
        dividerY: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        let rowHeight = ERDiagramLayout.columnRowHeight
        let nameFont = columnNameFont(scale: scale)
        let typeFont = columnTypeFont(scale: scale)

        for (index, column) in node.displayColumns.enumerated() {
            let rowY = dividerY + CGFloat(index) * rowHeight + rowHeight / 2

            if column.isPrimaryKey {
                ERDiagramSymbolRenderer.draw(
                    named: "key.fill",
                    pointSize: badgePointSize * scale,
                    color: .systemYellow,
                    at: CGPoint(x: rect.minX + badgeXOffset, y: rowY),
                    anchor: .center
                )
            } else if column.isForeignKey {
                ERDiagramSymbolRenderer.draw(
                    named: "link",
                    pointSize: badgePointSize * scale,
                    color: .systemBlue,
                    at: CGPoint(x: rect.minX + badgeXOffset, y: rowY),
                    anchor: .center
                )
            }

            let widths = columnTextWidths(name: column.name, type: column.dataType, nodeWidth: rect.width)
            ERDiagramTextRenderer.draw(
                column.name,
                font: nameFont,
                color: .labelColor,
                at: CGPoint(x: rect.minX + columnNameXOffset, y: rowY),
                anchor: .leading,
                maxWidth: widths.name,
                in: context
            )

            ERDiagramTextRenderer.draw(
                column.dataType,
                font: typeFont,
                color: .secondaryLabelColor,
                at: CGPoint(x: rect.maxX - typeRightMargin, y: rowY),
                anchor: .trailing,
                maxWidth: widths.type,
                in: context
            )
        }
    }

    private static func columnNameFont(scale: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: columnNamePointSize * scale, weight: .regular)
    }

    private static func columnTypeFont(scale: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: columnTypePointSize * scale, weight: .regular)
    }

    /// The widths a column row draws its name and type at, measured in the fonts the row uses.
    ///
    /// The name is drawn from the leading edge and the type to the trailing edge, so nothing kept
    /// the two apart: a long name ran under its type ("shipping_addr" over "character varying(…").
    /// They now share the row. The name comes first, because it is what a reader is looking for,
    /// but it leaves the type at least its first few characters; the type then takes what is left.
    static func columnTextWidths(name: String, type: String, nodeWidth: CGFloat) -> ERColumnTextWidths {
        let scale = ERDiagramLayout.typeScale
        let typeFont = columnTypeFont(scale: scale)
        let typeFloor = ERDiagramTextRenderer.width(
            of: String(repeating: "0", count: typeFloorCharacters), font: typeFont
        )
        return ERColumnTextWidths(
            room: nodeWidth - columnNameXOffset - typeRightMargin,
            gap: nameTypeGap,
            name: ERDiagramTextRenderer.width(of: name, font: columnNameFont(scale: scale)),
            type: ERDiagramTextRenderer.width(of: type, font: typeFont),
            typeFloor: typeFloor
        )
    }
}

/// How one column row shares its room between the name and the type. Each width is the most that
/// text may draw at; neither ever exceeds the text's own width, and the two plus the gap between
/// them never exceed the room.
struct ERColumnTextWidths: Equatable {
    let name: CGFloat
    let type: CGFloat

    init(room: CGFloat, gap: CGFloat, name: CGFloat, type: CGFloat, typeFloor: CGFloat) {
        let separation = type > 0 ? gap : 0
        let nameRoom = max(0, room - separation - min(type, typeFloor))
        self.name = min(name, nameRoom)
        self.type = min(type, max(0, room - separation - self.name))
    }
}
