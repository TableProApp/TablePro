//
//  HostListFieldRow.swift
//  TablePro
//

import SwiftUI

struct HostEntry: Identifiable {
    let id = UUID()
    var value: String
}

/// Selection arithmetic for `HostListFieldRow`.
///
/// `List(selection:)` with an empty `Set` after a row deletion leaves SwiftUI's
/// selection state stuck, so subsequent clicks on remaining rows do not register
/// until the parent view forces a redraw. This mirrors `NSTableView` HIG
/// behaviour by moving selection to the row that takes the removed row's place.
enum HostListSelection {
    static func nextSelection(
        afterRemoving removedIds: Set<UUID>,
        from entries: [HostEntry]
    ) -> Set<UUID> {
        guard let firstRemoveIndex = entries.firstIndex(where: { removedIds.contains($0.id) }) else {
            return []
        }
        let remaining = entries.filter { !removedIds.contains($0.id) }
        guard !remaining.isEmpty else { return [] }
        let nextIndex = min(firstRemoveIndex, remaining.count - 1)
        return [remaining[nextIndex].id]
    }
}

struct HostListFieldRow: View {
    let label: String
    let placeholder: String
    let defaultPort: Int
    @Binding var value: String

    @State private var entries: [HostEntry] = []
    @State private var selectedId: Set<UUID> = []

    var body: some View {
        LabeledContent {
            List(selection: $selectedId) {
                ForEach(entries) { entry in
                    TextField("", text: bindingForEntry(entry), prompt: Text(verbatim: "hostname:\(defaultPort)"))
                        .tag(entry.id)
                        .accessibilityLabel(String(localized: "Host"))
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: listHeight)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 0) {
                        Button { addEntry() } label: {
                            Image(systemName: "plus")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.borderless)

                        Divider().frame(height: 14)

                        Button { removeSelected() } label: {
                            Image(systemName: "minus")
                                .frame(width: 24, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .disabled(selectedId.isEmpty || entries.count <= 1)

                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .background(.bar)
            }
        } label: {
            Text(label)
        }
        .onAppear { parseValue() }
        .onChange(of: value) { parseValue() }
    }

    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 24
        let rows = CGFloat(max(entries.count, 1))
        let buttonBarHeight: CGFloat = 28
        return min(rows * rowHeight + buttonBarHeight + 8, 140)
    }

    private func bindingForEntry(_ entry: HostEntry) -> Binding<String> {
        Binding(
            get: {
                entries.first { $0.id == entry.id }?.value ?? ""
            },
            set: { newValue in
                if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[idx].value = newValue
                    syncValue()
                }
            }
        )
    }

    private func parseValue() {
        let parsed = Self.parseHosts(value, defaultPort: defaultPort)
        if !entriesMatch(parsed) {
            entries = parsed
        }
    }

    private func entriesMatch(_ parsed: [HostEntry]) -> Bool {
        guard entries.count == parsed.count else { return false }
        for (existing, new) in zip(entries, parsed) {
            if existing.value != new.value { return false }
        }
        return true
    }

    private func syncValue() {
        let result = entries.map { entry -> String in
            entry.value.trimmingCharacters(in: .whitespaces)
        }.joined(separator: ",")
        if value != result {
            value = result
        }
    }

    private func addEntry() {
        let newEntry = HostEntry(value: "")
        entries.append(newEntry)
        selectedId = [newEntry.id]
        syncValue()
    }

    private func removeSelected() {
        guard !selectedId.isEmpty, entries.count > 1 else { return }
        let nextSelection = HostListSelection.nextSelection(
            afterRemoving: selectedId,
            from: entries
        )
        entries.removeAll { selectedId.contains($0.id) }
        if entries.isEmpty {
            entries.append(HostEntry(value: ""))
            selectedId = []
        } else {
            selectedId = nextSelection
        }
        syncValue()
    }

    static func parseHosts(_ value: String, defaultPort: Int) -> [HostEntry] {
        guard !value.isEmpty else {
            return [HostEntry(value: "")]
        }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        let result = parts.map { part in
            HostEntry(value: String(part).trimmingCharacters(in: .whitespaces))
        }
        return result.isEmpty ? [HostEntry(value: "")] : result
    }
}
