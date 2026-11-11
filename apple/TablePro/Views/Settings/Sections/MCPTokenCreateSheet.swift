import SwiftUI

struct MCPTokenCreateFailure: Equatable, Sendable {
    let message: String
    // Nothing in this sheet can fix a server that is not running, so the alert closes it.
    let endsSheet: Bool
}

struct MCPTokenCreateSheet: View {
    private enum Field: Hashable {
        case name
    }

    @Environment(\.dismiss) private var dismiss
    let onGenerate: (String, TokenPermissions, Set<UUID>?, Date?) async -> MCPTokenCreateFailure?

    @State private var tokenName = ""
    @State private var permissions: TokenPermissions = .readOnly
    @State private var connectionAccess: ConnectionAccessMode = .all
    @State private var selectedConnectionIds: Set<UUID> = []
    @State private var expirationOption: ExpirationOption = .never
    @State private var customExpirationDate = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
    @State private var connections: [DatabaseConnection] = []
    @State private var isGenerating = false
    @State private var failure: MCPTokenCreateFailure?
    @FocusState private var focused: Field?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                nameSection
                permissionsSection
                connectionAccessSection
                expirationSection
            }
            .formStyle(.grouped)

            Divider()

            actionBar
                .padding()
        }
        .frame(minWidth: 480, minHeight: 520)
        .task {
            connections = ConnectionStorage.shared.loadConnections()
        }
        .alert(
            String(localized: "Couldn't Create the Token"),
            isPresented: failureBinding,
            presenting: failure
        ) { failure in
            Button(String(localized: "OK")) {
                self.failure = nil
                if failure.endsSheet {
                    dismiss()
                }
            }
        } message: { failure in
            Text(verbatim: failure.message)
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { failure != nil },
            set: { isPresented in
                if !isPresented {
                    failure = nil
                }
            }
        )
    }

    private var nameSection: some View {
        Section(String(localized: "Token Name")) {
            TextField(String(localized: "e.g., Cursor on my Mac"), text: $tokenName)
                .focused($focused, equals: .name)
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
        DialogFooter {
            Button(String(localized: "Cancel"), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Generate")) {
                let connectionIds: Set<UUID>? = connectionAccess == .selected ? selectedConnectionIds : nil
                isGenerating = true
                Task {
                    failure = await onGenerate(tokenName, permissions, connectionIds, resolvedExpirationDate)
                    isGenerating = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isGenerating
                || tokenName.trimmingCharacters(in: .whitespaces).isEmpty
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
