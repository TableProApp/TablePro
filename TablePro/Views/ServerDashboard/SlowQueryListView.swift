import SwiftUI

struct SlowQueryListView: View {
    let queries: [DashboardSlowQuery]
    let error: String?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Label(String(localized: "Slow Queries"), systemImage: "tortoise")
                        .font(.headline)
                    Text("(\(queries.count))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if isExpanded {
                if queries.isEmpty && error == nil {
                    Text(String(localized: "No slow queries"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(queries) { query in
                                slowQueryRow(query)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 200)
                }
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
