//
//  SSHAndProxiesJumpHostRows.swift
//  TablePro
//

import SwiftUI
import TableProSSHConfig

// What jump hosts are leads, then one card per hop, so two hops never read as one card.
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
        if rows.contains(.builtIn(.addJumpHost)) {
            Section {
                SSHAndProxiesAddJumpHostRow(hopCount: ids.count, store: store)
            } header: {
                Text(String(localized: "Jump Hosts"))
            } footer: {
                Text(String(localized: """
                    TablePro connects through the jump hosts in order, then the SSH server. \
                    A jump host signs in with a key file or the SSH agent.
                    """))
            }
        }
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
            SSHAndProxiesJumpHostSection(id: id, index: index, count: ids.count, store: store)
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

    private var title: String {
        String(format: String(localized: "Jump Host %lld"), Int64(index + 1))
    }

    var body: some View {
        Section {
            LabeledContent {
                actions
            } label: {
                Text(verbatim: title)
            }
            .id(row)

            TextField(text: jumpHost.host, prompt: Text(verbatim: "bastion.example.com")) {
                label(String(localized: "Host"), for: .host)
            }
            .autocorrectionDisabled()
            .focused($focusedField, equals: .host)
            .accessibilityIdentifier(identifier)
            .onEditorFocusRequest(row, store: store, perform: focusMissingField)

            TextField(text: portText, prompt: Text(verbatim: "22")) {
                label(String(localized: "Port"), for: .port)
            }
            .focused($focusedField, equals: .port)
            .accessibilityIdentifier("\(identifier)-port")

            TextField(text: jumpHost.username, prompt: Text(verbatim: "admin")) {
                Text(String(localized: "Username"))
            }
            .autocorrectionDisabled()
            .accessibilityIdentifier("\(identifier)-username")

            Picker(selection: jumpHost.authMethod) {
                ForEach(SSHJumpAuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            } label: {
                Text(String(localized: "Method"))
            }
            .accessibilityIdentifier("\(identifier)-auth")

            if jumpHost.wrappedValue.authMethod == .privateKey {
                keyFileRow
            }
        }
    }

    private var actions: some View {
        Menu {
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

            Divider()

            Button(String(localized: "Remove"), role: .destructive) {
                store.removeJumpHost(id: id)
            }
            .accessibilityIdentifier("\(identifier)-remove")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Actions"))
        .accessibilityLabel(String(format: String(localized: "Actions for %@"), title))
        .accessibilityIdentifier("\(identifier)-actions")
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
                .editorPathField(jumpHost.wrappedValue.privateKeyPath)
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
}

struct SSHAndProxiesAddJumpHostRow: View {
    let hopCount: Int
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        LabeledContent {
            Button(String(localized: "Add Jump Host")) {
                let id = store.addJumpHost()
                store.focus(facet: .sshAndProxies, row: .builtIn(.jumpHost(id)))
            }
            .accessibilityIdentifier(EditorRow.builtIn(.addJumpHost).accessibilityIdentifier)
        } label: {
            if hopCount == 0 {
                Text(String(localized: "No Jump Hosts"))
                    .foregroundStyle(.secondary)
            } else {
                Text("^[\(hopCount) Jump Host](inflect: true)")
            }
        }
        .id(EditorRow.builtIn(.addJumpHost))
    }
}
