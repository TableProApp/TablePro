//
//  PairingApprovalSheet.swift
//  TablePro
//

import SwiftUI

struct PairingApproval: Sendable {
    let grantedPermissions: TokenPermissions
    let allowedConnectionIds: Set<UUID>?
    let expiresAt: Date?
}

struct PairingApprovalSheet: View {
    let request: PairingRequest
    let onComplete: (Result<PairingApproval, Error>) -> Void

    @State private var permissions: TokenPermissions
    @State private var connectionAccess: ConnectionAccessMode = .all
    @State private var selectedConnectionIds: Set<UUID> = []
    @State private var expiry: ExpiryOption = .never
    @State private var connections: [DatabaseConnection] = []

    init(request: PairingRequest, onComplete: @escaping (Result<PairingApproval, Error>) -> Void) {
        self.request = request
        self.onComplete = onComplete
        let initialPermissions = Self.initialPermissions(from: request)
        _permissions = State(initialValue: initialPermissions)
        if let requested = request.requestedConnectionIds, !requested.isEmpty {
            _connectionAccess = State(initialValue: .selected)
            _selectedConnectionIds = State(initialValue: requested)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                permissionsSection
                connectionAccessSection
                expirySection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            actionBar.padding()
        }
        .frame(width: 520, height: 560)
        .task {
            connections = ConnectionStorage.shared.loadConnections()
            if connectionAccess == .all {
                selectedConnectionIds = Set(connections.map(\.id))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: String(localized: "Allow %@ to access TablePro?"), request.clientName))
                .font(.headline)
            Text(String(localized: "An external app is asking for an API token. Review the permissions before approving."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
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

            Text(permissionsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionAccessSection: some View {
        Section(String(localized: "Allowed Connections")) {
            Picker(String(localized: "Access"), selection: $connectionAccess) {
                Text(String(localized: "All Connections")).tag(ConnectionAccessMode.all)
                Text(String(localized: "Select Connections")).tag(ConnectionAccessMode.selected)
            }
            .labelsHidden()
            .onChange(of: connectionAccess) { _, newValue in
                if newValue == .all {
                    selectedConnectionIds = Set(connections.map(\.id))
                } else if selectedConnectionIds.isEmpty {
                    selectedConnectionIds = Set(connections.map(\.id))
                }
            }

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

    private var expirySection: some View {
        Section(String(localized: "Expiration")) {
            Picker(String(localized: "Expires"), selection: $expiry) {
                ForEach(ExpiryOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
        }
    }

    private var actionBar: some View {
        HStack {
            Button(String(localized: "Deny"), role: .cancel) {
                onComplete(.failure(MCPError.userCancelled))
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(String(localized: "Approve")) {
                let approval = PairingApproval(
                    grantedPermissions: permissions,
                    allowedConnectionIds: connectionAccess == .selected ? selectedConnectionIds : nil,
                    expiresAt: expiry.resolvedDate
                )
                onComplete(.success(approval))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(connectionAccess == .selected && selectedConnectionIds.isEmpty)
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

    private var permissionsDescription: String {
        switch permissions {
        case .readOnly:
            String(localized: "Read schema and run SELECT queries.")
        case .readWrite:
            String(localized: "Read schema and run any non-destructive query, including INSERT, UPDATE, and DELETE.")
        case .fullAccess:
            String(localized: "Full access including destructive DDL after explicit confirmation.")
        }
    }

    private static func initialPermissions(from request: PairingRequest) -> TokenPermissions {
        guard let raw = request.requestedScopes?.lowercased() else { return .readOnly }
        switch raw {
        case "readwrite", "read_write", "read-write":
            return .readWrite
        case "fullaccess", "full_access", "full-access", "full":
            return .fullAccess
        default:
            return .readOnly
        }
    }
}

private enum ConnectionAccessMode: String, Identifiable, Sendable {
    case all
    case selected

    var id: String { rawValue }
}

private enum ExpiryOption: String, CaseIterable, Identifiable, Sendable {
    case never
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: String(localized: "Never")
        case .oneDay: String(localized: "1 day")
        case .sevenDays: String(localized: "7 days")
        case .thirtyDays: String(localized: "30 days")
        case .ninetyDays: String(localized: "90 days")
        }
    }

    var resolvedDate: Date? {
        switch self {
        case .never: nil
        case .oneDay: Calendar.current.date(byAdding: .day, value: 1, to: .now)
        case .sevenDays: Calendar.current.date(byAdding: .day, value: 7, to: .now)
        case .thirtyDays: Calendar.current.date(byAdding: .day, value: 30, to: .now)
        case .ninetyDays: Calendar.current.date(byAdding: .day, value: 90, to: .now)
        }
    }
}
