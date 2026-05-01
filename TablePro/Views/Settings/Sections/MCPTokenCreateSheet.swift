import SwiftUI

struct MCPTokenCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onGenerate: (String, TokenPermissions, Set<UUID>?, Date?) -> Void

    @State private var tokenName = ""
    @State private var permissions: TokenPermissions = .readOnly
    @State private var connectionAccess: ConnectionAccessMode = .all
    @State private var selectedConnectionIds: Set<UUID> = []
    @State private var expirationOption: ExpirationOption = .never
    @State private var customExpirationDate = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
    @State private var connections: [DatabaseConnection] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                nameSection
                permissionsSection
                connectionAccessSection
                expirationSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            actionBar
                .padding()
        }
        .frame(minWidth: 480, minHeight: 520)
        .task {
            connections = ConnectionStorage.shared.loadConnections()
        }
    }

    private var nameSection: some View {
        Section(String(localized: "Token Name")) {
            TextField(String(localized: "e.g., Claude Code on VPS"), text: $tokenName)
        }
    }

    private var permissionsSection: some View {
        Section(String(localized: "Permission Level")) {
            Picker(String(localized: "Permission"), selection: $permissions) {
                ForEach(TokenPermissions.allCases) { permission in
                    Text(permission.displayName).tag(permission)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var connectionAccessSection: some View {
        Section(String(localized: "Connection Access")) {
            Picker(String(localized: "Access"), selection: $connectionAccess) {
                Text(String(localized: "All Connections")).tag(ConnectionAccessMode.all)
                Text(String(localized: "Select Connections")).tag(ConnectionAccessMode.selected)
            }
            .labelsHidden()

            if connectionAccess == .selected {
                connectionList
            }
        }
    }

    @ViewBuilder
    private var connectionList: some View {
        if connections.isEmpty {
            Text(String(localized: "No saved connections"))
                .foregroundStyle(.secondary)
        } else {
            ForEach(connections) { connection in
                Toggle(isOn: connectionBinding(for: connection.id)) {
                    HStack(spacing: 6) {
                        Text(connection.name)
                        Text(connection.type.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var expirationSection: some View {
        Section(String(localized: "Expiration")) {
            Picker(String(localized: "Expires"), selection: $expirationOption) {
                ForEach(ExpirationOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()

            if expirationOption == .custom {
                DatePicker(
                    String(localized: "Expiration date"),
                    selection: $customExpirationDate,
                    in: Date.now...,
                    displayedComponents: .date
                )
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button(String(localized: "Cancel"), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(String(localized: "Generate")) {
                let connectionIds: Set<UUID>? = connectionAccess == .selected ? selectedConnectionIds : nil
                onGenerate(tokenName, permissions, connectionIds, resolvedExpirationDate)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(tokenName.trimmingCharacters(in: .whitespaces).isEmpty
                || (connectionAccess == .selected && selectedConnectionIds.isEmpty))
        }
    }

    private func connectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedConnectionIds.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedConnectionIds.insert(id)
                } else {
                    selectedConnectionIds.remove(id)
                }
            }
        )
    }

    private var resolvedExpirationDate: Date? {
        switch expirationOption {
        case .never: nil
        case .thirtyDays: Calendar.current.date(byAdding: .day, value: 30, to: .now)
        case .sixtyDays: Calendar.current.date(byAdding: .day, value: 60, to: .now)
        case .ninetyDays: Calendar.current.date(byAdding: .day, value: 90, to: .now)
        case .custom: customExpirationDate
        }
    }
}

private enum ConnectionAccessMode: String, Identifiable {
    case all
    case selected

    var id: String { rawValue }
}

private enum ExpirationOption: String, CaseIterable, Identifiable {
    case never
    case thirtyDays
    case sixtyDays
    case ninetyDays
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: String(localized: "Never")
        case .thirtyDays: String(localized: "30 days")
        case .sixtyDays: String(localized: "60 days")
        case .ninetyDays: String(localized: "90 days")
        case .custom: String(localized: "Custom")
        }
    }
}
