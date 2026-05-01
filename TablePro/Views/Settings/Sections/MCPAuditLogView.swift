import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MCPAuditLogView: View {
    @State private var entries: [AuditEntry] = []
    @State private var tokens: [MCPAuthToken] = []
    @State private var connections: [DatabaseConnection] = []
    @State private var selectedTokenId: UUID?
    @State private var selectedCategory: AuditCategory?
    @State private var selectedRange: TimeRangeOption = .last7Days
    @State private var searchText: String = ""
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchBar
            filterBar

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if filteredEntries.isEmpty {
                emptyState
            } else {
                entryList
            }

            HStack {
                Text(String(localized: "Activity is retained for 90 days."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .task { await reload() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search activity"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker(selection: $selectedTokenId) {
                Text(String(localized: "All tokens")).tag(UUID?.none)
                ForEach(tokens) { token in
                    Text(displayTokenName(token.name)).tag(Optional(token.id))
                }
            } label: {
                Text(String(localized: "Token"))
            }
            .frame(minWidth: 180, maxWidth: 240)

            Picker(selection: $selectedCategory) {
                Text(String(localized: "All categories")).tag(AuditCategory?.none)
                ForEach(AuditCategory.allCases) { category in
                    Text(category.displayName).tag(Optional(category))
                }
            } label: {
                Text(String(localized: "Category"))
            }
            .frame(minWidth: 180, maxWidth: 220)

            Picker(selection: $selectedRange) {
                ForEach(TimeRangeOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                Text(String(localized: "Range"))
            }
            .frame(minWidth: 160, maxWidth: 200)

            Spacer()

            Button {
                exportCSV()
            } label: {
                Label(String(localized: "Export…"), systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel(String(localized: "Export activity to CSV"))
            .help(String(localized: "Export the filtered activity log to CSV"))
            .disabled(filteredEntries.isEmpty)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(String(localized: "Refresh"))
            .help(String(localized: "Refresh"))
        }
        .onChange(of: selectedTokenId) { _, _ in Task { await reload() } }
        .onChange(of: selectedCategory) { _, _ in Task { await reload() } }
        .onChange(of: selectedRange) { _, _ in Task { await reload() } }
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Group {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(
                        String(localized: "No activity yet"),
                        systemImage: "tray",
                        description: Text(String(localized: "External integrations and MCP client requests will appear here."))
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entryList: some View {
        List(filteredEntries) { entry in
            MCPAuditLogRow(
                entry: entry,
                connectionName: connectionName(for: entry.connectionId)
            )
        }
        .listStyle(.inset)
        .frame(minHeight: 240)
    }

    private var filteredEntries: [AuditEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let needle = trimmed.lowercased()
        return entries.filter { entry in
            if entry.action.lowercased().contains(needle) { return true }
            if let tokenName = entry.tokenName?.lowercased(), tokenName.contains(needle) { return true }
            if let connectionName = connectionName(for: entry.connectionId)?.lowercased(),
                connectionName.contains(needle) {
                return true
            }
            if let details = entry.details?.lowercased(), details.contains(needle) { return true }
            return false
        }
    }

    private func connectionName(for id: UUID?) -> String? {
        guard let id else { return nil }
        if let connection = connections.first(where: { $0.id == id }) {
            return connection.name
        }
        let prefix = id.uuidString.prefix(8)
        return String(format: String(localized: "Deleted connection (%@)"), String(prefix))
    }

    private func displayTokenName(_ name: String) -> String {
        name == MCPTokenStore.stdioBridgeTokenName ? String(localized: "Built-in CLI") : name
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        let store = MCPServerManager.shared.tokenStore
        if let store {
            tokens = await store.list().filter { $0.name != MCPTokenStore.stdioBridgeTokenName }
        }
        connections = ConnectionStorage.shared.loadConnections()

        let since = selectedRange.startDate
        let category = selectedCategory
        let tokenId = selectedTokenId
        let result = await MCPAuditLogStorage.shared.query(
            category: category,
            tokenId: tokenId,
            since: since,
            limit: 1_000
        )
        entries = result
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tablepro-activity-\(Self.fileTimestamp()).csv"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export Activity Log")

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        let csv = csvString(for: filteredEntries)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not export activity log")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    private func csvString(for entries: [AuditEntry]) -> String {
        let header = [
            "Timestamp",
            "Category",
            "Action",
            "Connection",
            "Token",
            "Outcome",
            "Details"
        ].joined(separator: ",")
        let rows = entries.map { entry -> String in
            let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
            let cells = [
                timestamp,
                entry.category.rawValue,
                entry.action,
                connectionName(for: entry.connectionId) ?? "",
                entry.tokenName ?? "",
                entry.outcome,
                entry.details ?? ""
            ]
            return cells.map(Self.escapeCSV).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func escapeCSV(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        guard needsQuotes else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

private struct MCPAuditLogRow: View {
    let entry: AuditEntry
    let connectionName: String?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IntegrationStatusIndicator(status: outcomeStatus)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayActionName)
                        .font(.callout.weight(.medium))
                    Text(entry.category.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                        )
                }
                if let tokenName = entry.tokenName {
                    Text(displayTokenName(tokenName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let connectionName {
                    Text(String(format: String(localized: "Connection: %@"), connectionName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let details = entry.details {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(Self.relativeFormatter.localizedString(for: entry.timestamp, relativeTo: .now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .help(entry.timestamp.formatted(date: .complete, time: .standard))
    }

    private var displayActionName: String {
        let words = entry.action.split(separator: ".").map { $0.capitalized }
        return words.joined(separator: " ")
    }

    private func displayTokenName(_ name: String) -> String {
        name == MCPTokenStore.stdioBridgeTokenName ? String(localized: "Built-in CLI") : name
    }

    private var outcomeStatus: IntegrationStatus {
        switch entry.outcome {
        case AuditOutcome.success.rawValue: return .success
        case AuditOutcome.denied.rawValue, AuditOutcome.rateLimited.rawValue: return .warning
        case AuditOutcome.error.rawValue: return .error
        default: return .stopped
        }
    }
}

enum TimeRangeOption: String, CaseIterable, Identifiable {
    case last24Hours
    case last7Days
    case last30Days
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .last24Hours: String(localized: "Last 24 hours")
        case .last7Days: String(localized: "Last 7 days")
        case .last30Days: String(localized: "Last 30 days")
        case .all: String(localized: "All time")
        }
    }

    var startDate: Date? {
        let now = Date()
        switch self {
        case .last24Hours: return now.addingTimeInterval(-86_400)
        case .last7Days: return now.addingTimeInterval(-7 * 86_400)
        case .last30Days: return now.addingTimeInterval(-30 * 86_400)
        case .all: return nil
        }
    }
}
