import SwiftUI
import TableProMCP

struct PairingApproval: Sendable {
    let grantedPermissions: TokenPermissions
    let allowedConnectionIds: Set<UUID>?
    let expiresAt: Date?
    let extraScopes: Set<MCPScope>
}

// Hosted by AlertHelper.runPairingApproval in its own window, so it works while Settings is closed.
struct PairingApprovalSheet: View {
    private enum Access: Hashable {
        case all
        case selected
    }

    let request: PairingRequest
    let codeExpiresAt: Date
    let allowsHiddenConnectionListing: Bool
    let onComplete: (Result<PairingApproval, Error>) -> Void

    @State private var permissions: TokenPermissions
    @State private var grantsHiddenConnections = false
    @State private var access: Access = .all
    @State private var selectedConnectionIds: Set<UUID> = []
    @State private var expiry: TokenExpiry = .never
    @State private var customExpiry = TokenExpiry.defaultCustomDate()
    @State private var connections: [DatabaseConnection] = []
    @State private var isExpired: Bool

    init(
        request: PairingRequest,
        codeExpiresAt: Date,
        allowsHiddenConnectionListing: Bool,
        onComplete: @escaping (Result<PairingApproval, Error>) -> Void
    ) {
        self.request = request
        self.codeExpiresAt = codeExpiresAt
        self.allowsHiddenConnectionListing = allowsHiddenConnectionListing
        self.onComplete = onComplete
        _permissions = State(initialValue: request.scopeRequest.permissions)
        _isExpired = State(initialValue: codeExpiresAt <= .now)
        if let requested = request.requestedConnectionIds, !requested.isEmpty {
            _access = State(initialValue: .selected)
            _selectedConnectionIds = State(initialValue: requested)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                permissionsSection
                connectionsSection
                if requestsHiddenConnections {
                    hiddenConnectionsSection
                }
                expirySection
            }
            .formStyle(.grouped)
            // A grouped Form answers any proposal with the whole height, so it alone is capped (#2930).
            .frame(maxHeight: 420)

            Divider()
            actionBar.padding()
        }
        .frame(width: 520)
        .task {
            connections = ConnectionStorage.shared.loadConnections()
            if access == .all {
                selectedConnectionIds = Set(connections.map(\.id))
            }
        }
        .task {
            let remaining = codeExpiresAt.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            isExpired = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The name is whatever the request asked to be called, so its length is bounded here.
            Text(String(format: String(localized: "Allow %@ to access TablePro?"), request.clientName))
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.tail)
            Text("An external app is asking for an API token. Review the permissions before approving.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            destinationLabel
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                countdownLabel(now: timeline.date)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // The client name is the request's own label; this says who receives the grant, so it keeps the scheme and host.
    private var destinationLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(String(format: String(localized: "Sends the code to %@"), request.redirectDisplayValue))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func countdownLabel(now: Date) -> some View {
        let remaining = max(0, Int(codeExpiresAt.timeIntervalSince(now).rounded(.up)))
        let expired = isExpired || remaining == 0
        return HStack(spacing: 6) {
            Image(systemName: expired ? "clock.badge.exclamationmark.fill" : "clock")
                .foregroundStyle(expired ? Color.red : Color.secondary)
                .imageScale(.small)
                .accessibilityHidden(true)
            Group {
                if expired {
                    Text("Code expired")
                } else {
                    Text("Code expires in ^[\(remaining) second](inflect: true)")
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
        }
    }

    private var permissionsSection: some View {
        Section {
            Picker(selection: $permissions) {
                ForEach(TokenPermissions.allCases) { permission in
                    Text(permission.displayName).tag(permission)
                }
            } label: {
                Text("Permissions")
                Text(permissions.summary)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pairing-permissions-picker")
        }
    }

    private var connectionsSection: some View {
        Section {
            Picker(selection: $access) {
                Text("All").tag(Access.all)
                Text("Selected").tag(Access.selected)
            } label: {
                Text("Connections")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("pairing-connections-picker")
            .onChange(of: access) { newValue in
                if newValue == .all || selectedConnectionIds.isEmpty {
                    selectedConnectionIds = Set(connections.map(\.id))
                }
            }

            if access == .selected {
                ConnectionAllowlistSection(
                    selection: $selectedConnectionIds,
                    connections: connections,
                    showsSelectAll: true
                )
            }
        }
    }

    private var requestsHiddenConnections: Bool {
        request.scopeRequest.optionalGrants.contains(.connectionsDisplay)
    }

    // Off even when allowed: an agent with a shell can pair to its own redirect, and one Approve must not hand it these.
    private var hiddenConnectionsSection: some View {
        Section {
            if allowsHiddenConnectionListing {
                Toggle(isOn: $grantsHiddenConnections) {
                    Text("List connections hidden from AI")
                    Text("Adds connections whose AI Policy is Never to this app's list, with each user name. The app still cannot query them. Blocked connections stay hidden.")
                }
                .accessibilityIdentifier("pairing-hidden-connections-toggle")
            } else {
                // swiftlint:disable:next line_length
                Text("This app also asks to list connections hidden from AI. To allow that, turn on “Allow apps to list connections hidden from AI” in Settings > MCP, then pair again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairing-hidden-connections-refusal")
            }
        } header: {
            Text("Connections Hidden from AI")
        }
    }

    private var expirySection: some View {
        Section {
            Picker(selection: $expiry) {
                ForEach(TokenExpiry.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                Text("Expires")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("pairing-expiry-picker")

            if expiry == .custom {
                DatePicker(
                    String(localized: "Expiration date"),
                    selection: $customExpiry,
                    in: Date.now...,
                    displayedComponents: .date
                )
            }
        }
    }

    private var actionBar: some View {
        DialogFooter {
            Button(String(localized: "Approve")) {
                let approval = PairingApproval(
                    grantedPermissions: permissions,
                    allowedConnectionIds: access == .selected ? selectedConnectionIds : nil,
                    expiresAt: expiry.resolvedDate(custom: customExpiry),
                    extraScopes: grantsHiddenConnections && allowsHiddenConnectionListing ? [.connectionsDisplay] : []
                )
                onComplete(.success(approval))
            }
            .disabled(approveDisabled)

            Button(String(localized: "Deny"), role: .cancel) {
                onComplete(.failure(DatabaseAccessError.userCancelled))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var approveDisabled: Bool {
        if isExpired { return true }
        if access == .selected && selectedConnectionIds.isEmpty { return true }
        return false
    }
}
