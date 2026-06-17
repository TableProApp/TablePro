//
//  TriggerDetailView.swift
//  TablePro
//
//  Read-only master-detail view of a table's triggers.
//

import SwiftUI

struct TriggerDetailView: View {
    let triggers: [TriggerInfo]
    @Binding var selectedTriggerID: TriggerInfo.ID?
    @Binding var fontSize: Double
    let databaseType: DatabaseType
    let isLoading: Bool
    let onOpenInEditor: (TriggerInfo) -> Void

    @State private var searchText = ""
    @State private var sortOrder: [KeyPathComparator<TriggerInfo>] = [KeyPathComparator(\.name)]

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if triggers.isEmpty {
            EmptyStateView.triggers()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AutosavingVSplitView(
                autosaveName: "com.TablePro.triggerSplit",
                topMinimumHeight: 120,
                bottomMinimumHeight: 180
            ) {
                triggerList
            } bottom: {
                detailPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: ensureSelection)
            .onChange(of: triggers) { _, _ in ensureSelection() }
        }
    }

    private var displayedTriggers: [TriggerInfo] {
        let filtered = searchText.isEmpty
            ? triggers
            : triggers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return filtered.sorted(using: sortOrder)
    }

    private var showEnabled: Bool { triggers.contains { $0.enabled != nil } }
    private var showOrientation: Bool { triggers.contains { !($0.orientation ?? "").isEmpty } }
    private var showWhen: Bool { triggers.contains { !($0.whenClause ?? "").isEmpty } }

    private var selectedTrigger: TriggerInfo? {
        guard let id = selectedTriggerID,
              let match = triggers.first(where: { $0.id == id }) else {
            return triggers.first
        }
        return match
    }

    private func ensureSelection() {
        guard let id = selectedTriggerID,
              triggers.contains(where: { $0.id == id }) else {
            selectedTriggerID = triggers.first?.id
            return
        }
    }

    private var triggerList: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $searchText, placeholder: String(localized: "Filter"))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            triggerTable
        }
    }

    private var triggerTable: some View {
        Table(displayedTriggers, selection: $selectedTriggerID, sortOrder: $sortOrder) {
            TableColumn(String(localized: "Name"), value: \.name)
                .width(min: 140, ideal: 220)
            TableColumn(String(localized: "Timing"), value: \.timing)
                .width(min: 70, ideal: 90)
            TableColumn(String(localized: "Event"), value: \.event)
                .width(min: 90, ideal: 150)
            if showOrientation {
                TableColumn(String(localized: "For Each")) { trigger in
                    Text(trigger.orientation ?? "")
                }
                .width(min: 70, ideal: 90)
            }
            if showEnabled {
                TableColumn(String(localized: "Enabled")) { trigger in
                    if let enabled = trigger.enabled {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(enabled ? Color.green : Color.secondary)
                            .accessibilityLabel(enabled
                                ? String(localized: "Enabled")
                                : String(localized: "Disabled"))
                    }
                }
                .width(min: 60, ideal: 70)
            }
            if showWhen {
                TableColumn(String(localized: "When")) { trigger in
                    Text(trigger.whenClause ?? "")
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 180)
            }
        }
    }

    private var detailPane: some View {
        Group {
            if let trigger = selectedTrigger {
                VStack(spacing: 0) {
                    detailToolbar(for: trigger)
                    Divider()
                    DDLTextView(ddl: trigger.statement, fontSize: $fontSize, databaseType: databaseType)
                }
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
    }

    private func detailToolbar(for trigger: TriggerInfo) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button {
                    fontSize = max(10, fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(String(localized: "Decrease font size"))
                Text("\(Int(fontSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Button {
                    fontSize = min(24, fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(String(localized: "Increase font size"))
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                onOpenInEditor(trigger)
            } label: {
                Label("Open in Editor", systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)

            Button {
                ClipboardService.shared.writeText(trigger.statement)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
