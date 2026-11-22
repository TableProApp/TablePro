//
//  TransportProxyRows.swift
//  TablePro
//

import AppKit
import SwiftUI

struct TransportCloudflareRow: View {
    let row: BuiltInRow
    @ObservedObject var store: ConnectionEditorStore

    private var editorRow: EditorRow { .builtIn(row) }

    var body: some View {
        switch row {
        case .cloudflareHostname:
            EditorTextRow(
                String(localized: "Hostname"),
                text: store.binding(\.cloudflare.accessHostname),
                prompt: "db.example.com",
                row: editorRow,
                store: store
            )
        case .cloudflareAuthMethod:
            SSHAndProxiesPicker(String(localized: "Method"), selection: store.binding(\.cloudflare.authMethod), row: editorRow, store: store) {
                ForEach(CloudflareAuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
        case .cloudflareSignIn:
            signInRow
        case .cloudflareTokenId:
            EditorSecureRow(
                String(localized: "Client ID"),
                text: store.binding(\.cloudflare.serviceTokenId),
                prompt: String(localized: "Required"),
                row: editorRow,
                store: store
            )
        case .cloudflareTokenSecret:
            EditorSecureRow(
                String(localized: "Client Secret"),
                text: store.binding(\.cloudflare.serviceTokenSecret),
                prompt: String(localized: "Required"),
                row: editorRow,
                store: store
            )
        case .cloudflareAutomaticPort:
            TransportToggle(String(localized: "Choose Port Automatically"), isOn: store.binding(\.cloudflare.automaticPort), row: editorRow, store: store)
        case .cloudflareLocalPort:
            EditorTextRow(String(localized: "Local Port"), text: store.binding(\.cloudflare.localPort), prompt: "5432", row: editorRow, store: store)
        case .cloudflareExposeToLAN:
            TransportToggle(String(localized: "Expose to Local Network"), isOn: store.binding(\.cloudflare.exposeToLAN), row: editorRow, store: store)
        case .cloudflareBinary:
            TransportBinaryRow(
                path: store.binding(\.cloudflare.binaryPath),
                detection: store.cloudflaredDetection,
                notFoundMessage: String(localized: "cloudflared not found. Install it with “brew install cloudflared”, or choose the binary."),
                row: editorRow,
                store: store
            )
        default:
            EmptyView()
        }
    }

    private var signInRow: some View {
        let hostname = store.draft.cloudflare.accessHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return LabeledContent {
            Button(store.isCloudflareSignInRunning ? String(localized: "Signing In…") : String(localized: "Sign In with Browser…")) {
                store.signInWithCloudflare()
            }
            .disabled(hostname.isEmpty || store.isCloudflareSignInRunning)
            .accessibilityIdentifier(editorRow.accessibilityIdentifier)
        } label: {
            Text(String(localized: "Access Token"))
            if let error = store.cloudflareSignInError {
                NoticeLabel(error, severity: .error)
                    .textSelection(.enabled)
            }
        }
        .editorRowFocus(editorRow, store: store)
    }
}

struct TransportCloudSQLRow: View {
    let row: BuiltInRow
    @ObservedObject var store: ConnectionEditorStore

    private var editorRow: EditorRow { .builtIn(row) }

    var body: some View {
        switch row {
        case .cloudSQLInstance:
            EditorTextRow(
                String(localized: "Instance Connection Name"),
                text: store.binding(\.cloudSQLProxy.instanceConnectionName),
                prompt: "project:region:instance",
                row: editorRow,
                store: store
            )
        case .cloudSQLAuthMode:
            SSHAndProxiesPicker(String(localized: "Method"), selection: store.binding(\.cloudSQLProxy.authMode), row: editorRow, store: store) {
                ForEach(CloudSQLProxyAuthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        case .cloudSQLServiceAccountKey:
            EditorCodeEditor(
                text: store.binding(\.cloudSQLProxy.serviceAccountKeyJSON),
                language: .json,
                row: editorRow,
                store: store
            )
        case .cloudSQLIAMAuth:
            TransportToggle(
                String(localized: "Use IAM Database Authentication"),
                isOn: store.binding(\.cloudSQLProxy.useIAMAuth),
                row: editorRow,
                store: store
            )
        case .cloudSQLPrivateIP:
            TransportToggle(String(localized: "Connect over Private IP"), isOn: store.binding(\.cloudSQLProxy.usePrivateIP), row: editorRow, store: store)
        case .cloudSQLAutomaticPort:
            TransportToggle(
                String(localized: "Choose Port Automatically"),
                isOn: store.binding(\.cloudSQLProxy.automaticPort),
                row: editorRow,
                store: store
            )
        case .cloudSQLLocalPort:
            EditorTextRow(String(localized: "Local Port"), text: store.binding(\.cloudSQLProxy.localPort), prompt: "5432", row: editorRow, store: store)
        case .cloudSQLBinary:
            TransportBinaryRow(
                path: store.binding(\.cloudSQLProxy.binaryPath),
                detection: store.cloudSQLProxyDetection,
                notFoundMessage: String(
                    localized: "cloud-sql-proxy not found. Install it with “brew install cloud-sql-proxy”, download it, or choose the binary."
                ),
                row: editorRow,
                store: store,
                downloadPhase: store.cloudSQLProxyDownloadPhase
            )
        default:
            EmptyView()
        }
    }
}

struct TransportSOCKSRow: View {
    let row: BuiltInRow
    @ObservedObject var store: ConnectionEditorStore

    private var editorRow: EditorRow { .builtIn(row) }

    var body: some View {
        switch row {
        case .socksHost:
            EditorTextRow(String(localized: "Host"), text: store.binding(\.socksProxy.host), prompt: "proxy.example.com", row: editorRow, store: store)
        case .socksPort:
            EditorTextRow(String(localized: "Port"), text: store.binding(\.socksProxy.port), prompt: "1080", row: editorRow, store: store)
        case .socksUsername:
            EditorTextRow(String(localized: "Username"), text: store.binding(\.socksProxy.username), row: editorRow, store: store)
        case .socksPassword:
            EditorSecureRow(String(localized: "Password"), text: store.binding(\.socksProxy.password), row: editorRow, store: store)
        default:
            EmptyView()
        }
    }
}

struct TransportToggle: View {
    private let title: String
    @Binding private var isOn: Bool
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore

    init(_ title: String, isOn: Binding<Bool>, row: EditorRow, store: ConnectionEditorStore) {
        self.title = title
        _isOn = isOn
        self.row = row
        self.store = store
    }

    var body: some View {
        Toggle(isOn: store.tracking($isOn, row: row)) {
            EditorRowLabel(title, row: row, store: store)
        }
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .editorRowFocus(row, store: store)
    }
}

// A helper binary: empty finds it on its own, and the label says what was found.
struct TransportBinaryRow: View {
    @Binding var path: String
    let detection: ConnectionEditorStore.BinaryDetection
    let notFoundMessage: String
    let row: EditorRow
    @ObservedObject var store: ConnectionEditorStore
    var downloadPhase: CloudSQLProxyDownload.Phase?

    private var usesDetection: Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDownloading: Bool { downloadPhase?.isDownloading == true }

    private var downloadFailure: String? {
        if case .failed(let message) = downloadPhase { return message }
        return nil
    }

    private var offersDownload: Bool {
        guard downloadPhase != nil, !isDownloading, usesDetection else { return false }
        return detection == .notFound || downloadFailure != nil
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(String(localized: "Path"), text: store.tracking($path, row: row), prompt: Text(String(localized: "Automatic")))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier(row.accessibilityIdentifier)
                Button(String(localized: "Choose…")) {
                    Task {
                        if let chosen = await TransportFilePanel.chooseExecutable(currentPath: path, store: store) {
                            store.noteEdited(row)
                            path = chosen
                        }
                    }
                }
                .accessibilityIdentifier("\(row.accessibilityIdentifier)-choose")
                if offersDownload {
                    Button(String(localized: "Download")) {
                        store.downloadCloudSQLProxy()
                    }
                    .accessibilityIdentifier("\(row.accessibilityIdentifier)-download")
                }
            }
        } label: {
            Text(String(localized: "Path"))
            status
        }
        .editorRowFocus(row, store: store)

        if case .downloading(let fraction) = downloadPhase {
            LabeledContent {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .labelsHidden()
                    Button(String(localized: "Cancel")) {
                        store.cancelCloudSQLProxyDownload()
                    }
                    .accessibilityIdentifier("\(row.accessibilityIdentifier)-download-cancel")
                }
            } label: {
                Text(String(localized: "Downloading cloud-sql-proxy"))
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let downloadFailure {
            NoticeLabel(downloadFailure, severity: .error)
                .textSelection(.enabled)
        } else if usesDetection, !isDownloading {
            switch detection {
            case .found(let found):
                Text(String(format: String(localized: "Detected: %@"), found))
                    .textSelection(.enabled)
            case .notFound:
                NoticeLabel(notFoundMessage, severity: .warning)
                    .textSelection(.enabled)
            case .notChecked, .checking:
                EmptyView()
            }
        }
    }
}

@MainActor
enum TransportFilePanel {
    static func chooseSSHKey(message: String, store: ConnectionEditorStore) async -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        return await present(panel, store: store)
    }

    static func chooseExecutable(currentPath: String, store: ConnectionEditorStore) async -> String? {
        let panel = NSOpenPanel()
        let typed = (currentPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if typed.hasPrefix("/") {
            panel.directoryURL = URL(fileURLWithPath: typed).deletingLastPathComponent()
        } else {
            let homebrew = "/opt/homebrew/bin"
            let folder = FileManager.default.fileExists(atPath: homebrew) ? homebrew : "/usr/local/bin"
            panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        }
        return await present(panel, store: store)
    }

    private static func present(_ panel: NSOpenPanel, store: ConnectionEditorStore) async -> String? {
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let response: NSApplication.ModalResponse
        if let window = EditorFilePanel.window(for: store) {
            response = await panel.presentAsSheet(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}
