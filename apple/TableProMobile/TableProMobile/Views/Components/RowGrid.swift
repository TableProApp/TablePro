import SwiftUI
import TableProModels
import UIKit

nonisolated struct RowGridMetrics: Equatable, Sendable {
    var minimumWidth: CGFloat
    var maximumWidth: CGFloat
    var horizontalPadding: CGFloat
}

nonisolated struct RowGridLayout: Equatable, Sendable {
    static let sampledRowCount = 50
    // Past this many characters even the narrowest glyphs overflow the widest column.
    static let maximumMeasuredCharacters = 128

    let order: [Int]
    let widths: [CGFloat]

    var totalWidth: CGFloat { widths.reduce(0, +) }

    static func make(
        columnNames: [String],
        rows: some Collection<[String?]>,
        keyColumn: Int?,
        metrics: RowGridMetrics,
        measure: (_ text: String, _ isHeader: Bool) -> CGFloat
    ) -> RowGridLayout {
        let order = displayOrder(columnCount: columnNames.count, keyColumn: keyColumn)
        let sample = rows.prefix(sampledRowCount)
        let widestText = metrics.maximumWidth - metrics.horizontalPadding * 2
        let widths = order.map { column in
            var widest = measure(measuredText(columnNames[column]), true)
            for row in sample where widest < widestText {
                let value = row.indices.contains(column) ? row[column] : nil
                widest = max(widest, measure(measuredText(value ?? "NULL"), false))
            }
            let width = widest.rounded(.up) + metrics.horizontalPadding * 2
            return min(max(width, metrics.minimumWidth), metrics.maximumWidth)
        }
        return RowGridLayout(order: order, widths: widths)
    }

    static func displayOrder(columnCount: Int, keyColumn: Int?) -> [Int] {
        let columns = Array(0..<columnCount)
        guard let keyColumn, columns.contains(keyColumn) else { return columns }
        return [keyColumn] + columns.filter { $0 != keyColumn }
    }

    // A cell shows one line, and a value that continues past it ends in an ellipsis.
    static func measuredText(_ text: String) -> String {
        var end = text.startIndex
        var count = 0
        while end < text.endIndex, count < maximumMeasuredCharacters, !text[end].isNewline {
            text.formIndex(after: &end)
            count += 1
        }
        let measured = String(text[..<end])
        return end < text.endIndex ? measured + "…" : measured
    }
}

struct RowGridTextMeasure {
    let cellFont: UIFont
    let headerFont: UIFont

    init(dynamicTypeSize: DynamicTypeSize) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        cellFont = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        headerFont = UIFont.systemFont(ofSize: cellFont.pointSize, weight: .semibold)
    }

    func width(of text: String, isHeader: Bool) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: isHeader ? headerFont : cellFont]).width
    }
}

nonisolated struct RowGridViewport: Equatable, Sendable {
    let width: CGFloat
    let leadingInset: CGFloat
}

