//
//  HostListFieldRow.swift
//  TablePro
//

import SwiftUI

struct HostEntry: Identifiable {
    let id = UUID()
    var host: String
    var port: String
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
                        TextField("", text: $entry.host, prompt: Text("hostname"))
                            .onChange(of: entry.host) { syncValue() }

                        TextField("", text: $entry.port, prompt: Text(String(defaultPort)))
                            .frame(width: 60)
                            .onChange(of: entry.port) { syncValue() }

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
            if existing.host != new.host || existing.port != new.port { return false }
        }
        return true
    }

    private func syncValue() {
        let result = entries.map { entry -> String in
            let h = entry.host.trimmingCharacters(in: .whitespaces)
            let p = entry.port.trimmingCharacters(in: .whitespaces)
            let effectiveHost = h.isEmpty ? "localhost" : h
            let effectivePort = p.isEmpty ? String(defaultPort) : p
            return "\(effectiveHost):\(effectivePort)"
        }.joined(separator: ",")
        if value != result {
            value = result
        }
    }

    private func addEntry() {
        entries.append(HostEntry(host: "", port: String(defaultPort)))
        syncValue()
    }

    private func removeEntry(_ entry: HostEntry) {
        entries.removeAll { $0.id == entry.id }
        if entries.isEmpty {
            entries.append(HostEntry(host: "", port: String(defaultPort)))
        }
        syncValue()
    }

    static func parseHosts(_ value: String, defaultPort: Int) -> [HostEntry] {
        guard !value.isEmpty else {
            return [HostEntry(host: "", port: String(defaultPort))]
        }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        var result: [HostEntry] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let components = trimmed.split(separator: ":", maxSplits: 1)
            let host = components.isEmpty ? "" : String(components[0])
            let port = components.count > 1 ? String(components[1]) : String(defaultPort)
            result.append(HostEntry(host: host, port: port))
        }
        return result.isEmpty ? [HostEntry(host: "", port: String(defaultPort))] : result
    }
}
