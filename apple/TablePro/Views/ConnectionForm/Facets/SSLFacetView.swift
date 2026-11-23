//
//  SSLFacetView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct SSLFacetView: View {
    @ObservedObject var store: ConnectionEditorStore

    init(store: ConnectionEditorStore) {
        self.store = store
    }

    var body: some View {
        Form {
            if let facet = store.layout.facet(.sslTLS) {
                ForEach(facet.sections) { section in
                    Section {
                        ForEach(section.rows, id: \.self) { row in
                            rowView(row)
                                .id(row)
                        }
                    } header: {
                        if let title = section.title {
                            Text(verbatim: title)
                        }
                    } footer: {
                        if let footer = footer(for: section) {
                            Text(verbatim: footer)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollsToEditorFocus(.sslTLS, store: store)
    }

    // The mode section explains the mode that is selected, not the type's note about Preferred under every mode.
    private func footer(for section: SectionLayout) -> String? {
        guard section.id == "sslMode" else { return section.footer }
        return SSLModeFooter.text(
            mode: store.draft.ssl.mode,
            traits: store.traits.ssl,
            usesLocalSocket: store.usesLocalSocket
        )
    }

    @ViewBuilder
    private func rowView(_ row: EditorRow) -> some View {
        switch row {
        case .builtIn(.sslMode):
            SSLModeRow(store: store)
        case .builtIn(.sslNoFallbackNotice):
            SSLNoFallbackNotice(store: store)
        case .builtIn(.sslCertificateTrustNote):
            NoticeLabel(
                String(localized: """
                    Verify CA and Verify Identity check the server certificate against the system trust \
                    store. This driver takes no custom CA or client certificate.
                    """),
                severity: .info
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(BuiltInRow.sslCertificateTrustNote.accessibilityIdentifier)
        case .builtIn(.sslCACertificate):
            certificateRow(
                String(localized: "Certificate"),
                keyPath: \.ssl.caCertPath,
                prompt: caCertificateIsOptional ? String(localized: "Optional") : "/path/to/ca-cert.pem",
                row: .sslCACertificate
            )
        case .builtIn(.sslClientCertificate):
            certificateRow(
                String(localized: "Certificate"),
                keyPath: \.ssl.clientCertPath,
                prompt: String(localized: "Optional"),
                row: .sslClientCertificate
            )
        case .builtIn(.sslClientKey):
            certificateRow(
                String(localized: "Key"),
                keyPath: \.ssl.clientKeyPath,
                prompt: String(localized: "Optional"),
                row: .sslClientKey
            )
        case .builtIn(.sslClientKeyPassphrase):
            EditorSecureRow(
                String(localized: "Key Passphrase"),
                text: store.binding(\.ssl.clientKeyPassphrase),
                prompt: String(localized: "Required only for an encrypted key"),
                row: .builtIn(.sslClientKeyPassphrase),
                store: store
            )
        case .plugin(let fieldID):
            PluginFieldRow(fieldID: fieldID, store: store)
        default:
            EmptyView()
        }
    }

    private var caCertificateIsOptional: Bool {
        !store.traits.ssl.requiresCACertificate(for: store.draft.ssl.mode)
    }

    private func certificateRow(
        _ title: String,
        keyPath: WritableKeyPath<ConnectionDraft, String>,
        prompt: String,
        row: BuiltInRow
    ) -> some View {
        let path = store.binding(keyPath)
        return EditorPathRow(title, path: path, prompt: prompt, row: .builtIn(row), store: store) {
            await EditorFilePanel.chooseFile(
                in: EditorFilePanel.window(for: store),
                message: String(localized: "Choose a certificate or key file"),
                showsHiddenFiles: true,
                currentPath: path.wrappedValue
            )
        }
    }
}

// A mode the driver refuses here stays in the menu, dimmed, so the pop-up never reads blank; its issue says why.
struct SSLModeRow: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        let offered = store.offeredSSLModes
        let current = store.draft.ssl.mode
        Picker(selection: store.tracking(store.sslModeBinding, row: .builtIn(.sslMode))) {
            ForEach(offered) { mode in
                Text(verbatim: mode.displayLabel).tag(mode)
            }
            if !offered.contains(current) {
                Divider()
                Text(verbatim: current.displayLabel)
                    .tag(current)
                    .disabled(true)
            }
        } label: {
            EditorRowLabel(String(localized: "SSL Mode"), row: .builtIn(.sslMode), store: store)
        }
        .accessibilityIdentifier(BuiltInRow.sslMode.accessibilityIdentifier)
        .editorRowFocus(.builtIn(.sslMode), store: store)
    }
}

struct SSLNoFallbackNotice: View {
    @ObservedObject var store: ConnectionEditorStore

    // Oracle's driver drops to plain TCP on Preferred where the others force TLS.
    private var connectsInPlain: Bool { store.draft.type == .oracle }

    var body: some View {
        NoticeLabel(
            connectsInPlain
                ? String(localized: "Preferred connects in plain TCP for this driver. Use Required to enforce TCPS.")
                : String(localized: "This driver has no TLS fallback. Preferred forces TLS, same as Required."),
            severity: connectsInPlain ? .error : .warning
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(BuiltInRow.sslNoFallbackNotice.accessibilityIdentifier)
    }
}

enum SSLModeFooter {
    static func text(mode: SSLMode, traits: ConnectionTypeTraits.SSLTraits, usesLocalSocket: Bool) -> String? {
        switch mode {
        case .disabled:
            return String(localized: "The connection is not encrypted.")
        case .preferred:
            // Without a fallback the notice above already says what Preferred does, and the type's note repeats it.
            guard traits.supportsOpportunisticTLS else { return nil }
            var lines = [traits.note.isEmpty
                ? String(localized: "Encrypts the connection when the server offers TLS, and connects without it otherwise.")
                : traits.note]
            if usesLocalSocket {
                lines.append(String(localized: "Preferred leaves a socket connection unencrypted. Required encrypts it."))
            }
            return lines.joined(separator: "\n")
        case .required:
            return String(localized: "Encrypts the connection without checking the server certificate.")
        case .verifyCa:
            return String(localized: "Encrypts the connection and checks that a trusted certificate authority signed the server certificate.")
        case .verifyIdentity:
            return String(localized: "Encrypts the connection and checks the server certificate and that it names the host.")
        }
    }
}
