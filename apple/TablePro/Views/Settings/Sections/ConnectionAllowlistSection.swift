import SwiftUI

// Rows only, so each sheet puts them in its own card under its own header.
struct ConnectionAllowlistSection: View {
    @Binding var selection: Set<UUID>
    let connections: [DatabaseConnection]
    let showsSelectAll: Bool

    @State private var search = ""

    var body: some View {
        if connections.isEmpty {
            Text("No saved connections")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                NativeSearchField(
                    text: $search,
                    placeholder: String(localized: "Search connections"),
                    accessibilityIdentifier: "connection-allowlist-search"
                )
                if showsSelectAll {
                    Button(String(localized: "Select All")) {
                        selection.formUnion(filtered.map(\.id))
                    }
                    .disabled(filtered.isEmpty)
                    .accessibilityIdentifier("connection-allowlist-select-all")
                    Button(String(localized: "Select None")) {
                        selection.subtract(filtered.map(\.id))
                    }
                    .disabled(filtered.isEmpty)
                    .accessibilityIdentifier("connection-allowlist-select-none")
                }
            }

            if filtered.isEmpty {
                Text("No matching connections")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { connection in
                    Toggle(isOn: binding(for: connection.id)) {
                        Text(verbatim: connection.name)
                        Text(verbatim: connection.type.displayName)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var filtered: [DatabaseConnection] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return connections }
        return connections.filter { connection in
            connection.name.localizedStandardContains(query)
                || connection.type.displayName.localizedStandardContains(query)
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn {
                    selection.insert(id)
                } else {
                    selection.remove(id)
                }
            }
        )
    }
}
