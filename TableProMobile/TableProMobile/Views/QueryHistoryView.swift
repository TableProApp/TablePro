//
//  QueryHistoryView.swift
//  TableProMobile
//

import SwiftUI
import UIKit

struct QueryHistoryView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @State private var showClearConfirmation = false

    var body: some View {
        List {
            ForEach(coordinator.queryHistory.reversed()) { item in
                Button {
                    coordinator.pendingQuery = item.query
                    coordinator.selectedTab = .query
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.query)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(3)
                            .foregroundStyle(.primary)
                        Text(item.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = item.query
                    } label: {
                        Label("Copy Query", systemImage: "doc.on.doc")
                    }
                }
            }
            .onDelete { indexSet in
                let reversed = Array(coordinator.queryHistory.reversed())
                for index in indexSet {
                    coordinator.deleteHistoryItem(reversed[index].id)
                }
            }

            if !coordinator.queryHistory.isEmpty {
                Section {
                    Button(String(localized: "Clear All History"), role: .destructive) {
                        showClearConfirmation = true
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(String(localized: "Clear History"), isPresented: $showClearConfirmation) {
            Button(String(localized: "Clear All"), role: .destructive) {
                coordinator.clearHistory()
            }
        }
        .overlay {
            if coordinator.queryHistory.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("Executed queries will appear here.")
                )
            }
        }
    }
}
