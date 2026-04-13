import SwiftUI

struct MetricsBarView: View {
    let metrics: [DashboardMetric]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(String(localized: "Server Metrics"), systemImage: "gauge.with.dots.needle.33percent")
                    .font(.headline)
                Spacer()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if metrics.isEmpty && error == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(metrics) { metric in
                            metricCard(metric)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func metricCard(_ metric: DashboardMetric) -> some View {
        HStack(spacing: 8) {
            Image(systemName: metric.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(metric.value)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .monospacedDigit()
                    if !metric.unit.isEmpty {
                        Text(metric.unit)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
