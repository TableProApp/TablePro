//
//  TriggerDetailView.swift
//  TablePro
//
//  Read-only master-detail view of a table's triggers.
//

import SwiftUI

@Observable
final class TriggerInspectorState {
    var searchText = ""
    var sortOrder: [KeyPathComparator<TriggerInfo>] = [KeyPathComparator(\.name)]
    var selectedID: TriggerInfo.ID?

    func displayed(_ triggers: [TriggerInfo]) -> [TriggerInfo] {
        let filtered = searchText.isEmpty
            ? triggers
            : triggers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return filtered.sorted(using: sortOrder)
    }

    func selectedTrigger(_ triggers: [TriggerInfo]) -> TriggerInfo? {
        let list = displayed(triggers)
        if let id = selectedID, let match = list.first(where: { $0.id == id }) {
            return match
        }
        return list.first
    }

    func ensureSelection(_ triggers: [TriggerInfo]) {
        if selectedID == nil || !triggers.contains(where: { $0.id == selectedID }) {
            selectedID = triggers.first?.id
        }
    }
}

struct TriggerDetailView: View {
    let triggers: [TriggerInfo]
    let databaseType: DatabaseType
    let isLoading: Bool
    let onOpenInEditor: (TriggerInfo) -> Void

    @State private var state = TriggerInspectorState()

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
                TriggerListPane(triggers: triggers, state: state)
            } bottom: {
                TriggerDetailPane(triggers: triggers, state: state, databaseType: databaseType, onOpenInEditor: onOpenInEditor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { state.ensureSelection(triggers) }
            .onChange(of: triggers) { _, newTriggers in state.ensureSelection(newTriggers) }
        }
    }
}

private struct TriggerListPane: View {
    let triggers: [TriggerInfo]
    @Bindable var state: TriggerInspectorState

    private var showEnabled: Bool { triggers.contains { $0.enabled != nil } }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $state.searchText, placeholder: String(localized: "Filter"))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            table
        }
    }

    @ViewBuilder
    private var table: some View {
        if showEnabled {
            Table(state.displayed(triggers), selection: $state.selectedID, sortOrder: $state.sortOrder) {
                TableColumn(String(localized: "Name"), value: \.name)
                    .width(min: 140, ideal: 220)
                TableColumn(String(localized: "Timing"), value: \.timing)
                    .width(min: 70, ideal: 90)
                TableColumn(String(localized: "Event"), value: \.event)
                    .width(min: 90, ideal: 150)
                TableColumn(String(localized: "Enabled")) { trigger in
                    enabledIndicator(trigger)
                }
                .width(min: 60, ideal: 70)
            }
        } else {
            Table(state.displayed(triggers), selection: $state.selectedID, sortOrder: $state.sortOrder) {
                TableColumn(String(localized: "Name"), value: \.name)
                    .width(min: 140, ideal: 240)
                TableColumn(String(localized: "Timing"), value: \.timing)
                    .width(min: 70, ideal: 90)
                TableColumn(String(localized: "Event"), value: \.event)
                    .width(min: 90, ideal: 160)
            }
        }
    }

    @ViewBuilder
    private func enabledIndicator(_ trigger: TriggerInfo) -> some View {
        if let enabled = trigger.enabled {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? Color.green : Color.secondary)
                .accessibilityLabel(enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
        }
    }
}

private struct TriggerDetailPane: View {
    let triggers: [TriggerInfo]
    let state: TriggerInspectorState
    let databaseType: DatabaseType
    let onOpenInEditor: (TriggerInfo) -> Void

    @AppStorage("structureCodeFontSize") private var fontSize: Double = 13

    var body: some View {
        if let trigger = state.selectedTrigger(triggers) {
            VStack(spacing: 0) {
                toolbar(for: trigger)
                Divider()
                DDLTextView(ddl: trigger.statement, fontSize: $fontSize, databaseType: databaseType)
            }
        } else {
            Color(nsColor: .textBackgroundColor)
        }
    }

    private func toolbar(for trigger: TriggerInfo) -> some View {
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
