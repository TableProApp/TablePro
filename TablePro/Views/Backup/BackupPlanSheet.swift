//
//  BackupPlanSheet.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything a backup needs, on one sheet: what to include, what format, and where it goes.
///
/// One sheet rather than a chain. The HIG asks for one sheet at a time from the main interface,
/// and this flow used to present a save panel as a sub-sheet over the database picker, so the user
/// answered "which database" before seeing anything about the file and could not get back.
internal struct BackupPlanSheet: View {
    internal let model: BackupScopeModel
    internal let formats: [NativeDumpDescriptor.ArchiveFormat]
    @Binding internal var formatId: String
    @Binding internal var directory: URL
    internal let onCancel: () -> Void
    internal let onStart: () -> Void

    @State private var hostWindow: NSWindow?

    /// An engine that cannot narrow says so from the start, because the picker being off is the
    /// thing the user needs told. An engine that can says nothing until the selection is actually
    /// narrower than the whole database.
    private var caveat: String? {
        guard model.objectScope.allowsNarrowing else {
            return model.objectScope.narrowedCaveat
        }
        guard model.isNarrowed else { return nil }
        return model.objectScope.narrowedCaveat
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            scopeSection
            Divider()
            settingsSection
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .background { WindowAccessor { window in hostWindow = window } }
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Back Up")
                .font(.headline)
            Text("Each database is written to its own file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var scopeSection: some View {
        if model.isLoadingDatabases {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BackupScopeTreeView(model: model) { database in
                Task { await model.loadObjects(for: database) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let caveat {
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if formats.count > 1 {
                Picker(selection: $formatId) {
                    ForEach(formats) { option in
                        Text(option.contentDescription).tag(option.id)
                    }
                } label: {
                    Text("Format")
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack(spacing: 8) {
                Text("Save to")
                Text(directory.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .help(directory.path(percentEncoded: false))
                Spacer()
                Button(String(localized: "Choose\u{2026}")) {
                    Task { await chooseDirectory() }
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Text(model.summary())
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Back Up"), action: onStart)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRun)
        }
        .padding(16)
    }

    /// A folder, never a file, whatever the format writes.
    ///
    /// One database still produces one file, but naming it here would mean two destination controls
    /// that disagree the moment a second database is ticked. The file's own name is derived from the
    /// database and the timestamp, which is also what makes several of them land side by side
    /// without colliding.
    ///
    /// `canChooseFiles` and `canChooseDirectories` are assigned after `allowedContentTypes`, which
    /// NSOpenPanel.h says macOS 27 rewrites them from.
    @MainActor
    private func chooseDirectory() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.title = String(localized: "Choose Backup Folder")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Every database you picked is written into this folder.")

        let response: NSApplication.ModalResponse
        if let window = AlertHelper.resolveWindow(hostWindow) {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        directory = url
    }
}
