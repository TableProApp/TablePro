//
//  DeeplinkImportSheet.swift
//  TablePro
//

import SwiftUI
import TableProImport

struct DeeplinkImportSheet: View {
    let bundle: ConnectionBundle
    let onFinished: (ImportOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editableName: String
    @State private var analyzedRow: ConnectionRow?
    @State private var libraryError: String?
    @State private var isImporting = false

    init(bundle: ConnectionBundle, onFinished: @escaping (ImportOutcome) -> Void) {
        self.bundle = bundle
        self.onFinished = onFinished
        _editableName = State(initialValue: bundle.connections.first?.settings.name ?? "")
    }

    private var entry: BundleConnection? {
        bundle.connections.first
    }

    private var trimmedName: String {
        editableName.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let entry {
                form(for: entry)
            }

            Divider()

            DialogFooter {
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button(analyzedRow?.duplicate == nil ? String(localized: "Add Connection") : String(localized: "Add as Copy")) {
                    isImporting = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry == nil || trimmedName.isEmpty || libraryError != nil || isImporting)
            }
            .padding()
        }
        .frame(width: 420)
        .frame(maxHeight: 560)
        .task { await analyze() }
        .task(id: isImporting) {
            guard isImporting else { return }
            await performImport()
            isImporting = false
        }
    }

    private func form(for entry: BundleConnection) -> some View {
        let connection = entry.settings
        return Form {
            Section {
                HStack(spacing: 10) {
                    DatabaseType(rawValue: connection.type).iconImage
                        .frame(width: 28, height: 28)
                    Text(DatabaseType(rawValue: connection.type).displayName)
                        .font(.headline)
                }
            }

            Section(String(localized: "Connection")) {
                TextField(String(localized: "Name"), text: $editableName)

                LabeledContent(String(localized: "Host")) {
                    Text(Self.hostDisplay(connection))
                        .foregroundStyle(.secondary)
                }

                if !connection.database.isEmpty {
                    LabeledContent(String(localized: "Database")) {
                        Text(connection.database)
                            .foregroundStyle(.secondary)
                    }
                }

                if !connection.username.isEmpty {
                    LabeledContent(String(localized: "Username")) {
                        Text(connection.username)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let ssh = connection.sshConfig {
                sshSection(ssh)
            }

            if let ssl = connection.sslConfig {
                Section("SSL") {
                    LabeledContent(String(localized: "Mode")) {
                        Text(ssl.mode)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            metadataSection(entry)

            startupCommandsSection(connection)

            optionsSection(connection)

            noticesSection
        }
        .formStyle(.grouped)
    }

    private static func hostDisplay(_ connection: ExportableConnection) -> String {
        connection.port > 0 ? "\(connection.host):\(connection.port)" : connection.host
    }

    private static func formatSSHHost(_ ssh: ExportableSSHConfig) -> String {
        if let port = ssh.port, port != 22 {
            return "\(ssh.host):\(port)"
        }
        return ssh.host
    }

    private static func formatJumpHosts(_ ssh: ExportableSSHConfig) -> String? {
        let hops = (ssh.jumpHosts ?? []).filter { !$0.host.isEmpty }
        guard !hops.isEmpty else { return nil }
        return hops
            .map { hop in
                let port = hop.port ?? 22
                return hop.username.isEmpty ? "\(hop.host):\(port)" : "\(hop.username)@\(hop.host):\(port)"
            }
            .joined(separator: ", ")
    }

    private func sshSection(_ ssh: ExportableSSHConfig) -> some View {
        Section("SSH") {
            LabeledContent(String(localized: "Host")) {
                Text(Self.formatSSHHost(ssh))
                    .foregroundStyle(.secondary)
            }
            if !ssh.username.isEmpty {
                LabeledContent(String(localized: "User")) {
                    Text(ssh.username)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent(String(localized: "Auth")) {
                Text(ssh.authMethod)
                    .foregroundStyle(.secondary)
            }
            if let jumpHosts = Self.formatJumpHosts(ssh) {
                LabeledContent(String(localized: "Jump Hosts")) {
                    Text(jumpHosts)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func startupCommandsSection(_ connection: ExportableConnection) -> some View {
        if let startupCommands = connection.startupCommands,
           !startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section {
                Label(
                    String(localized: "This connection runs SQL every time it connects, using your credentials."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)

                Text(startupCommands)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Startup SQL")
            }
        }
    }

    @ViewBuilder
    private func optionsSection(_ connection: ExportableConnection) -> some View {
        if let fields = connection.additionalFields, !fields.isEmpty {
            Section(String(localized: "Driver Options")) {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        Text(fields[key] ?? "")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataSection(_ entry: BundleConnection) -> some View {
        let color = Self.displayColor(entry.settings.color)
        let groupPath = bundle.groupChain(entry.groupRef).map(\.name)
        if color != nil || !entry.tagNames.isEmpty || !groupPath.isEmpty {
            Section {
                if let color {
                    LabeledContent(String(localized: "Color")) {
                        Circle()
                            .fill(color.color)
                            .frame(width: 12, height: 12)
                    }
                }
                if !entry.tagNames.isEmpty {
                    LabeledContent(entry.tagNames.count == 1 ? String(localized: "Tag") : String(localized: "Tags")) {
                        Text(entry.tagNames.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                }
                if !groupPath.isEmpty {
                    LabeledContent(String(localized: "Group")) {
                        Text(groupPath.joined(separator: " / ")).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private static func displayColor(_ raw: String?) -> ConnectionColor? {
        guard let raw, let color = ConnectionColor(rawValue: raw), color != ConnectionColor.none else { return nil }
        return color
    }

    @ViewBuilder
    private var noticesSection: some View {
        let notices = Self.notices(for: analyzedRow, libraryError: libraryError)
        if !notices.isEmpty {
            Section {
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    static func notices(for row: ConnectionRow?, libraryError: String?) -> [String] {
        if let libraryError {
            return [libraryError]
        }
        guard let row else { return [] }
        var notices: [String] = []
        if let duplicate = row.duplicate {
            notices.append(String(format: String(localized: "A connection to this server is already saved as “%@”."), duplicate.name))
        }
        return notices + ImportConnectionRowView.notes(for: row)
    }

    private func analyze() async {
        guard analyzedRow == nil, libraryError == nil else { return }
        do {
            let preview = try await ImportReviewLoader.preview(of: CollectedImport(bundle: bundle, source: .link))
            analyzedRow = preview.connections.first
        } catch {
            libraryError = ImportReviewLoader.message(for: error)
        }
    }

    private func performImport() async {
        guard let entry, !trimmedName.isEmpty else { return }
        var settings = entry.settings
        settings.name = trimmedName
        let edited = bundle.replacingSettings(settings, of: entry.ref)
        do {
            let preview = try await ImportReviewLoader.preview(of: CollectedImport(bundle: edited, source: .link))
            guard !Task.isCancelled else { return }
            let review = ImportReview(preview: preview)
            for row in preview.connections {
                review.setSelected(true, row)
            }
            // The parser drops a link's tunnel command; its startup SQL is shown in this sheet before Add.
            let outcome = await review.commit(keepingCommands: true)
            onFinished(outcome)
        } catch {
            libraryError = ImportReviewLoader.message(for: error)
        }
    }
}
