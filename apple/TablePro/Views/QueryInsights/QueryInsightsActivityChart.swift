import Charts
import SwiftUI
import TableProTheme

struct QueryInsightsActivityChart: View {
    let buckets: [QueryInsightsActivityBucket]
    let granularity: QueryInsightsGranularity

    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Environment(\.colorSchemeContrast) private var contrast

    private enum Outcome: String, Plottable {
        case succeeded
        case failed

        var displayName: String {
            switch self {
            case .succeeded: return String(localized: "Succeeded")
            case .failed: return String(localized: "Failed")
            }
        }
    }

    private struct Segment: Identifiable {
        let date: Date
        let outcome: Outcome
        let queryCount: Int

        var id: String { "\(date.timeIntervalSince1970)-\(outcome.rawValue)" }
    }

    private var segments: [Segment] {
        buckets.flatMap { bucket in
            [
                Segment(date: bucket.date, outcome: .succeeded, queryCount: bucket.succeededCount),
                Segment(date: bucket.date, outcome: .failed, queryCount: bucket.failedCount),
            ]
            .filter { $0.queryCount > 0 }
        }
    }

    // A chart plot takes the grid's lines and background, as the result chart does. Unthemed it keeps
    // the default grid line and no plot fill.
    var body: some View {
        let gridLine = ThemeShapeStyle.override(.gridLine, engine: themeEngine, contrast: contrast)
        return Chart(segments) { segment in
            BarMark(
                x: .value(String(localized: "Date"), segment.date, unit: granularity.component),
                y: .value(String(localized: "Queries"), segment.queryCount)
            )
            .foregroundStyle(by: .value(String(localized: "Outcome"), segment.outcome))
            .accessibilityLabel(accessibilityLabel(for: segment))
            .accessibilityValue(segment.queryCount.formatted())
        }
        .chartForegroundStyleScale([
            Outcome.succeeded: Color.accentColor,
            Outcome.failed: Color.orange,
        ])
        .chartLegend(position: .top, alignment: .trailing, spacing: 8)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if let gridLine {
                    AxisGridLine().foregroundStyle(gridLine)
                } else {
                    AxisGridLine()
                }
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(count.formatted())
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                if let gridLine {
                    AxisGridLine().foregroundStyle(gridLine)
                } else {
                    AxisGridLine()
                }
                AxisValueLabel(format: axisFormat, centered: false)
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.themeBackground(.gridBackground, native: Color.clear, in: .rect(cornerRadius: 8))
        }
        .frame(height: 180)
        .padding(.top, 4)
    }

    private var axisFormat: Date.FormatStyle {
        granularity == .hourly
            ? .dateTime.hour()
            : .dateTime.month(.abbreviated).day()
    }

    private func accessibilityLabel(for segment: Segment) -> String {
        let date = granularity == .hourly
            ? segment.date.formatted(.dateTime.month(.abbreviated).day().hour())
            : segment.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date), \(segment.outcome.displayName)"
    }
}

// An empty section keeps its place with a reason, so the sections below it never shuffle.
struct QueryInsightsSection<Content: View>: View {
    let title: String
    let systemImage: String
    var accessory: AnyView?
    let isEmpty: Bool
    let emptyMessage: String
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        systemImage: String,
        accessory: AnyView? = nil,
        isEmpty: Bool,
        emptyMessage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.isEmpty = isEmpty
        self.emptyMessage = emptyMessage
        self.content = content
    }

    var body: some View {
        GroupBox {
            Group {
                if isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                } else {
                    content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                accessory
            }
        }
        .padding(.horizontal, 16)
    }
}
