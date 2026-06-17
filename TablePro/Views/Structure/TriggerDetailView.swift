import SwiftUI

struct TriggerDetailView: View {
    let triggers: [TriggerInfo]
    @Binding var selectedTriggerID: TriggerInfo.ID?
    @Binding var fontSize: CGFloat
    let databaseType: DatabaseType
    let isLoading: Bool
    let onOpenInEditor: (TriggerInfo) -> Void

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if triggers.isEmpty {
            EmptyStateView.triggers()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VSplitView {
                triggerTable
                    .frame(minHeight: 120, idealHeight: 170)
                detailPane
                    .frame(minHeight: 180)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: ensureSelection)
            .onChange(of: triggers) { _, _ in ensureSelection() }
        }
    }

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

    private var triggerTable: some View {
        Table(triggers, selection: $selectedTriggerID) {
            TableColumn(String(localized: "Name"), value: \.name)
                .width(min: 160, ideal: 240)
            TableColumn(String(localized: "Timing"), value: \.timing)
                .width(min: 70, ideal: 90)
            TableColumn(String(localized: "Event"), value: \.event)
                .width(min: 90, ideal: 140)
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
