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

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 6) {
                ForEach($entries) { $entry in
                    HStack(spacing: 6) {
                        TextField(
                            "",
                            text: $entry.value,
                            prompt: Text("hostname:\(defaultPort)")
                        )
                        .onChange(of: entry.value) { syncValue() }

                        Button {
                            removeEntry(entry)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(entries.count <= 1)
                        .opacity(entries.count <= 1 ? 0.3 : 1)
                    }
                }

                Button {
                    addEntry()
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        } label: {
            Text(label)
        }
        .onAppear { parseValue() }
        .onChange(of: value) { parseValue() }
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
        entries.append(HostEntry(value: ""))
        syncValue()
    }

    private func removeEntry(_ entry: HostEntry) {
        entries.removeAll { $0.id == entry.id }
        if entries.isEmpty {
            entries.append(HostEntry(value: ""))
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
