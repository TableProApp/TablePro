//
//  IntegrationsActivityLogPane.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IntegrationsActivityLogPane: View {
    @State private var entries: [AuditEntry] = []
    @State private var tokens: [MCPAuthToken] = []
    @State private var connections: [DatabaseConnection] = []
    @State private var selectedTokenId: UUID?
    @State private var selectedCategory: AuditCategory?
    @State private var selectedRange: ActivityTimeRange = .last7Days
    @State private var searchText: String = ""
    @State private var selection: AuditEntry.ID?
    @State private var isLoading = false
    @State private var hasLoaded = false

    private let auditChanges = NotificationCenter.default
        .publisher(for: .mcpAuditLogChanged)

    var body: some View {
        ActivityLogTable(
            entries: filteredEntries,
            selection: $selection,
            row: { entry in
                ActivityLogRow(
                    entry: entry,
                    connectionName: connectionName(for: entry.connectionId),
                    tokenLabel: displayTokenName(entry.tokenName)
                )
            }
        )
        .overlay(alignment: .center) { overlay }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text(String(localized: "Search activity")))
        .toolbar(content: toolbar)
        .navigationTitle(IntegrationsActivitySection.activityLog.title)
        .navigationSubtitle(retentionSubtitle)
        .task { await reload() }
        .onReceive(auditChanges) { _ in
            Task { await reload() }
        }
        .onChange(of: selectedTokenId) { _, _ in Task { await reload() } }
        .onChange(of: selectedCategory) { _, _ in Task { await reload() } }
        .onChange(of: selectedRange) { _, _ in Task { await reload() } }
    }

    @ViewBuilder
    private var overlay: some View {
        if !hasLoaded {
            ProgressView()
        } else if filteredEntries.isEmpty {
            emptyState
                .background(.background)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if hasNoFilters {
            ContentUnavailableView(
                String(localized: "No activity yet"),
                systemImage: "tray",
                description: Text(String(localized: "External integrations and MCP client requests will appear here."))
            )
        } else {
            ContentUnavailableView(
                String(localized: "No matching activity"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(String(localized: "No activity matches the current filters."))
            )
        }
    }

    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        ToolbarItem {
            filterMenu
        }
        ToolbarItem {
            exportButton
        }
        ToolbarItem {
            refreshButton
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(String(localized: "Range"), selection: $selectedRange) {
                ForEach(ActivityTimeRange.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Picker(String(localized: "Category"), selection: $selectedCategory) {
                Text(String(localized: "All categories")).tag(AuditCategory?.none)
                ForEach(AuditCategory.allCases) { category in
                    Text(category.displayName).tag(Optional(category))
                }
            }
            Picker(String(localized: "Token"), selection: $selectedTokenId) {
                Text(String(localized: "All tokens")).tag(UUID?.none)
                ForEach(tokens) { token in
                    Text(displayTokenName(token.name) ?? token.name).tag(Optional(token.id))
                }
            }
            if hasActiveFilters {
                Divider()
                Button(String(localized: "Clear Filters")) {
                    selectedTokenId = nil
                    selectedCategory = nil
                    selectedRange = .last7Days
                }
            }
        } label: {
            Label(String(localized: "Filters"), systemImage: filterIcon)
        }
        .help(String(localized: "Filter activity"))
    }

    private var filterIcon: String {
        hasActiveFilters
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
    }

    private var exportButton: some View {
        Button(action: exportCSV) {
            Label(String(localized: "Export"), systemImage: "square.and.arrow.up")
        }
        .help(String(localized: "Export the filtered activity log to CSV"))
        .disabled(filteredEntries.isEmpty)
    }

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            Task { await reload() }
        } label: {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .help(String(localized: "Refresh"))
        .disabled(isLoading)
    }

    private var hasActiveFilters: Bool {
        selectedTokenId != nil || selectedCategory != nil || selectedRange != .last7Days
    }

    private var hasNoFilters: Bool {
        selectedTokenId == nil
            && selectedCategory == nil
            && selectedRange == .all
            && searchText.isEmpty
    }

    private var retentionSubtitle: String {
        String(localized: "Activity is retained for 90 days")
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

    private func displayTokenName(_ name: String?) -> String? {
        guard let name else { return nil }
        return name == MCPTokenStore.stdioBridgeTokenName ? String(localized: "Built-in CLI") : name
    }

    private func connectionName(for id: UUID?) -> String? {
        guard let id else { return nil }
        if let connection = connections.first(where: { $0.id == id }) {
            return connection.name
        }
        let prefix = id.uuidString.prefix(8)
        return String(format: String(localized: "Deleted connection (%@)"), String(prefix))
    }

    private func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        if let store = MCPServerManager.shared.tokenStore {
            tokens = await store.list().filter { $0.name != MCPTokenStore.stdioBridgeTokenName }
        }
        connections = ConnectionStorage.shared.loadConnections()

        let result = await MCPAuditLogStorage.shared.query(
            category: selectedCategory,
            tokenId: selectedTokenId,
            since: selectedRange.startDate,
            limit: 1_000
        )
        entries = result.sorted { $0.timestamp > $1.timestamp }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tablepro-activity-\(Self.fileTimestamp()).csv"
        panel.canCreateDirectories = true
        panel.title = String(localized: "Export Activity Log")

        guard panel.runModal() == .OK, let url = panel.url else { return }

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
        let header = ["Timestamp", "Category", "Action", "Connection", "Token", "Outcome", "Details"]
            .joined(separator: ",")
        let rows = entries.map { entry -> String in
            let cells = [
                ISO8601DateFormatter().string(from: entry.timestamp),
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
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

private struct ActivityLogTable<Row: View>: View {
    let entries: [AuditEntry]
    @Binding var selection: AuditEntry.ID?
    let row: (AuditEntry) -> Row

    var body: some View {
        List(entries, selection: $selection) { entry in
            row(entry)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct ActivityLogRow: View {
    let entry: AuditEntry
    let connectionName: String?
    let tokenLabel: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IntegrationStatusIndicator(status: rowStatus)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                primaryLine
                metadataLine
                if let details = entry.details {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            timestamp
        }
        .padding(.vertical, 4)
    }

    private var primaryLine: some View {
        HStack(spacing: 8) {
            Text(displayActionName)
                .font(.callout.weight(.medium))
            categoryBadge
            outcomeBadge
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        let parts: [String] = [
            tokenLabel,
            connectionName.map { String(format: String(localized: "Connection: %@"), $0) }
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var categoryBadge: some View {
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

    @ViewBuilder
    private var outcomeBadge: some View {
        if let outcome = AuditOutcome(rawValue: entry.outcome), outcome != .success {
            Text(outcome.displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(outcomeBackground(outcome).opacity(0.15))
                )
                .foregroundStyle(outcomeBackground(outcome))
        }
    }

    private var timestamp: some View {
        Text(entry.timestamp, format: .relative(presentation: .named))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(entry.timestamp.formatted(date: .complete, time: .standard))
    }

    private var displayActionName: String {
        entry.action.split(separator: ".").map { $0.capitalized }.joined(separator: " ")
    }

    private var rowStatus: IntegrationStatus {
        switch entry.outcome {
        case AuditOutcome.success.rawValue: .success
        case AuditOutcome.denied.rawValue, AuditOutcome.rateLimited.rawValue: .warning
        case AuditOutcome.error.rawValue: .error
        default: .stopped
        }
    }

    private func outcomeBackground(_ outcome: AuditOutcome) -> Color {
        switch outcome {
        case .success: Color(nsColor: .systemGreen)
        case .denied, .rateLimited: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        }
    }
}

enum ActivityTimeRange: String, CaseIterable, Identifiable {
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
