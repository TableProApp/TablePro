//
//  SSHAndProxiesJumpHostRows.swift
//  TablePro
//

import SwiftUI
import TableProSSHConfig

// One jump host as rows of the Jump Hosts section, so every field stays visible and an issue can focus it.
struct SSHAndProxiesJumpHostRows: View {
    let id: UUID
    @ObservedObject var store: ConnectionEditorStore

    private enum Field: Hashable {
        case host
        case keyFile
    }

    @FocusState private var focusedField: Field?
    @State private var handledToken: UUID?
    @State private var isEdited = false

    private var row: EditorRow { .builtIn(.jumpHost(id)) }
    private var identifier: String { row.accessibilityIdentifier }
    private var jumpHost: Binding<SSHJumpHost> { store.jumpHostBinding(id) }
    private var jumpHosts: [SSHJumpHost] { store.draft.ssh.jumpHosts }
    private var index: Int { jumpHosts.firstIndex { $0.id == id } ?? 0 }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "Host"),
                    text: jumpHost.host,
                    prompt: Text(verbatim: "bastion.example.com")
                )
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($focusedField, equals: .host)
                .accessibilityIdentifier(identifier)
                orderButtons
                Button {
                    store.removeJumpHost(id: id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Remove Jump Host"))
                .accessibilityLabel(String(localized: "Remove Jump Host"))
                .accessibilityIdentifier("\(identifier)-remove")
            }
        } label: {
            EditorRowLabel(
                String(format: String(localized: "Jump Host %lld"), Int64(index + 1)),
                row: row,
                store: store,
                isEdited: isEdited
            )
        }
        .onAppear { applyFocus(store.focusRequest) }
        .onChange(of: store.focusRequest) { applyFocus($0) }
        .onChange(of: jumpHost.wrappedValue) { _ in isEdited = true }

        TextField(String(localized: "Port"), text: portText, prompt: Text(verbatim: "22"))
            .accessibilityIdentifier("\(identifier)-port")

        TextField(String(localized: "User"), text: jumpHost.username, prompt: Text(verbatim: "admin"))
            .autocorrectionDisabled()
            .accessibilityIdentifier("\(identifier)-username")

        Picker(String(localized: "Authentication"), selection: jumpHost.authMethod) {
            ForEach(SSHJumpAuthMethod.allCases) { method in
                Text(Self.title(of: method)).tag(method)
            }
        }
        .accessibilityIdentifier("\(identifier)-auth")

        if jumpHost.wrappedValue.authMethod == .privateKey {
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
                Text(String(localized: "Key File"))
            }
        }
    }

    @ViewBuilder
    private var orderButtons: some View {
        if jumpHosts.count > 1 {
            Button {
                store.moveJumpHosts(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(String(localized: "Move Up"))
            .accessibilityLabel(String(localized: "Move Up"))
            .accessibilityIdentifier("\(identifier)-move-up")

            Button {
                store.moveJumpHosts(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == jumpHosts.count - 1)
            .help(String(localized: "Move Down"))
            .accessibilityLabel(String(localized: "Move Down"))
            .accessibilityIdentifier("\(identifier)-move-down")
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

    // The issue covers the whole hop, so focus lands on the field that is missing.
    private func applyFocus(_ request: FocusRequest?) {
        guard let request, request.row == row, request.token != handledToken else { return }
        handledToken = request.token
        let hop = jumpHost.wrappedValue
        let field: Field = !hop.host.isEmpty && hop.authMethod == .privateKey && hop.privateKeyPath.isEmpty ? .keyFile : .host
        DispatchQueue.main.async {
            focusedField = field
        }
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
        Button(String(localized: "Add Jump Host")) {
            let id = store.addJumpHost()
            store.focus(facet: .sshAndProxies, row: .builtIn(.jumpHost(id)))
        }
        .accessibilityIdentifier(EditorRow.builtIn(.addJumpHost).accessibilityIdentifier)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
