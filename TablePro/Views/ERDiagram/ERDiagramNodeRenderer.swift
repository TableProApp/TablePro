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
    private static let maxTableNameChars = 24
    private static let maxTypeChars = 18
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
        let nameFont = NSFont.monospacedSystemFont(ofSize: columnNamePointSize * scale, weight: .regular)
        let typeFont = NSFont.monospacedSystemFont(ofSize: columnTypePointSize * scale, weight: .regular)

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

            ERDiagramTextRenderer.draw(
                column.name,
                font: nameFont,
                color: .labelColor,
                at: CGPoint(x: rect.minX + columnNameXOffset, y: rowY),
                anchor: .leading,
                in: context
            )

            let displayType = (column.dataType as NSString).length > maxTypeChars
                ? String(column.dataType.prefix(maxTypeChars)) + "\u{2026}"
                : column.dataType
            ERDiagramTextRenderer.draw(
                displayType,
                font: typeFont,
                color: .secondaryLabelColor,
                at: CGPoint(x: rect.maxX - typeRightMargin, y: rowY),
                anchor: .trailing,
                in: context
            )
        }
    }
}
