//
//  SSHAndProxiesJumpHostRows.swift
//  TablePro
//

import SwiftUI
import TableProSSHConfig

// One Section per hop, so two hops never read as one card.
struct SSHAndProxiesJumpHostSections: View {
    let rows: [EditorRow]
    @ObservedObject var store: ConnectionEditorStore

    private var hopIDs: [UUID] {
        rows.compactMap { row in
            guard case .builtIn(.jumpHost(let id)) = row else { return nil }
            return id
        }
    }

    var body: some View {
        let ids = hopIDs
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
            SSHAndProxiesJumpHostSection(id: id, index: index, count: ids.count, store: store)
        }
        if rows.contains(.builtIn(.addJumpHost)) {
            Section {
                SSHAndProxiesAddJumpHostRow(store: store)
            } footer: {
                Text(String(localized: """
                    TablePro connects through the jump hosts in order, then the SSH server. \
                    A jump host signs in with a key file or the SSH agent.
                    """))
            }
        }
    }
}

private struct SSHAndProxiesJumpHostSection: View {
    let id: UUID
    let index: Int
    let count: Int
    @ObservedObject var store: ConnectionEditorStore

    @FocusState private var focusedField: JumpHostField?

    private var row: EditorRow { .builtIn(.jumpHost(id)) }
    private var identifier: String { row.accessibilityIdentifier }
    private var jumpHost: Binding<SSHJumpHost> { store.tracking(store.jumpHostBinding(id), row: row) }

    var body: some View {
        Section {
            TextField(text: jumpHost.host, prompt: Text(verbatim: "bastion.example.com")) {
                label(String(localized: "Host"), for: .host)
            }
            .autocorrectionDisabled()
            .focused($focusedField, equals: .host)
            .accessibilityIdentifier(identifier)
            .onEditorFocusRequest(row, store: store, perform: focusMissingField)

            TextField(text: portText, prompt: Text(verbatim: "22")) {
                Text(String(localized: "Port"))
            }
            .accessibilityIdentifier("\(identifier)-port")

            TextField(text: jumpHost.username, prompt: Text(verbatim: "admin")) {
                Text(String(localized: "Username"))
            }
            .autocorrectionDisabled()
            .accessibilityIdentifier("\(identifier)-username")

            Picker(selection: jumpHost.authMethod) {
                ForEach(SSHJumpAuthMethod.allCases) { method in
                    Text(Self.title(of: method)).tag(method)
                }
            } label: {
                Text(String(localized: "Method"))
            }
            .accessibilityIdentifier("\(identifier)-auth")

            if jumpHost.wrappedValue.authMethod == .privateKey {
                keyFileRow
            }
        } header: {
            Text(String(format: String(localized: "Jump Host %lld"), Int64(index + 1)))
        } footer: {
            HStack(spacing: 8) {
                Spacer()
                if count > 1 {
                    Button(String(localized: "Move Up")) {
                        store.moveJumpHosts(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                    }
                    .disabled(index == 0)
                    .accessibilityIdentifier("\(identifier)-move-up")

                    Button(String(localized: "Move Down")) {
                        store.moveJumpHosts(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                    }
                    .disabled(index == count - 1)
                    .accessibilityIdentifier("\(identifier)-move-down")
                }
                Button(String(localized: "Remove")) {
                    store.removeJumpHost(id: id)
                }
                .accessibilityIdentifier("\(identifier)-remove")
            }
        }
    }

    private var keyFileRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "Key File"),
                    text: jumpHost.privateKeyPath,
                    prompt: Text(verbatim: "~/.ssh/id_ed25519")
                )
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($focusedField, equals: .keyFile)
                .accessibilityIdentifier("\(identifier)-key-file")
                Button(String(localized: "Choose…")) {
                    Task {
                        let message = String(localized: "Choose a private key file")
                        if let path = await TransportFilePanel.chooseSSHKey(message: message, store: store) {
                            jumpHost.wrappedValue.privateKeyPath = path
                        }
                    }
                }
                .accessibilityIdentifier("\(identifier)-key-file-choose")
            }
        } label: {
            label(String(localized: "Key File"), for: .keyFile)
        }
    }

    // The hop's one issue sits under the field it is about.
    @ViewBuilder
    private func label(_ title: String, for field: JumpHostField) -> some View {
        Text(verbatim: title)
        if let issue = store.revealedIssue(for: row), (store.missingJumpHostField(id) ?? .host) == field {
            NoticeLabel(issue.message, severity: issue.noticeSeverity)
        }
    }

    // Digits only, so a stray letter never wipes the port the field shows.
    private var portText: Binding<String> {
        Binding(
            get: { jumpHost.wrappedValue.port.map(String.init) ?? "" },
            set: { text in
                let digits = String(text.filter { ("0"..."9").contains($0) }.prefix(5))
                jumpHost.wrappedValue.port = Int(digits)
            }
        )
    }

    private func focusMissingField() {
        focusedField = store.missingJumpHostField(id) ?? .host
    }

    private static func title(of method: SSHJumpAuthMethod) -> String {
        switch method {
        case .privateKey: return SSHAuthMethod.privateKey.displayName
        case .sshAgent: return SSHAuthMethod.sshAgent.displayName
        }
    }
}

struct SSHAndProxiesAddJumpHostRow: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        LabeledContent {
            Button(String(localized: "Add Jump Host")) {
                let id = store.addJumpHost()
                store.focus(facet: .sshAndProxies, row: .builtIn(.jumpHost(id)))
            }
            .accessibilityIdentifier(EditorRow.builtIn(.addJumpHost).accessibilityIdentifier)
        } label: {
            Text(String(localized: "Jump Hosts"))
        }
    }
}
