//
//  ConnectionInfoView.swift
//  TableProMobile
//

import SwiftUI
import TableProDatabase
import TableProModels

struct ConnectionInfoView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState

    private var connection: DatabaseConnection { coordinator.connection }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(connection.name.isEmpty ? connection.host : connection.name)
                } label: {
                    HStack(spacing: 8) {
                        DatabaseIconView(type: connection.type, size: 18)
                            .frame(width: 28, height: 28)
                            .background(DatabaseIconView.color(for: connection.type).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Name")
                    }
                }
                LabeledContent("Type", value: typeDisplayName)
                if connection.safeModeLevel != .off {
                    LabeledContent("Safe Mode") {
                        Label {
                            Text(connection.safeModeLevel.displayName)
                        } icon: {
                            Image(systemName: connection.safeModeLevel == .readOnly ? "lock.fill" : "shield.fill")
                                .foregroundStyle(connection.safeModeLevel == .readOnly ? .red : .orange)
                        }
                    }
                }
            }

            if connection.type != .sqlite {
                serverSection
                if connection.sshEnabled, let ssh = connection.sshConfiguration {
                    sshSection(ssh)
                }
            } else {
                sqliteFileSection
            }

            statsSection
        }
        .navigationTitle("Info")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { coordinator.showingEditSheet },
            set: { coordinator.showingEditSheet = $0 }
        )) {
            ConnectionFormView(editing: connection) { updated in
                appState.updateConnection(updated)
                coordinator.showingEditSheet = false
            }
        }
    }

    private var typeDisplayName: String {
        switch connection.type {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        case .redshift: "Redshift"
        case .sqlite: "SQLite"
        case .redis: "Redis"
        default: connection.type.rawValue.uppercased()
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            LabeledContent("Host") {
                Text(verbatim: "\(connection.host):\(connection.port)")
                    .textSelection(.enabled)
            }
            if !connection.username.isEmpty {
                LabeledContent("Username") {
                    Text(connection.username).textSelection(.enabled)
                }
            }
            HStack {
                Text("SSL")
                Spacer()
                if connection.sslEnabled {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityLabel(Text("Enabled"))
                } else {
                    Text("Off")
                        .foregroundStyle(.secondary)
                }
            }
            if !activeDatabaseLabel.isEmpty {
                LabeledContent(coordinator.activeDatabase.isEmpty ? "Default DB" : "Active DB", value: activeDatabaseLabel)
            }
            if coordinator.supportsSchemas, !coordinator.activeSchema.isEmpty {
                LabeledContent("Schema", value: coordinator.activeSchema)
            }
        }
    }

    private var activeDatabaseLabel: String {
        if !coordinator.activeDatabase.isEmpty { return coordinator.activeDatabase }
        return connection.database
    }

    @ViewBuilder
    private func sshSection(_ ssh: SSHConfiguration) -> some View {
        Section("SSH Tunnel") {
            LabeledContent("SSH Host") {
                Text(verbatim: "\(ssh.host):\(ssh.port)")
                    .textSelection(.enabled)
            }
            LabeledContent("SSH Username", value: ssh.username)
            LabeledContent("Auth", value: ssh.authMethod == .password ? "Password" : "Private Key")
        }
    }

    @ViewBuilder
    private var sqliteFileSection: some View {
        Section("File") {
            let url = URL(fileURLWithPath: connection.database)
            LabeledContent("Name", value: url.lastPathComponent)
            LabeledContent("Path") {
                Text(connection.database)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        Section("Stats") {
            LabeledContent("Tables", value: "\(coordinator.tables.count)")
            if coordinator.supportsDatabaseSwitching, !coordinator.databases.isEmpty {
                LabeledContent("Databases", value: "\(coordinator.databases.count)")
            }
            if coordinator.supportsSchemas, !coordinator.schemas.isEmpty {
                LabeledContent("Schemas", value: "\(coordinator.schemas.count)")
            }
            HStack {
                Text("Status")
                Spacer()
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.caption)
                Text(statusText)
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusIcon: String {
        switch coordinator.phase {
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch coordinator.phase {
        case .connecting: .secondary
        case .connected: .green
        case .error: .red
        }
    }

    private var statusText: String {
        switch coordinator.phase {
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Connected")
        case .error: String(localized: "Disconnected")
        }
    }
}
