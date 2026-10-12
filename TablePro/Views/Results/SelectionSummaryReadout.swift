//
//  SelectionSummaryReadout.swift
//  TablePro
//

import SwiftUI
import TableProNumberFormatting

struct SelectionSummaryFigures: Equatable {
    enum Figure: Equatable {
        case count
        case numbers
        case empty
        case notANumber
        case sum
        case average
        case minimum
        case maximum
    }

    struct Row: Equatable, Identifiable {
        let figure: Figure
        let value: String
        let copyText: String

        var id: Figure { figure }
    }

    let valueCount: Int
    let sum: String?
    let average: String?
    let countRows: [Row]
    let numberRows: [Row]

    init(_ summary: SelectionSummary, locale: Locale = .current) {
        valueCount = summary.valueCount

        var countRows = [
            Self.countRow(.count, summary.valueCount, locale: locale),
            Self.countRow(.numbers, summary.numbers?.count ?? 0, locale: locale),
            Self.countRow(.empty, summary.emptyCount, locale: locale),
        ]
        if summary.notANumberCount > 0 {
            countRows.append(Self.countRow(.notANumber, summary.notANumberCount, locale: locale))
        }
        self.countRows = countRows

        let numberRows = summary.numbers.map { numbers in
            [Figure.sum, .average, .minimum, .maximum].compactMap { Self.numberRow($0, of: numbers, locale: locale) }
        } ?? []
        self.numberRows = numberRows
        sum = numberRows.first { $0.figure == .sum }?.value
        average = numberRows.first { $0.figure == .average }?.value
    }

    /// POSIX text with no grouping, so the copy pastes into SQL or a spreadsheet in any locale.
    static func copyText(_ figure: Figure, of numbers: ExactNumericSummary) -> String? {
        guard let value = figure.value(in: numbers) else { return nil }
        return ExactNumberFormat.plainText(value, fractionDigits: figure.fractionDigits(scale: numbers.scale))
    }

    private static func countRow(_ figure: Figure, _ count: Int, locale: Locale) -> Row {
        Row(figure: figure, value: count.formatted(.number.locale(locale)), copyText: String(count))
    }

    private static func numberRow(_ figure: Figure, of numbers: ExactNumericSummary, locale: Locale) -> Row? {
        guard let value = figure.value(in: numbers), let copyText = copyText(figure, of: numbers) else { return nil }
        let display = ExactNumberFormat.string(
            value,
            fractionDigits: figure.fractionDigits(scale: numbers.scale),
            locale: locale
        )
        return Row(figure: figure, value: display, copyText: copyText)
    }
}

internal extension SelectionSummaryFigures.Figure {
    var title: String {
        switch self {
        case .count: String(localized: "Count")
        case .numbers: String(localized: "Numbers", comment: "How many of the selected cells hold a number")
        case .empty: String(localized: "Empty")
        case .notANumber: String(localized: "Not a number")
        case .sum: String(localized: "Sum")
        case .average: String(localized: "Average")
        case .minimum: String(localized: "Minimum")
        case .maximum: String(localized: "Maximum")
        }
    }

    var copyTitle: String {
        switch self {
        case .count: String(localized: "Copy Count")
        case .numbers: String(localized: "Copy Number Count")
        case .empty: String(localized: "Copy Empty Count")
        case .notANumber: String(localized: "Copy Not a Number Count")
        case .sum: String(localized: "Copy Sum")
        case .average: String(localized: "Copy Average")
        case .minimum: String(localized: "Copy Minimum")
        case .maximum: String(localized: "Copy Maximum")
        }
    }

    /// Cents stay cents. The average gets four more digits, and the formatter trims trailing zeros.
    func fractionDigits(scale: Int) -> ClosedRange<Int> {
        let scale = max(0, scale)
        return self == .average ? 0...(scale + 4) : scale...scale
    }

    func value(in numbers: ExactNumericSummary) -> ExactNumber? {
        switch self {
        case .sum: numbers.sum
        case .average: numbers.mean
        case .minimum: numbers.minimum
        case .maximum: numbers.maximum
        case .count, .numbers, .empty, .notANumber: nil
        }
    }
}

/// The only view that observes the summary, so a recompute re-renders it and not the bar. The host
/// owns the popover flag: the bar mounts one readout per tier and closes popovers on a tab switch.
struct SelectionSummaryReadout: View {
    @ObservedObject var state: SelectionSummaryState
    let scopeNote: String?
    @Binding var isPopoverPresented: Bool
    var leadsWithSeparator = false

    var body: some View {
        if let summary = state.summary {
            let figures = SelectionSummaryFigures(summary)
            if leadsWithSeparator {
                StatusBarSeparator()
            }
            Button {
                isPopoverPresented.toggle()
            } label: {
                label(figures)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sentence(figures))
            .accessibilityHint(String(localized: "Shows every figure with a Copy button"))
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("result-status-selection-summary")
            .help(sentence(figures))
            .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
                SelectionSummaryPopover(state: state, scopeNote: scopeNote)
            }
            // The flag outlives the button, so a summary that comes back would reopen the popover.
            .onDisappear { isPopoverPresented = false }
        }
    }

    /// Digits are never truncated: the ladder drops figures instead, down to a glyph that keeps the
    /// popover's anchor on the bar at every width.
    private func label(_ figures: SelectionSummaryFigures) -> some View {
        ViewThatFits(in: .horizontal) {
            if let sum = figures.sum, let average = figures.average {
                Text("Sum \(sum) · Average \(average) · Count \(figures.valueCount)")
                    .fixedSize()
                Text("Sum \(sum)")
                    .fixedSize()
            } else {
                Text("Count \(figures.valueCount)")
                    .fixedSize()
            }
            Image(systemName: "sum")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private func sentence(_ figures: SelectionSummaryFigures) -> Text {
        guard let sum = figures.sum, let average = figures.average else {
            return Text("Count \(figures.valueCount)")
        }
        return Text("Sum \(sum), Average \(average), Count \(figures.valueCount)")
    }
}

struct SelectionSummaryPopover: View {
    @ObservedObject var state: SelectionSummaryState
    let scopeNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = state.summary {
                let figures = SelectionSummaryFigures(summary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(figures.countRows) { row in
                        figureRow(row)
                    }
                    if !figures.numberRows.isEmpty {
                        Divider()
                        ForEach(figures.numberRows) { row in
                            figureRow(row)
                        }
                    }
                }
                if summary.coversWholeColumn, let scopeNote {
                    Text(scopeNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
        .padding(14)
        // A popover inherits its presenter's environment, and both bars set caption, secondary,
        // one-line text for their own row.
        .font(.body)
        .foregroundStyle(.primary)
        .lineLimit(nil)
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection-summary-popover")
    }

    private func figureRow(_ row: SelectionSummaryFigures.Row) -> some View {
        GridRow {
            Text(row.figure.title)
                .foregroundStyle(.secondary)
            Text(row.value)
                .monospacedDigit()
                .textSelection(.enabled)
                .gridColumnAlignment(.trailing)
            Button {
                ClipboardService.shared.writeText(row.copyText)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(!state.isCurrent)
            .help(row.figure.copyTitle)
            .accessibilityLabel(row.figure.copyTitle)
        }
    }
}
