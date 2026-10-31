import SwiftUI
import TableProModels

nonisolated enum RowGridMetrics {
    static let minimumColumnWidth: CGFloat = 72
    static let maximumColumnWidth: CGFloat = 320
    static let cellHorizontalPadding: CGFloat = 12
    static let sampledRowCount = 50
    static let maximumMeasuredCharacters = 40

    /// Sized from the header and the first rows only, so a page of 500 rows costs no more than one of 50.
    static func columnWidths(columns: [ColumnInfo], rows: [[String?]], characterWidth: CGFloat) -> [CGFloat] {
        let sample = rows.prefix(sampledRowCount)
        return columns.indices.map { index in
            let longestValue = sample.reduce(0) { longest, row in
                guard row.indices.contains(index) else { return longest }
                return max(longest, displayLength(row[index] ?? "NULL"))
            }
            let characters = max(displayLength(columns[index].name), longestValue)
            let width = CGFloat(characters) * characterWidth + cellHorizontalPadding * 2
            return min(max(width, minimumColumnWidth), maximumColumnWidth)
        }
    }

    private static func displayLength(_ text: String) -> Int {
        let firstLine = text.prefix { !$0.isNewline }
        return min(firstLine.count, maximumMeasuredCharacters)
    }
}

struct RowGrid<Destination: View, MenuItems: View>: View {
    let columns: [ColumnInfo]
    let rows: [[String?]]
    @ViewBuilder let destination: (Int) -> Destination
    @ViewBuilder let menuItems: (Int) -> MenuItems
    let deleteAction: (Int) -> (() -> Void)?

    @ScaledMetric(relativeTo: .subheadline) private var characterWidth: CGFloat = 8
    @State private var pinnedOffset: CGFloat = 0

    var body: some View {
        let widths = RowGridMetrics.columnWidths(columns: columns, rows: rows, characterWidth: characterWidth)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(IndexedRow.wrap(rows)) { item in
                        rowLink(index: item.id, values: item.values, widths: widths)
                    }
                } header: {
                    header(widths: widths)
                }
            }
        }
        // The first column rides the horizontal offset back into view, so a row keeps its name while the rest scrolls.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(geometry.contentOffset.x + geometry.contentInsets.leading, 0)
        } action: { _, offset in
            pinnedOffset = offset
        }
    }

    private func header(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                Text(column.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, RowGridMetrics.cellHorizontalPadding)
                    .padding(.vertical, 8)
                    .frame(width: widths[index], alignment: .leading)
                    .modifier(PinnedCell(isPinned: index == 0, offset: pinnedOffset))
            }
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowLink(index: Int, values: [String?], widths: [CGFloat]) -> some View {
        let delete = deleteAction(index)
        return NavigationLink {
            destination(index)
        } label: {
            line(values: values, widths: widths)
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .contextMenu {
            menuItems(index)
            if let delete {
                Divider()
                Button("Delete Row", systemImage: "trash", role: .destructive, action: delete)
            }
        }
        .accessibilityActions {
            if let delete {
                Button("Delete row", action: delete)
            }
        }
    }

    private func line(values: [String?], widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.indices), id: \.self) { index in
                let value = values.indices.contains(index) ? values[index] : nil
                cell(value)
                    .frame(width: widths[index], alignment: .leading)
                    .modifier(PinnedCell(isPinned: index == 0, offset: pinnedOffset))
            }
        }
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
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
        .padding(.horizontal, RowGridMetrics.cellHorizontalPadding)
        .padding(.vertical, 11)
    }
}

private struct PinnedCell: ViewModifier {
    let isPinned: Bool
    let offset: CGFloat

    func body(content: Content) -> some View {
        if isPinned {
            content
                .background(Color(.systemBackground))
                .overlay(alignment: .trailing) {
                    if offset > 0 { Divider() }
                }
                .offset(x: offset)
                .zIndex(1)
        } else {
            content
        }
    }
}
