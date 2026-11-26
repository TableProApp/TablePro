import SwiftUI

// Where the account signs in: tablepro.app, or the organization's own TablePro server (core ADR 0047, The server).
struct AccountServerPage: View {
    private static let addressExample = "https://tablepro.example.com"

    let account: AccountModel
    let managed: ManagedAppConfiguration

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await choose(nil) }
                } label: {
                    LabeledContent {
                        if isDefault {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    } label: {
                        Text(verbatim: defaultHost)
                            .foregroundStyle(.primary)
                    }
                }
                .disabled(account.isBusy)
            } footer: {
                if managedHost != nil {
                    Text("Your organization's server.")
                }
            }

            Section {
                LiteralTextField(Self.addressExample, text: $address, keyboardType: .URL)
                    .accessibilityIdentifier("account-server-address")
                Button(String(localized: "Use This Server")) {
                    guard let url = URL(string: trimmedAddress) else {
                        failure = AccountError.companyServer(.invalidAddress).mobileDescription
                        return
                    }
                    Task { await choose(url) }
                }
                .disabled(trimmedAddress.isEmpty || account.isBusy)
            } header: {
                Text("Company Server")
            } footer: {
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                } else {
                    Text("Your organization's TablePro server, if it runs one. Ask your administrator for its address.")
                }
            }
        }
        .navigationTitle(String(localized: "Server"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !account.server.isProduction, !account.server.isManaged {
                address = account.server.apiOrigin.absoluteString
            }
        }
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var managedHost: String? {
        managed.accountServerURL.flatMap { URL(string: $0)?.host() }
    }

    // With no choice of the person's, the organization's server, else tablepro.app.
    private var defaultHost: String {
        managedHost ?? AccountServer.production.host
    }

    private var isDefault: Bool {
        account.server.isManaged || (managedHost == nil && account.server.isProduction)
    }

    private func choose(_ url: URL?) async {
        failure = nil
        do throws(AccountError) {
            try await account.chooseServer(url)
            dismiss()
        } catch {
            failure = error.mobileDescription
        }
    }
}
