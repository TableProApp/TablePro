import SwiftUI

struct SessionsTableView: View {
    @Bindable var viewModel: ServerDashboardViewModel
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(String(localized: "Active Sessions"), systemImage: "person.2")
                    .font(.headline)
                Text("(\(viewModel.sessions.count))")
                    .foregroundStyle(.secondary)
                Spacer()
                if let error = viewModel.panelErrors[.activeSessions] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Table(viewModel.sessions, selection: $selection, sortOrder: $viewModel.sessionSortOrder) {
                TableColumn(String(localized: "PID"), value: \.id) { session in
                    Text(session.id).monospacedDigit()
                }
                .width(min: 50, ideal: 70)

                TableColumn(String(localized: "User"), value: \.user)
                    .width(min: 60, ideal: 100)

                TableColumn(String(localized: "Database"), value: \.database)
                    .width(min: 60, ideal: 100)

                TableColumn(String(localized: "State"), value: \.state) { session in
                    Text(session.state)
                        .foregroundStyle(stateColor(session.state))
                }
                .width(min: 60, ideal: 80)

                TableColumn(String(localized: "Duration"), value: \.durationSeconds) { session in
                    Text(session.duration).monospacedDigit()
                }
                .width(min: 50, ideal: 80)

                TableColumn(String(localized: "Query"), value: \.query) { session in
                    Text(session.query)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(session.query)
                }

                TableColumn("") { session in
                    HStack(spacing: 4) {
                        if session.canCancel, viewModel.canCancelQueries {
                            Button { viewModel.confirmCancelQuery(processId: session.id) } label: {
                                Image(systemName: "stop.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Cancel Query"))
                            .accessibilityLabel(String(localized: "Cancel query for session \(session.id)"))
                        }
                        if session.canKill, viewModel.canKillSessions {
                            Button { viewModel.confirmKillSession(processId: session.id) } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Terminate Session"))
                            .accessibilityLabel(String(localized: "Terminate session \(session.id)"))
                        }
                    }
                }
                .width(60)
            }
            .onChange(of: viewModel.sessionSortOrder) { _, newOrder in
                viewModel.sessions.sort(using: newOrder)
            }
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "active", "running": return .green
        case "idle": return .secondary
        case "idle in transaction": return .orange
        case "waiting", "locked": return .red
        default: return .primary
        }
    }
}
