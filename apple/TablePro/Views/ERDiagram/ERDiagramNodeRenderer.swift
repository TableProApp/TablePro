import AppKit

// AppKit draws a plain view at every magnification, which a SwiftUI `Canvas` did not (#2692).
@MainActor
enum ERDiagramNodeRenderer {
    private static var headerTextXOffset: CGFloat { 28 * ERDiagramLayout.typeScale }
    private static var iconXOffset: CGFloat { 10 * ERDiagramLayout.typeScale }
    private static var badgeXOffset: CGFloat { 14 * ERDiagramLayout.typeScale }
    private static var columnNameXOffset: CGFloat { 24 * ERDiagramLayout.typeScale }
    private static var typeRightMargin: CGFloat { 8 * ERDiagramLayout.typeScale }
    private static var nameTypeGap: CGFloat { 8 * ERDiagramLayout.typeScale }
    // Enough of a type stays readable beside a long name: "varchar" or "timestam".
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
        palette: ERDiagramPalette,
        on canvas: some ERDiagramCanvas
    ) {
        let scale = ERDiagramLayout.typeScale
        let body = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        canvas.fill(body, color: palette.nodeFill)

        let headerHeight = ERDiagramLayout.headerHeight
        let headerRect = CGPath(
            rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight),
            transform: nil
        )

        canvas.clip(to: body) {
            if let headerFill = palette.headerFill {
                canvas.fill(headerRect, color: headerFill)
            }
            // A cluster's hue groups related tables, so it still washes a themed header.
            if palette.headerFill == nil || clusterColor != nil {
                canvas.fill(headerRect, color: palette.headerWash(cluster: clusterColor))
            }
        }

        canvas.stroke(
            body,
            color: isSelected ? palette.selectionRule : palette.rule,
            lineWidth: isSelected ? 2 : 1,
            rounded: false
        )

        let displayName = (node.tableName as NSString).length > maxTableNameChars
            ? String(node.tableName.prefix(maxTableNameChars)) + "\u{2026}"
            : node.tableName
        canvas.drawText(
            displayName,
            font: .monospacedSystemFont(ofSize: headerPointSize * scale, weight: .semibold),
            color: palette.headerText,
            at: CGPoint(x: rect.minX + headerTextXOffset, y: rect.minY + headerHeight / 2),
            anchor: .leading
        )

        canvas.drawSymbol(
            named: node.isJunctionTable ? "arrow.left.arrow.right" : "tablecells",
            pointSize: iconPointSize * scale,
            color: palette.secondaryText,
            at: CGPoint(x: rect.minX + iconXOffset, y: rect.minY + headerHeight / 2),
            anchor: .leading
        )

        let dividerY = rect.minY + headerHeight
        let divider = CGMutablePath()
        divider.move(to: CGPoint(x: rect.minX, y: dividerY))
        divider.addLine(to: CGPoint(x: rect.maxX, y: dividerY))
        canvas.stroke(divider, color: palette.rule, lineWidth: 0.5, rounded: false)

        canvas.clip(to: body) {
            drawColumns(node: node, rect: rect, dividerY: dividerY, scale: scale, palette: palette, on: canvas)
        }
    }

    private static func drawColumns(
        node: ERTableNode,
        rect: CGRect,
        dividerY: CGFloat,
        scale: CGFloat,
        palette: ERDiagramPalette,
        on canvas: some ERDiagramCanvas
    ) {
        let rowHeight = ERDiagramLayout.columnRowHeight
        let nameFont = columnNameFont(scale: scale)
        let typeFont = columnTypeFont(scale: scale)

        for (index, column) in node.displayColumns.enumerated() {
            let rowY = dividerY + CGFloat(index) * rowHeight + rowHeight / 2

            if let fill = stagedFill(column.stagedEdit, palette: palette) {
                let row = CGRect(x: rect.minX, y: dividerY + CGFloat(index) * rowHeight, width: rect.width, height: rowHeight)
                canvas.fill(CGPath(rect: row, transform: nil), color: fill)
            }

            if column.isPrimaryKey {
                canvas.drawSymbol(
                    named: "key.fill",
                    pointSize: badgePointSize * scale,
                    color: .systemYellow,
                    at: CGPoint(x: rect.minX + badgeXOffset, y: rowY),
                    anchor: .center
                )
            } else if column.isForeignKey {
                canvas.drawSymbol(
                    named: "link",
                    pointSize: badgePointSize * scale,
                    color: .systemBlue,
                    at: CGPoint(x: rect.minX + badgeXOffset, y: rowY),
                    anchor: .center
                )
            }

            let widths = columnTextWidths(name: column.name, type: column.dataType, nodeWidth: rect.width)
            let isDropped = column.stagedEdit == .dropped
            canvas.drawText(
                column.name,
                font: nameFont,
                color: isDropped ? palette.deletedText : palette.text,
                at: CGPoint(x: rect.minX + columnNameXOffset, y: rowY),
                anchor: .leading,
                maxWidth: widths.name
            )
            // The strike says "dropped" where the row tint alone would rely on color.
            if isDropped {
                let strike = CGMutablePath()
                strike.move(to: CGPoint(x: rect.minX + columnNameXOffset, y: rowY))
                strike.addLine(to: CGPoint(x: rect.minX + columnNameXOffset + widths.name, y: rowY))
                canvas.stroke(strike, color: palette.droppedEdge, lineWidth: 1, rounded: false)
            }

            canvas.drawText(
                column.dataType,
                font: typeFont,
                color: palette.secondaryText,
                at: CGPoint(x: rect.maxX - typeRightMargin, y: rowY),
                anchor: .trailing,
                maxWidth: widths.type
            )
        }
    }

    private static func stagedFill(_ edit: ERStagedEdit?, palette: ERDiagramPalette) -> CGColor? {
        switch edit {
        case .added: palette.insertedRow
        case .modified: palette.modifiedRow
        case .dropped: palette.deletedRow
        case nil: nil
        }
    }

    private static func columnNameFont(scale: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: columnNamePointSize * scale, weight: .regular)
    }

    private static func columnTypeFont(scale: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: columnTypePointSize * scale, weight: .regular)
    }

    // The name comes first but leaves the type its first few characters.
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

// Neither width exceeds its text's own width, and the two plus the gap never exceed the room.
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
