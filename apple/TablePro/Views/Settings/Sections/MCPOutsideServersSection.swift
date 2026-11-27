import SwiftUI
import TableProMCP

// The opposite direction from the server above it, what TablePro may ask of an outside server, so it shows whether or not the server is on.
internal struct MCPOutsideServersSection: View {
    private struct SheetTarget: Identifiable {
        let id: UUID
        let server: MCPServerConfiguration?
    }

    @ObservedObject private var store = MCPServerStore.shared

    @State private var sheet: SheetTarget?
    @State private var removalCandidate: MCPServerConfiguration?

    var body: some View {
        Section {
            if store.servers.isEmpty {
                Text("No servers")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.servers) { server in
                    row(server)
                }
            }

            // swiftlint:disable:next line_length
            SettingsHelpRow("A session can call tools on a server you add here once you allow it on a connection. Every call waits for you to approve it, and the arguments leave this Mac.")
        } header: {
            Text("Outside MCP Servers")
        } footer: {
            SettingsSectionActions {
                Button(String(localized: "Add Server…")) {
                    sheet = SheetTarget(id: UUID(), server: nil)
                }
                .accessibilityIdentifier("mcp-outside-server-add")
            }
        }
        .sheet(item: $sheet) { target in
            MCPOutsideServerSheet(server: target.server)
        }
        .alert(
            String(localized: "Remove Server?"),
            isPresented: removalBinding,
            presenting: removalCandidate
        ) { server in
            Button(String(localized: "Remove"), role: .destructive) {
                store.remove(id: server.id)
                removalCandidate = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                removalCandidate = nil
            }
        } message: { server in
            Text(String(
                format: String(localized: "“%@” and its token are removed from this Mac. Sessions lose its tools."),
                server.name
            ))
        }
    }

    private func row(_ server: MCPServerConfiguration) -> some View {
        SettingsRecordRow(
            title: server.name,
            subtitle: server.endpoint.absoluteString,
            value: Self.reach(of: server)
        )
        .infoButton(
            onEdit: { sheet = SheetTarget(id: server.id, server: server) },
            removal: .remove { removalCandidate = server },
            identifier: "mcp-outside-server-edit-\(server.id.uuidString)"
        )
    }

    // How far a server reaches is the one thing worth reading at a glance: one allowed nowhere is inert.
    static func reach(of server: MCPServerConfiguration) -> String {
        let count = server.allowedConnectionIds.count
        guard count > 0 else { return String(localized: "No connections") }
        return String(AttributedString(localized: "^[\(count) connection](inflect: true)").characters)
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )
    }
}