struct RowGrid<Row: View>: View {
    let columns: [ColumnInfo]
    let rows: [[String?]]
    let keyColumn: Int?
    @ViewBuilder let row: (_ index: Int, _ line: RowGridLine) -> Row

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .subheadline) private var minimumWidth: CGFloat = 72
    @ScaledMetric(relativeTo: .subheadline) private var maximumWidth: CGFloat = 320
    @ScaledMetric(relativeTo: .subheadline) private var horizontalPadding: CGFloat = 12
    @ScaledMetric(relativeTo: .subheadline) private var verticalPadding: CGFloat = 10
    @State private var layout: RowGridLayout?
    @State private var viewport = RowGridViewport(width: 0, leadingInset: 0)

    private var layoutKey: LayoutKey {
        LayoutKey(
            columnNames: columns.map(\.name),
            sample: rows.prefix(RowGridLayout.sampledRowCount),
            keyColumn: keyColumn,
            dynamicTypeSize: dynamicTypeSize,
            metrics: RowGridMetrics(
                minimumWidth: minimumWidth, maximumWidth: maximumWidth, horizontalPadding: horizontalPadding
            )
        )
    }

    private var style: RowGridLine.Style {
        RowGridLine.Style(
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            hairline: HairlineThickness.points(forDisplayScale: displayScale),
            pinnedInset: viewport.leadingInset
        )
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            // For one pass after the columns change, the layout still describes the old ones.
            if let layout, layout.order.count == columns.count {
                grid(layout, width: max(layout.totalWidth, viewport.width))
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .buttonStyle(.plain)
        .onGeometryChange(for: RowGridViewport.self) { proxy in
            RowGridViewport(
                width: proxy.size.width - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing,
                leadingInset: proxy.safeAreaInsets.leading
            )
        } action: { viewport = $0 }
        // Reads only the key: the closure's other captures belong to the previous body.
        .onChange(of: layoutKey, initial: true) { _, key in
            let measure = RowGridTextMeasure(dynamicTypeSize: key.dynamicTypeSize)
            layout = RowGridLayout.make(
                columnNames: key.columnNames,
                rows: key.sample,
                keyColumn: key.keyColumn,
                metrics: key.metrics,
                measure: measure.width(of:isHeader:)
            )
        }
    }

    private func grid(_ layout: RowGridLayout, width: CGFloat) -> some View {
        let style = style
        return LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(IndexedRow.wrap(rows)) { item in
                    row(item.id, RowGridLine(
                        columns: columns, values: item.values, layout: layout, width: width, style: style
                    ))
                }
            } header: {
                header(layout, width: width, style: style)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func header(_ layout: RowGridLayout, width: CGFloat, style: RowGridLine.Style) -> some View {
        HStack(spacing: 0) {
            ForEach(layout.order.indices, id: \.self) { position in
                Text(verbatim: columns[layout.order[position]].name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, style.horizontalPadding)
                    .padding(.vertical, style.verticalPadding)
                    .frame(width: layout.widths[position], alignment: .leading)
                    .modifier(RowGridCell(isPinned: position == 0, style: style))
            }
        }
        .frame(width: width, alignment: .leading)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: style.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private struct LayoutKey: Equatable {
        let columnNames: [String]
        let sample: ArraySlice<[String?]>
        let keyColumn: Int?
        let dynamicTypeSize: DynamicTypeSize
        let metrics: RowGridMetrics
    }
}

struct RowGridLine: View {
    struct Style {
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let hairline: CGFloat
        let pinnedInset: CGFloat
    }

    let columns: [ColumnInfo]
    let values: [String?]
    let layout: RowGridLayout
    let width: CGFloat
    let style: Style

    var body: some View {
        HStack(spacing: 0) {
            ForEach(layout.order.indices, id: \.self) { position in
                cell(value(at: layout.order[position]))
                    .frame(width: layout.widths[position], alignment: .leading)
                    .modifier(RowGridCell(isPinned: position == 0, style: style))
            }
        }
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: style.hairline)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private func value(at column: Int) -> String? {
        values.indices.contains(column) ? values[column] : nil
    }

    private var accessibilityText: String {
        layout.order
            .filter { columns.indices.contains($0) }
            .map { "\(columns[$0].name), \(value(at: $0) ?? "NULL")" }
            .joined(separator: ", ")
    }

    private func cell(_ value: String?) -> some View {
        Group {
            if let value {
                Text(verbatim: value)
            } else {
                Text(verbatim: "NULL")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, style.horizontalPadding)
        .padding(.vertical, style.verticalPadding)
    }
}

private struct RowGridCell: ViewModifier {
    let isPinned: Bool
    let style: RowGridLine.Style

    func body(content: Content) -> some View {
        if isPinned {
            let inset = style.pinnedInset
            // Offset in the render pass, so a sideways scroll moves no state and rebuilds no row.
            content
                .background(Color(.systemBackground))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color(.separator)).frame(width: style.hairline)
                }
                .visualEffect { content, proxy in
                    content.offset(x: max(0, inset - proxy.frame(in: .scrollView).minX))
                }
                .zIndex(1)
        } else {
            content
        }
    }
}
