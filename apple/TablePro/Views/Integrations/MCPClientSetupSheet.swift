import AppKit
import SwiftUI

struct MCPClientSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var service = MCPClientSetupService()
    @ObservedObject private var manager = MCPServerManager.shared
    @State private var selection: String?
    @State private var removeCandidate: MCPClientRow?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 680, height: sheetHeight)
        .onExitCommand { dismiss() }
        .task { await service.refresh() }
        // The sheet says "<Client> connected" from the client list, which updates only while a view polls it.
        .task { await manager.refreshClientsWhileShown() }
        .confirmationDialog(
            removeTitle,
            isPresented: removeBinding,
            titleVisibility: .visible,
            presenting: removeCandidate
        ) { row in
            Button(String(localized: "Remove"), role: .destructive) {
                selection = row.id
                Task { await service.remove(row.id) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { row in
            Text(verbatim: removeMessage(for: row))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Connect a Client"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "Install adds TablePro to a client on this Mac. Select a client to see its settings and set it up by hand."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if service.isAppOnReadOnlyVolume {
                NoticeLabel(String(localized: "TablePro is running from a disk image or a temporary location. Move it to the Applications folder first, then open it from there."))
                    .font(.callout)
            }
            if isServerDown {
                NoticeLabel(String(localized: "The MCP server is not running, so clients you add cannot connect yet. Turn it on in Settings > MCP."))
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if !service.isCatalogAvailable {
            UnavailableStateView(
                String(localized: "Client List Unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text(String(localized: "TablePro could not read its list of clients. Reinstall TablePro to restore it."))
            )
        } else if !service.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            clientList
                .frame(maxHeight: .infinity)
            Divider()
            detail
                .frame(height: sheetHeight >= 700 ? 260 : 190)
        }
    }

    private var clientList: some View {
        List(selection: $selection) {
            if !foundRows.isEmpty {
                Section(String(localized: "On This Mac")) {
                    ForEach(foundRows) { row in
                        clientRow(row)
                    }
                }
            }
            if !otherRows.isEmpty {
                Section(String(localized: "Other Clients")) {
                    ForEach(otherRows) { row in
                        clientRow(row)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .onDeleteCommand {
            if let row = selectedRow, row.removeRoute != nil {
                removeCandidate = row
            }
        }
    }

    private func clientRow(_ row: MCPClientRow) -> some View {
        MCPClientSetupRowView(
            row: row,
            presentation: service.presentation(for: row),
            actionsDisabled: service.isAppOnReadOnlyVolume,
            onAction: { action in perform(action, on: row) }
        )
        .tag(row.id)
        .contextMenu { contextMenu(for: row) }
    }

    @ViewBuilder
    private func contextMenu(for row: MCPClientRow) -> some View {
        if let action = service.presentation(for: row).action, action != .copy {
            Button(action.title) { perform(action, on: row) }
                .disabled(service.isAppOnReadOnlyVolume)
        }
        if let snippet = row.snippet {
            Button(String(localized: "Copy Configuration")) { copy(snippet) }
        }
        if let commandLine = row.commandLine {
            Button(String(localized: "Copy Command")) { copy(commandLine) }
        }
        if row.configPath != nil {
            Button(String(localized: "Show in Finder")) { reveal(row) }
                .disabled(!canReveal(row))
        }
        if row.removeRoute != nil {
            Divider()
            Button(String(localized: "Remove…"), role: .destructive) { removeCandidate = row }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailContent(for: row)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(String(localized: "Select a client to see how TablePro connects to it."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detailContent(for row: MCPClientRow) -> some View {
        Text(verbatim: row.name)
            .font(.headline)
        if let unsupported = row.unsupported {
            Text(verbatim: MCPClientDetailText.unsupported(unsupported, name: row.name))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if case let .failed(_, message, output)? = service.activities[row.id] {
                NoticeLabel(message, severity: .error)
                if let output {
                    CopyableCodeBlock(text: output)
                }
            }
            if let note = MCPClientDetailText.configState(row.config, name: row.name) {
                Text(verbatim: note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let applies = row.applies {
                Text(verbatim: MCPClientDetailText.applies(applies, name: row.name))
                    .foregroundStyle(.secondary)
            }
            if let path = row.displayConfigPath {
                LabeledContent(String(localized: "Settings file")) {
                    HStack(spacing: 8) {
                        Text(verbatim: path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(String(localized: "Show in Finder")) { reveal(row) }
                            .controlSize(.small)
                            .disabled(!canReveal(row))
                    }
                }
            }
            if let commandLine = row.commandLine {
                Text(String(localized: "Command"))
                    .font(.subheadline.weight(.semibold))
                CopyableCodeBlock(text: commandLine)
            }
            if let snippet = row.snippet, row.isConfigWritable || row.commandLine == nil {
                Text(String(localized: "Configuration"))
                    .font(.subheadline.weight(.semibold))
                CopyableCodeBlock(text: snippet)
            }
            if row.removeRoute != nil {
                Button(String(localized: "Remove…"), role: .destructive) { removeCandidate = row }
                    .accessibilityIdentifier("mcp-client-remove")
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("mcp-client-setup-done")
        }
        .padding(16)
    }

    // A SwiftUI sheet on macOS opens at its minimum size, so the size is fixed here and kept inside a short screen.
    private var sheetHeight: CGFloat {
        let available = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 760
        return min(760, max(480, available - 80))
    }

    private var foundRows: [MCPClientRow] {
        service.rows.filter { $0.isInstalled }
    }

    private var otherRows: [MCPClientRow] {
        service.rows.filter { !$0.isInstalled }
    }

    private var selectedRow: MCPClientRow? {
        selection.flatMap { service.row(id: $0) }
    }

    private var isServerDown: Bool {
        switch manager.state {
        case .stopped, .failed: true
        case .starting, .running: false
        }
    }

    private func perform(_ action: MCPClientRowAction, on row: MCPClientRow) {
        selection = row.id
        switch action {
        case .install:
            Task { await service.install(row.id) }
        case .update:
            Task { await service.update(row.id) }
        case .copy:
            if let text = row.copyText {
                copy(text)
            }
        }
    }

    private func copy(_ text: String) {
        ClipboardService.shared.writeText(text)
        AccessibilityAnnouncement.post(String(localized: "Copied to clipboard"))
    }

    private func canReveal(_ row: MCPClientRow) -> Bool {
        guard let path = row.configPath else { return false }
        return row.configFileExists
            || FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func reveal(_ row: MCPClientRow) {
        guard let path = row.configPath else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        }
    }

    private var removeTitle: String {
        guard let row = removeCandidate else { return "" }
        return String(format: String(localized: "Remove TablePro from %@?"), row.name)
    }

    private func removeMessage(for row: MCPClientRow) -> String {
        if row.removeRoute == .file, let file = row.configFileName {
            return String(
                format: String(localized: "%1$@ stops reaching your databases through TablePro. The current %2$@ is kept next to it as %3$@."),
                row.name,
                file,
                file + ".tablepro-backup"
            )
        }
        return String(format: String(localized: "%@ stops reaching your databases through TablePro."), row.name)
    }

    private var removeBinding: Binding<Bool> {
        Binding(
            get: { removeCandidate != nil },
            set: { isPresented in
                if !isPresented {
                    removeCandidate = nil
                }
            }
        )
    }
}

private struct MCPClientSetupRowView: View {
    let row: MCPClientRow
    let presentation: MCPClientRowPresentation
    let actionsDisabled: Bool
    let onAction: (MCPClientRowAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            BrandIconView(slug: row.iconSlug, fallbackSystemImage: "app")
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: presentation.title)
                Text(verbatim: presentation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let status = presentation.status {
                Text(verbatim: status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if presentation.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if let action = presentation.action {
                Button(action.title) { onAction(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(actionsDisabled && action != .copy)
                    .accessibilityLabel(action.accessibilityLabel(clientName: row.name))
                    .accessibilityIdentifier("mcp-client-action-\(row.id)")
            }
        }
        .padding(.vertical, 3)
    }
}
