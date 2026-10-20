import SwiftUI

struct JumpHostsSection: View {
    let viewModel: ConnectionFormViewModel
    var onAdd: (UUID) -> Void

    var body: some View {
        Section {
            ForEach(viewModel.jumpHosts) { hop in
                NavigationLink {
                    JumpHostEditorView(viewModel: viewModel, hopId: hop.id)
                } label: {
                    row(for: hop)
                }
            }
            .onDelete { viewModel.removeJumpHosts(atOffsets: $0) }
            .onMove { viewModel.moveJumpHosts(fromOffsets: $0, toOffset: $1) }

            Button {
                onAdd(viewModel.addJumpHost())
            } label: {
                Label("Add Jump Host", systemImage: "plus.circle")
            }
        } header: {
            Text("Jump Hosts")
        } footer: {
            Text("Jump hosts are connected in order before reaching the SSH server above.")
        }
    }

    private func row(for hop: JumpHostDraft) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if hop.hasHost {
                Text(verbatim: hop.username.isEmpty ? hop.host : "\(hop.username)@\(hop.host)")
            } else {
                Text("New Jump Host")
                    .foregroundStyle(.secondary)
            }
            if !viewModel.jumpHostCredentialsUnreadable {
                keyStatus(viewModel.keyStatus(of: hop))
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func keyStatus(_ status: ConnectionFormViewModel.JumpHostKeyStatus) -> some View {
        switch status {
        case .sameKey:
            Text("Same key as SSH server")
                .foregroundStyle(.secondary)
        case .ownKey:
            Text("Own key")
                .foregroundStyle(.secondary)
        case .noKey:
            Text("No key on this device")
                .foregroundStyle(.red)
        }
    }
}
