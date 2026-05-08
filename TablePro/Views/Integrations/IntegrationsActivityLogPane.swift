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
    @State private var sortOrder: [KeyPathComparator<AuditEntry>] = [
        KeyPathComparator(\AuditEntry.timestamp, order: .reverse)
    ]
    @State private var selection: AuditEntry.ID?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var showInspector = false

    var body: some View {
        ActivityLogTable(
            entries: filteredEntries,
            selection: $selection,
            sortOrder: $sortOrder,
            connectionLabel: connectionName
        )
        .overlay(alignment: .center) { overlay }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text(String(localized: "Search activity")))
        .inspector(isPresented: $showInspector) {
            ActivityLogInspector(entry: selectedEntry,
                                 connectionLabel: connectionName)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
        }
        .toolbar(content: toolbar)
        .navigationTitle(IntegrationsActivitySection.activityLog.title)
        .navigationSubtitle(retentionSubtitle)
        .task { await reload() }
        .onReceive(AppEvents.shared.mcpAuditLogChanged) { _ in
            Task { await reload() }
        }
        .onChange(of: selectedTokenId) { _, _ in Task { await reload() } }
        .onChange(of: selectedCategory) { _, _ in Task { await reload() } }
        .onChange(of: selectedRange) { _, _ in Task { await reload() } }
        .onChange(of: sortOrder) { _, newValue in
            entries.sort(using: newValue)
        }
    }

    private var selectedEntry: AuditEntry? {
        guard let selection else { return nil }
        return filteredEntries.first { $0.id == selection }
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
        ToolbarItem { filterMenu }
        ToolbarItem { exportButton }
        ToolbarItem { refreshButton }
        ToolbarItem(placement: .primaryAction) { inspectorToggle }
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
                    Text(IntegrationsFormatting.displayTokenName(token.name)).tag(Optional(token.id))
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

    private var inspectorToggle: some View {
        Button {
            showInspector.toggle()
        } label: {
            Label(String(localized: "Details"), systemImage: "sidebar.right")
        }
        .help(String(localized: "Show details"))
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
        String(localized: "Activity is retained for 90 days.")
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
        entries = result.sorted(using: sortOrder)
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
        let timestampFormatter = ISO8601DateFormatter()
        let rows = entries.map { entry -> String in
            let cells = [
                timestampFormatter.string(from: entry.timestamp),
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

private struct ActivityLogTable: View {
    let entries: [AuditEntry]
    @Binding var selection: AuditEntry.ID?
    @Binding var sortOrder: [KeyPathComparator<AuditEntry>]
    let connectionLabel: (UUID?) -> String?

    var body: some View {
        Table(of: AuditEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(String(localized: "Outcome"), value: \.outcomeSeverity) { entry in
                outcomeCell(for: entry)
            }
            .width(min: 96, ideal: 110)

            TableColumn(String(localized: "Time"), value: \.timestamp) { entry in
                timeCell(for: entry)
            }
            .width(min: 110, ideal: 130)

            TableColumn(String(localized: "Category")) { entry in
                Text(entry.category.displayName)
            }
            .width(min: 100, ideal: 120)

            TableColumn(String(localized: "Action"), value: \.action) { entry in
                actionCell(for: entry)
            }
            .width(min: 160, ideal: 220)

            TableColumn(String(localized: "Token")) { entry in
                tokenCell(for: entry)
            }
            .width(min: 100, ideal: 140)

            TableColumn(String(localized: "Connection")) { entry in
                connectionCell(for: entry)
            }
            .width(min: 120, ideal: 160)
        } rows: {
            ForEach(entries) { entry in
                SwiftUI.TableRow(entry)
                    .contextMenu { contextMenu(for: entry) }
            }
        }
    }

    @ViewBuilder
    private func outcomeCell(for entry: AuditEntry) -> some View {
        let outcome = AuditOutcome(rawValue: entry.outcome)
        Label {
            Text(outcome?.displayName ?? entry.outcome)
        } icon: {
            Image(systemName: IntegrationsFormatting.outcomeSymbol(outcome))
                .foregroundStyle(IntegrationsFormatting.outcomeTint(outcome))
        }
    }

    @ViewBuilder
    private func timeCell(for entry: AuditEntry) -> some View {
        Text(entry.timestamp, format: .relative(presentation: .named))
            .help(entry.timestamp.formatted(date: .complete, time: .standard))
    }

    @ViewBuilder
    private func actionCell(for entry: AuditEntry) -> some View {
        Text(entry.action)
            .font(.system(.body, design: .monospaced))
    }

    @ViewBuilder
    private func tokenCell(for entry: AuditEntry) -> some View {
        if let name = entry.tokenName {
            Text(IntegrationsFormatting.displayTokenName(name))
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func connectionCell(for entry: AuditEntry) -> some View {
        if let label = connectionLabel(entry.connectionId) {
            Text(label)
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: AuditEntry) -> some View {
        Button(String(localized: "Copy Details")) {
            copyDetails(for: entry)
        }
        if entry.connectionId != nil {
            Button(String(localized: "Copy Connection ID")) {
                if let id = entry.connectionId {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id.uuidString, forType: .string)
                }
            }
        }
    }

    private func copyDetails(for entry: AuditEntry) {
        let outcome = AuditOutcome(rawValue: entry.outcome)?.displayName ?? entry.outcome
        let tokenLine = entry.tokenName.map {
            String(format: String(localized: "Token: %@"), IntegrationsFormatting.displayTokenName($0))
        }
        let lines = [
            String(format: String(localized: "Time: %@"), entry.timestamp.formatted(date: .complete, time: .standard)),
            String(format: String(localized: "Category: %@"), entry.category.displayName),
            String(format: String(localized: "Action: %@"), entry.action),
            String(format: String(localized: "Outcome: %@"), outcome),
            tokenLine,
            connectionLabel(entry.connectionId).map { String(format: String(localized: "Connection: %@"), $0) },
            entry.details.map { String(format: String(localized: "Details: %@"), $0) }
        ].compactMap { $0 }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct ActivityLogInspector: View {
    let entry: AuditEntry?
    let connectionLabel: (UUID?) -> String?

    var body: some View {
        Group {
            if let entry {
                detailForm(for: entry)
            } else {
                ContentUnavailableView(
                    String(localized: "No Selection"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(String(localized: "Select an activity entry to see its details."))
                )
            }
        }
        .navigationTitle(String(localized: "Activity Details"))
    }

    private func detailForm(for entry: AuditEntry) -> some View {
        Form {
            Section {
                LabeledContent(String(localized: "Time")) {
                    Text(entry.timestamp.formatted(date: .complete, time: .standard))
                        .textSelection(.enabled)
                }
                LabeledContent(String(localized: "Outcome")) {
                    outcomeLabel(for: entry)
                }
                LabeledContent(String(localized: "Category")) {
                    Text(entry.category.displayName)
                }
            }

            Section(String(localized: "Source")) {
                LabeledContent(String(localized: "Token")) {
                    let tokenText = entry.tokenName.map(IntegrationsFormatting.displayTokenName) ?? "—"
                    Text(tokenText)
                        .foregroundStyle(entry.tokenName == nil ? .tertiary : .primary)
                        .textSelection(.enabled)
                }
                LabeledContent(String(localized: "Connection")) {
                    Text(connectionLabel(entry.connectionId) ?? "—")
                        .foregroundStyle(entry.connectionId == nil ? .tertiary : .primary)
                        .textSelection(.enabled)
                }
            }

            Section(String(localized: "Action")) {
                Text(entry.action)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let details = entry.details, !details.isEmpty {
                Section(String(localized: "Details")) {
                    ScrollView {
                        Text(details)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 80, maxHeight: 200)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func outcomeLabel(for entry: AuditEntry) -> some View {
        let outcome = AuditOutcome(rawValue: entry.outcome)
        return Label {
            Text(outcome?.displayName ?? entry.outcome)
        } icon: {
            Image(systemName: IntegrationsFormatting.outcomeSymbol(outcome))
                .foregroundStyle(IntegrationsFormatting.outcomeTint(outcome))
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
