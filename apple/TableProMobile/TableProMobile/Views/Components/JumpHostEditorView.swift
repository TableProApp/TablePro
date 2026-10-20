import SwiftUI
import UniformTypeIdentifiers

struct JumpHostEditorView: View {
    let viewModel: ConnectionFormViewModel
    let hopId: UUID

    @State private var keyInputMode: ConnectionFormViewModel.KeyInputMode
    @State private var showKeyImporter = false

    init(viewModel: ConnectionFormViewModel, hopId: UUID) {
        self.viewModel = viewModel
        self.hopId = hopId
        let hasKey = viewModel.jumpHost(hopId)?.keyContent.isEmpty == false
        _keyInputMode = State(initialValue: hasKey ? .paste : .file)
    }

    private var hop: JumpHostDraft? {
        viewModel.jumpHost(hopId)
    }

    private var draft: Binding<JumpHostDraft> {
        Binding(
            get: { viewModel.jumpHost(hopId) ?? JumpHostDraft(id: hopId) },
            set: { value in viewModel.updateJumpHost(hopId) { $0 = value } }
        )
    }

    private var showKeyFileError: Binding<Bool> {
        Binding(
            get: { viewModel.jumpHostKeyFileError != nil },
            set: { if !$0 { viewModel.dismissJumpHostKeyFileError() } }
        )
    }

    private var title: String {
        guard let hop, hop.hasHost else { return String(localized: "New Jump Host") }
        return hop.host
    }

    var body: some View {
        Form {
            Section {
                TextField("Host", text: draft.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Port", text: draft.port, prompt: Text(verbatim: "22"))
                    .keyboardType(.numberPad)
                TextField("Username", text: draft.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
            }

            keySection
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if viewModel.importJumpHostKey(result, for: hopId) {
                keyInputMode = .paste
            }
        }
        .alert("Private Key", isPresented: showKeyFileError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.jumpHostKeyFileError ?? "")
        }
    }

    @ViewBuilder
    private var keySection: some View {
        let usesServerKey = hop?.usesServerKey ?? false
        Section {
            Toggle("Same Key as SSH Server", isOn: draft.usesServerKey)
                .disabled(!viewModel.serverSignsInWithKey && !usesServerKey)

            if !usesServerKey {
                Picker("Input Method", selection: $keyInputMode) {
                    ForEach(ConnectionFormViewModel.KeyInputMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if keyInputMode == .file {
                    Button {
                        showKeyImporter = true
                    } label: {
                        HStack {
                            Text("Select Private Key")
                            Spacer()
                            Image(systemName: "folder")
                        }
                    }
                } else {
                    keyEditor
                }

                SecureField("Passphrase (optional)", text: draft.keyPassphrase)
            }
        } header: {
            Text("Private Key")
        } footer: {
            if viewModel.jumpHostCredentialsUnreadable {
                Text(ConnectionFormViewModel.jumpHostKeysUnreadableMessage)
            } else if !viewModel.serverSignsInWithKey {
                Text("The SSH server does not sign in with a private key, so this jump host needs its own key.")
            }
        }
        .disabled(viewModel.jumpHostCredentialsUnreadable)
    }

    private var keyEditor: some View {
        TextEditor(text: draft.keyContent)
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 120)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .overlay(alignment: .topLeading) {
                if hop?.keyContent.isEmpty ?? true {
                    Text("Paste private key (PEM format)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
            }
    }
}
