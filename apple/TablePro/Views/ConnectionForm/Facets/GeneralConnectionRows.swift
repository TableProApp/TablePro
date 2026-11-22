//
//  GeneralConnectionRows.swift
//  TablePro
//

import AppKit
import SwiftUI

struct GeneralTypeRow: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                ConnectionTile(
                    type: store.draft.type,
                    iconName: store.draft.appearance.iconName,
                    identityColor: store.draft.appearance.color.isDefault ? nil : store.draft.appearance.color,
                    size: 22
                )
                Text(verbatim: store.traits.displayName)
                Button(String(localized: "Change…")) {
                    store.isChoosingType = true
                }
                .accessibilityIdentifier(BuiltInRow.type.accessibilityIdentifier)
            }
        } label: {
            EditorRowLabel(String(localized: "Type"), row: .builtIn(.type), store: store)
        }
        .editorRowFocus(.builtIn(.type), store: store)
    }
}

struct GeneralEnvironmentRow: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        Picker(selection: store.tracking(store.environmentBinding, row: .builtIn(.environment))) {
            ForEach(ConnectionEnvironment.allCases) { environment in
                if let image = Self.symbol(for: environment) {
                    Label {
                        Text(verbatim: environment.displayName)
                    } icon: {
                        Image(nsImage: image)
                    }
                    .tag(environment)
                } else {
                    Text(verbatim: environment.displayName).tag(environment)
                }
            }
        } label: {
            EditorRowLabel(String(localized: "Environment"), row: .builtIn(.environment), store: store)
        }
        .accessibilityIdentifier(BuiltInRow.environment.accessibilityIdentifier)
        .editorRowFocus(.builtIn(.environment), store: store)
    }

    // A menu item draws a template image in its own text color, so the tint is baked into a non-template copy.
    private static func symbol(for environment: ConnectionEnvironment) -> NSImage? {
        guard let name = environment.symbolName else { return nil }
        let tint: NSColor = environment == .local ? .secondaryLabelColor : NSColor(environment.tint)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        image?.isTemplate = false
        return image
    }
}

struct GeneralSocketPathRow: View {
    @ObservedObject var store: ConnectionEditorStore

    private var prompt: String { store.traits.defaultLocalSocketPath ?? "" }

    var body: some View {
        if store.traits.localSocketIsDirectory {
            LabeledContent {
                SuggestionComboBox(
                    suggestions: { PostgreSQLLocalSocket.commonDirectories },
                    placeholder: prompt,
                    accessibilityLabel: String(localized: "Socket"),
                    accessibilityIdentifier: BuiltInRow.localSocketPath.accessibilityIdentifier,
                    value: Binding(
                        get: { store.draft.localSocketPath },
                        set: { newValue in
                            store.noteEdited(.builtIn(.localSocketPath))
                            store.update { $0.localSocketPath = newValue }
                        }
                    )
                )
            } label: {
                EditorRowLabel(String(localized: "Socket"), row: .builtIn(.localSocketPath), store: store)
            }
            .editorRowFocus(.builtIn(.localSocketPath), store: store)
        } else {
            EditorTextRow(
                String(localized: "Socket"),
                text: store.binding(\.localSocketPath),
                prompt: prompt,
                row: .builtIn(.localSocketPath),
                store: store
            )
        }
    }
}

// Advisory only: the server may start after the connection is saved.
enum GeneralSocketStatus {
    static func message(status: SocketFileStatus?, socketFile: String?, isDirectory: Bool) -> String {
        isDirectory ? directoryMessage(status: status, socketFile: socketFile) : fileMessage(status: status)
    }

    private static func fileMessage(status: SocketFileStatus?) -> String {
        switch status {
        case .missing:
            return String(localized: "Nothing is at this path. Start the server, or check the path.")
        case .notSocket:
            return String(localized: "This file is not a socket.")
        case .socket, .none:
            return String(localized: "The server's socket file on this Mac. SELECT @@socket in the mysql client shows it.")
        }
    }

    private static func directoryMessage(status: SocketFileStatus?, socketFile: String?) -> String {
        guard let socketFile else {
            return String(localized: """
                The folder with the server's socket, or the socket file. SHOW unix_socket_directories \
                in psql lists the folders.
                """)
        }
        let file = (socketFile as NSString).abbreviatingWithTildeInPath
        switch status {
        case .missing:
            return String(
                format: String(localized: "Nothing is at %@. Start the server, or check the folder and the port."),
                file
            )
        case .notSocket:
            return String(format: String(localized: "%@ is not a socket."), file)
        case .socket, .none:
            return String(
                format: String(localized: "Connects to %@. The port names the socket file in the folder."),
                file
            )
        }
    }
}

struct GeneralPastedURLNoticeRow: View {
    let notice: PastedURLNotice
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        LabeledContent {
            Button(String(localized: "Undo")) {
                store.undoPastedURL()
            }
            .accessibilityIdentifier("connection-form-pasted-url-undo")
        } label: {
            NoticeLabel(notice.message, severity: .info)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connection-form-pasted-url-notice")
        }
    }
}

struct GeneralPortTLSNoticeRow: View {
    let notice: PortTLSNotice
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        if let actionTitle = notice.actionTitle {
            LabeledContent {
                Button(actionTitle) {
                    store.selectSSLMode(notice.impliedMode)
                }
                .accessibilityIdentifier("connection-form-port-tls-use")
            } label: {
                noticeLabel(severity: .warning)
            }
        } else {
            noticeLabel(severity: .info)
        }
    }

    private func noticeLabel(severity: NoticeSeverity) -> some View {
        NoticeLabel(notice.message, severity: severity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(BuiltInRow.portTLSNotice.accessibilityIdentifier)
    }
}
