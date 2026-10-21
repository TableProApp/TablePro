import SwiftUI
import TableProSSHTransport

struct MacRouteSection: View {
    let viewModel: ConnectionFormViewModel
    let route: PublishedSSHRoute

    var body: some View {
        Section {
            ForEach(route.hops, id: \.id) { hop in
                if viewModel.isRouteOnlyHop(hop.id) {
                    NavigationLink {
                        JumpHostEditorView(viewModel: viewModel, hopId: hop.id)
                    } label: {
                        hopRow(hop)
                    }
                } else {
                    hopRow(hop)
                }
            }
            LabeledContent("SSH Server") {
                Text(verbatim: Self.address(route.target.username, route.target.host, route.target.port))
                    .textSelection(.enabled)
            }
        } header: {
            Text("Route from Mac")
        } footer: {
            Text("Your Mac reaches the SSH server through these hosts from its ~/.ssh/config, and this device dials the same route with its own keys. Changing the SSH server or jump hosts above replaces it.")
        }
    }

    private func hopRow(_ hop: PublishedSSHRoute.Hop) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: Self.address(hop.username, hop.host, hop.port))
            if hop.alias != hop.host {
                Text(verbatim: hop.alias)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.jumpHostCredentialsUnreadable, let draft = viewModel.jumpHost(hop.id) {
                JumpHostKeyStatusLabel(status: viewModel.keyStatus(of: draft))
            }
        }
    }

    private static func address(_ username: String, _ host: String, _ port: Int) -> String {
        let endpoint = port == PublishedSSHRoute.defaultPort ? host : "\(host):\(port)"
        return username.isEmpty ? endpoint : "\(username)@\(endpoint)"
    }
}
