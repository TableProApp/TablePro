//
//  MCPAuditLogView.swift
//  TablePro
//

import SwiftUI

struct MCPAuditLogView: View {
    @State private var entries: [AuditEntry] = []
    @State private var tokens: [MCPAuthToken] = []
    @State private var selectedTokenId: UUID?
    @State private var selectedCategory: AuditCategory?
    @State private var selectedRange: TimeRangeOption = .last7Days
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filterBar

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if entries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .task { await reload() }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker(selection: $selectedTokenId) {
                Text(String(localized: "All tokens")).tag(UUID?.none)
                ForEach(tokens) { token in
                    Text(token.name).tag(Optional(token.id))
                }
            } label: {
                Text(String(localized: "Token"))
            }
            .frame(maxWidth: 220)

            Picker(selection: $selectedCategory) {
                Text(String(localized: "All categories")).tag(AuditCategory?.none)
                ForEach(AuditCategory.allCases) { category in
                    Text(category.displayName).tag(Optional(category))
                }
            } label: {
                Text(String(localized: "Category"))
            }
            .frame(maxWidth: 200)

            Picker(selection: $selectedRange) {
                ForEach(TimeRangeOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                Text(String(localized: "Range"))
            }
            .frame(maxWidth: 180)

            Spacer()

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(String(localized: "Refresh"))
        }
        .onChange(of: selectedTokenId) { _, _ in Task { await reload() } }
        .onChange(of: selectedCategory) { _, _ in Task { await reload() } }
        .onChange(of: selectedRange) { _, _ in Task { await reload() } }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(String(localized: "No activity yet"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var entryList: some View {
        List(entries) { entry in
            MCPAuditLogRow(entry: entry)
        }
        .listStyle(.inset)
        .frame(minHeight: 240)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        let store = MCPServerManager.shared.tokenStore
        if let store {
            tokens = await store.list().filter { $0.name != "__stdio_bridge__" }
        }

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
}

private struct MCPAuditLogRow: View {
    let entry: AuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            outcomeBadge
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.action)
                        .font(.callout.weight(.medium))
                    Text(entry.category.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let tokenName = entry.tokenName {
                    Text(tokenName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let connectionId = entry.connectionId {
                    Text(String(format: String(localized: "Connection: %@"), connectionId.uuidString.prefix(8) + "…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let details = entry.details {
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.timestamp.formatted(date: .numeric, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .help(entry.details ?? entry.action)
    }

    private var outcomeBadge: some View {
        Circle()
            .fill(outcomeColor)
            .frame(width: 8, height: 8)
            .padding(.top, 6)
    }

    private var outcomeColor: Color {
        switch entry.outcome {
        case AuditOutcome.success.rawValue: .green
        case AuditOutcome.denied.rawValue: .orange
        case AuditOutcome.rateLimited.rawValue: .orange
        case AuditOutcome.error.rawValue: .red
        default: .secondary
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
