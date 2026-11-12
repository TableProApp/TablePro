import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IntegrationsActivityLogPane: View {
    @ObservedObject private var mcpServerManager = MCPServerManager.shared
    @State private var entries: [AuditEntry] = []
    @State private var tokens: [MCPAuthToken] = []
    @State private var clientNames: [String] = []
    @State private var connections: [DatabaseConnection] = []
    @State private var selectedToken: ActivityTokenFilter?
    @State private var selectedClient: String?
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
        .modifier(ActivityLogInspectorPane(
            isPresented: $showInspector,
            entry: selectedEntry,
            connectionLabel: connectionName
        ))
        .toolbar(content: toolbar)
        .navigationTitle(IntegrationsActivitySection.activityLog.title)
        .navigationSubtitle(retentionSubtitle)
        .task { await reload() }
        .onReceive(AppEvents.shared.mcpAuditLogChanged) { _ in
            Task { await reload() }
        }
        .onChange(of: selectedToken) { _ in Task { await reload() } }
        .onChange(of: selectedClient) { _ in Task { await reload() } }
        .onChange(of: selectedCategory) { _ in Task { await reload() } }
        .onChange(of: selectedRange) { _ in Task { await reload() } }
        .onChange(of: sortOrder) { newValue in
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
            UnavailableStateView.search(text: searchText)
        } else if hasNoFilters {
            UnavailableStateView(
                String(localized: "No activity yet"),
                systemImage: "tray",
                description: Text(String(localized: "External integrations and MCP client requests will appear here."))
            )
        } else {
            UnavailableStateView(
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
            Picker(String(localized: "Client"), selection: $selectedClient) {
                Text(String(localized: "All clients")).tag(String?.none)
                ForEach(clientNames, id: \.self) { name in
                    Text(verbatim: name).tag(Optional(name))
                }
            }
            Picker(String(localized: "Token"), selection: $selectedToken) {
                Text(String(localized: "All tokens")).tag(ActivityTokenFilter?.none)
                ForEach(ActivityTokenFilter.ownCredentialNames, id: \.self) { name in
                    Text(IntegrationsFormatting.displayTokenName(name)).tag(Optional(ActivityTokenFilter.named(name)))
                }
                ForEach(tokens) { token in
                    Text(IntegrationsFormatting.displayTokenName(token.name)).tag(Optional(ActivityTokenFilter.token(token.id)))
                }
            }
            if hasActiveFilters {
                Divider()
                Button(String(localized: "Clear Filters")) {
                    selectedToken = nil
                    selectedClient = nil
                    selectedCategory = nil
                    selectedRange = .last7Days
                }
            }
        } label: {
            Label(String(localized: "Filters"), systemImage: ToolbarSymbols.filter(isActive: hasActiveFilters))
        }
        // A toolbar-hosted Menu otherwise publishes "chevron.pulldown" from its label (see WelcomeViewOptionsMenu).
        .accessibilityLabel(String(localized: "Filters"))
        .help(String(localized: "Filter activity"))
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

    // The glyph AppKit's own inspector toggle draws; unlike sidebar.right it mirrors right to left.
    private var inspectorToggle: some View {
        Button {
            showInspector.toggle()
        } label: {
            Label(String(localized: "Details"), systemImage: "sidebar.trailing")
        }
        .help(String(localized: "Show details"))
    }

    private var hasActiveFilters: Bool {
        selectedToken != nil || selectedClient != nil || selectedCategory != nil || selectedRange != .last7Days
    }

    private var hasNoFilters: Bool {
        selectedToken == nil
            && selectedClient == nil
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
        return entries.filter { Self.searchMatches($0, needle: needle, connectionName: connectionName) }
    }

    static func searchMatches(_ entry: AuditEntry, needle: String, connectionName: (UUID?) -> String?) -> Bool {
        let fields = [
            entry.action,
            entry.clientName,
            entry.tokenName.map(IntegrationsFormatting.displayTokenName),
            connectionName(entry.connectionId),
            entry.details
        ]
        return fields.contains { $0?.lowercased().contains(needle) == true }
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

        if let store = mcpServerManager.tokenStore {
            // TablePro mints these afresh every rotation and every agent turn, so they are filtered by name.
            tokens = await store.list().filter { !$0.isBridgeCredential && !$0.isClaudeAgentCredential }
        }
        connections = ConnectionStorage.shared.loadConnections()

        let storage = MCPAuditLogStorage.shared
        clientNames = await storage.clientNames()
        let result = await storage.query(
            category: selectedCategory,
            tokenId: selectedToken?.tokenId,
            tokenName: selectedToken?.tokenName,
            clientName: selectedClient,
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

        if let window = AlertHelper.resolveWindow(nil) {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                writeActivityLog(to: url)
            }
        } else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            writeActivityLog(to: url)
        }
    }

    private func writeActivityLog(to url: URL) {
        do {
            try Self.csvString(for: filteredEntries, connectionName: connectionName)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AlertHelper.showErrorSheet(
                title: String(localized: "Could not export activity log"),
                message: error.localizedDescription,
                window: nil
            )
        }
    }

    static func csvString(for entries: [AuditEntry], connectionName: (UUID?) -> String?) -> String {
        let header = ["Timestamp", "Category", "Action", "Client", "Connection", "Token", "Outcome", "Details"]
            .joined(separator: ",")
        let timestampFormatter = ISO8601DateFormatter()
        let rows = entries.map { entry -> String in
            let cells = [
                timestampFormatter.string(from: entry.timestamp),
                entry.category.rawValue,
                entry.action,
                entry.clientName ?? "",
                connectionName(entry.connectionId) ?? "",
                entry.tokenName ?? "",
                entry.outcome,
                entry.details ?? ""
            ]
            return cells.map(CsvRowConverter.encodeForSpreadsheet).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
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

            TableColumn(String(localized: "Client")) { entry in
                clientCell(for: entry)
            }
            .width(min: 100, ideal: 140)

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
    private func clientCell(for entry: AuditEntry) -> some View {
        if let name = entry.clientName {
            Text(verbatim: name)
        } else {
            Text(verbatim: "-").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func tokenCell(for entry: AuditEntry) -> some View {
        if let name = entry.tokenName {
            Text(IntegrationsFormatting.displayTokenName(name))
        } else {
            Text(verbatim: "-").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func connectionCell(for entry: AuditEntry) -> some View {
        if let label = connectionLabel(entry.connectionId) {
            Text(label)
        } else {
            Text(verbatim: "-").foregroundStyle(.tertiary)
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
            entry.clientName.map { String(format: String(localized: "Client: %@"), $0) },
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
                UnavailableStateView(
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
                LabeledContent(String(localized: "Client")) {
                    Text(entry.clientName ?? String(localized: "None"))
                        .foregroundStyle(entry.clientName == nil ? .tertiary : .primary)
                        .textSelection(.enabled)
                }
                LabeledContent(String(localized: "Token")) {
                    let tokenText = entry.tokenName.map(IntegrationsFormatting.displayTokenName) ?? String(localized: "None")
                    Text(tokenText)
                        .foregroundStyle(entry.tokenName == nil ? .tertiary : .primary)
                        .textSelection(.enabled)
                }
                LabeledContent(String(localized: "Connection")) {
                    Text(connectionLabel(entry.connectionId) ?? String(localized: "None"))
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

enum ActivityTokenFilter: Hashable {
    case token(UUID)
    // TablePro's own credentials, minted afresh each bridge rotation and each Claude Agent turn.
    case named(String)

    static let ownCredentialNames = [MCPTokenStore.stdioBridgeTokenName, MCPTokenStore.claudeAgentTokenName]

    var tokenId: UUID? {
        if case .token(let id) = self { return id }
        return nil
    }

    var tokenName: String? {
        if case .named(let name) = self { return name }
        return nil
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

// .inspector is macOS 14; before it the pane sits beside the log in an HSplitView.
private struct ActivityLogInspectorPane: ViewModifier {
    @Binding var isPresented: Bool
    let entry: AuditEntry?
    let connectionLabel: (UUID?) -> String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.inspector(isPresented: $isPresented) {
                ActivityLogInspector(entry: entry, connectionLabel: connectionLabel)
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
            }
        } else {
            HSplitView {
                content
                if isPresented {
                    ActivityLogInspector(entry: entry, connectionLabel: connectionLabel)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                }
            }
        }
    }
}
