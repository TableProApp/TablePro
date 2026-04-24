//
//  HostListFieldRow.swift
//  TablePro
//

import SwiftUI

struct HostEntry: Identifiable {
    let id = UUID()
    var value: String
}

struct HostListFieldRow: View {
    let label: String
    let placeholder: String
    let defaultPort: Int
    @Binding var value: String

    @State private var entries: [HostEntry] = []
    @State private var selectedId: UUID?

    var body: some View {
        LabeledContent {
            VStack(spacing: 0) {
                list
                Divider()
                buttonBar
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        } label: {
            Text(label)
        }
        .onAppear { parseValue() }
        .onChange(of: value) { parseValue() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    entryRow(entry, index: index)
                }
            }
        }
        .frame(minHeight: 28, maxHeight: 88)
    }

    private func entryRow(_ entry: HostEntry, index: Int) -> some View {
        let isSelected = selectedId == entry.id
        return VStack(spacing: 0) {
            if index > 0 {
                Divider().padding(.horizontal, 1)
            }
            TextField(
                "",
                text: bindingForEntry(entry),
                prompt: Text("hostname:\(defaultPort)")
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { selectedId = entry.id }
        }
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

    private var buttonBar: some View {
        HStack(spacing: 0) {
            Button { addEntry() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 14)

            Button { removeSelected() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selectedId == nil || entries.count <= 1)

            Spacer()
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private func parseValue() {
        let parsed = Self.parseHosts(value, defaultPort: defaultPort)
        if !entriesMatch(parsed) {
            entries = parsed
            if selectedId == nil, let first = parsed.first {
                selectedId = first.id
            }
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
            let trimmed = entry.value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return "localhost:\(defaultPort)"
            }
            if !trimmed.contains(":") {
                return "\(trimmed):\(defaultPort)"
            }
            return trimmed
        }.joined(separator: ",")
        if value != result {
            value = result
        }
    }

    private func addEntry() {
        let newEntry = HostEntry(value: "")
        entries.append(newEntry)
        selectedId = newEntry.id
        syncValue()
    }

    private func removeSelected() {
        guard let id = selectedId, entries.count > 1 else { return }
        entries.removeAll { $0.id == id }
        selectedId = entries.last?.id
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
