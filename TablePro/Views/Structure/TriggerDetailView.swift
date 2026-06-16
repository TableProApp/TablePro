import SwiftUI

struct TriggerDetailView: View {
    let triggers: [TriggerInfo]
    @Binding var selectedName: String?
    @Binding var fontSize: CGFloat
    let databaseType: DatabaseType
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if triggers.isEmpty {
            emptyState
        } else {
            HSplitView {
                triggerList
                    .frame(minWidth: 200, idealWidth: 260)
                detailPanel
                    .frame(minWidth: 320)
            }
            .onAppear(perform: ensureSelection)
            .onChange(of: triggers) { _, _ in ensureSelection() }
        }
    }

    private var selectedTrigger: TriggerInfo? {
        guard let name = selectedName,
              let match = triggers.first(where: { $0.name == name }) else {
            return triggers.first
        }
        return match
    }

    private func ensureSelection() {
        guard let name = selectedName,
              triggers.contains(where: { $0.name == name }) else {
            selectedName = triggers.first?.name
            return
        }
    }

    private var triggerList: some View {
        List(triggers, id: \.name, selection: $selectedName) { trigger in
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.name)
                HStack(spacing: 6) {
                    if !trigger.timing.isEmpty {
                        Text(trigger.timing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !trigger.event.isEmpty {
                        Text(trigger.event)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private var detailPanel: some View {
        VStack(spacing: 0) {
            if let trigger = selectedTrigger {
                detailToolbar(for: trigger)
                Divider()
                DDLTextView(ddl: trigger.statement, fontSize: $fontSize, databaseType: databaseType)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
    }

    private func detailToolbar(for trigger: TriggerInfo) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button(action: { fontSize = max(10, fontSize - 1) }) {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(String(localized: "Decrease font size"))
                Text("\(Int(fontSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Button(action: { fontSize = min(24, fontSize + 1) }) {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel(String(localized: "Increase font size"))
            }
            .buttonStyle(.borderless)

            Spacer()

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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No triggers")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
