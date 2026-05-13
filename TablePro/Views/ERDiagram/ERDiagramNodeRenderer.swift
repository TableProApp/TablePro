import AppKit
import SwiftUI

/// Renders table nodes imperatively on a Canvas GraphicsContext.
enum ERDiagramNodeRenderer {
    private static var headerTextXOffset: CGFloat { 28 * ERDiagramLayout.typeScale }
    private static var iconXOffset: CGFloat { 10 * ERDiagramLayout.typeScale }
    private static var badgeXOffset: CGFloat { 14 * ERDiagramLayout.typeScale }
    private static var columnNameXOffset: CGFloat { 24 * ERDiagramLayout.typeScale }
    private static var typeRightMargin: CGFloat { 8 * ERDiagramLayout.typeScale }
    private static let maxTableNameChars = 24
    private static let maxTypeChars = 18

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
        context: inout GraphicsContext,
        node: ERTableNode,
        rect: CGRect,
        isSelected: Bool
    ) {
        let scale = ERDiagramLayout.typeScale
        let cornerRadius: CGFloat = 6
        let roundedRect = RoundedRectangle(cornerRadius: cornerRadius)
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

        // Background
        context.fill(path, with: .color(Color(nsColor: .controlBackgroundColor)))

        // Border
        let borderColor = isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor)
        context.stroke(path, with: .color(borderColor), lineWidth: isSelected ? 2 : 1)

        // Header background
        let headerHeight: CGFloat = ERDiagramLayout.headerHeight
        let headerRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
        let headerPath = Path { p in
            p.addRoundedRect(
                in: headerRect,
                cornerRadii: RectangleCornerRadii(topLeading: cornerRadius, topTrailing: cornerRadius)
            )
        }
        context.fill(headerPath, with: .color(Color.accentColor.opacity(0.15)))

        // Header text
        let displayName = (node.tableName as NSString).length > maxTableNameChars
            ? String(node.tableName.prefix(maxTableNameChars)) + "\u{2026}"
            : node.tableName
        let headerText = Text(displayName)
            .font(.system(size: Self.headerPointSize * scale, weight: .semibold, design: .monospaced))
        context.draw(
            context.resolve(headerText),
            at: CGPoint(x: rect.minX + headerTextXOffset, y: rect.minY + headerHeight / 2),
            anchor: .leading
        )

        // Table icon
        let iconText = Text(Image(systemName: "tablecells"))
            .font(.system(size: Self.iconPointSize * scale))
            .foregroundStyle(.secondary)
        context.draw(
            context.resolve(iconText),
            at: CGPoint(x: rect.minX + iconXOffset, y: rect.minY + headerHeight / 2),
            anchor: .leading
        )

        // Header divider
        let dividerY = rect.minY + headerHeight
        var dividerPath = Path()
        dividerPath.move(to: CGPoint(x: rect.minX, y: dividerY))
        dividerPath.addLine(to: CGPoint(x: rect.maxX, y: dividerY))
        context.stroke(dividerPath, with: .color(Color(nsColor: .tertiaryLabelColor)), lineWidth: 0.5)

        // Column rows — use clipped context to prevent long text overflow
        var clipped = context
        clipped.clip(to: path)
        let rowHeight = ERDiagramLayout.columnRowHeight
        for (idx, col) in node.displayColumns.enumerated() {
            let rowY = dividerY + CGFloat(idx) * rowHeight + rowHeight / 2

            // PK/FK badge
            if col.isPrimaryKey {
                let badge = Text(Image(systemName: "key.fill")).font(.system(size: Self.badgePointSize * scale)).foregroundStyle(Color(nsColor: .systemYellow))
                clipped.draw(clipped.resolve(badge), at: CGPoint(x: rect.minX + badgeXOffset, y: rowY), anchor: .center)
            } else if col.isForeignKey {
                let badge = Text(Image(systemName: "link")).font(.system(size: Self.badgePointSize * scale)).foregroundStyle(Color(nsColor: .systemBlue))
                clipped.draw(clipped.resolve(badge), at: CGPoint(x: rect.minX + badgeXOffset, y: rowY), anchor: .center)
            }

            // Column name
            let nameText = Text(col.name).font(.system(size: Self.columnNamePointSize * scale, design: .monospaced))
            clipped.draw(
                clipped.resolve(nameText),
                at: CGPoint(x: rect.minX + columnNameXOffset, y: rowY),
                anchor: .leading
            )

            // Column type — truncate long types (e.g. enum values) to fit node width
            let displayType = (col.dataType as NSString).length > maxTypeChars
                ? String(col.dataType.prefix(maxTypeChars)) + "\u{2026}"
                : col.dataType
            let typeText = Text(displayType)
                .font(.system(size: Self.columnTypePointSize * scale, design: .monospaced))
                .foregroundStyle(.secondary)
            clipped.draw(
                clipped.resolve(typeText),
                at: CGPoint(x: rect.maxX - typeRightMargin, y: rowY),
                anchor: .trailing
            )
        }
    }
}
