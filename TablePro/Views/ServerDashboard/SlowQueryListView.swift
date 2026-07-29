import SwiftUI

struct SlowQueryListView: View {
    let queries: [DashboardSlowQuery]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(String(localized: "Slow Queries"), systemImage: "tortoise")
                    .font(.headline)
                Text("(\(queries.count))")
                    .foregroundStyle(.secondary)
                Spacer()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if queries.isEmpty && error == nil {
                Text(String(localized: "No slow queries"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(queries) { query in
                        slowQueryRow(query)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func slowQueryRow(_ query: DashboardSlowQuery) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(query.duration)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.orange)
                .frame(width: 50, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(query.query)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if !query.user.isEmpty {
                        Text(query.user)
                    }
                    if !query.database.isEmpty {
                        Text("·")
                        Text(query.database)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
