import SwiftUI

// The devices the account is signed in on. Removing one signs it out and frees its slot.
struct AccountDevicesPage: View {
    private enum Devices {
        case loading
        case loaded([AccountDevice])
        case failed(String)
    }

    let account: AccountModel

    @State private var devices: Devices = .loading
    @State private var pendingRemoval: AccountDevice?
    @State private var failure: String?

    var body: some View {
        List {
            switch devices {
            case .loading:
                ProgressView()
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
            case .loaded(let devices):
                Section {
                    ForEach(devices) { device in
                        row(device)
                    }
                } footer: {
                    if let failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Devices"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            pendingRemoval.map { String(format: String(localized: "Remove “%@”?"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { device in
            Button(String(localized: "Remove"), role: .destructive) {
                Task { await remove(device) }
            }
        } message: { _ in
            Text("It is signed out of TablePro and frees its slot.")
        }
    }

    private func row(_ device: AccountDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: device.name)
            Text(detail(device))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .swipeActions {
            if !device.isThisDevice {
                Button(String(localized: "Remove"), role: .destructive) {
                    pendingRemoval = device
                }
            }
        }
    }

    private func detail(_ device: AccountDevice) -> String {
        let system = AccountCodes.systemName(platform: device.platform, osVersion: device.osVersion)
        guard !device.isThisDevice else {
            return String(format: String(localized: "%@ · %@"), String(localized: "This Device"), system)
        }
        let lastSeen = device.lastSeenAt.formatted(.relative(presentation: .named))
        return String(format: String(localized: "%@ · Last seen %@"), system, lastSeen)
    }

    private func load() async {
        do throws(AccountError) {
            devices = .loaded(try await account.devices())
        } catch {
            // A refresh keeps the list it has.
            guard case .loaded = devices else {
                devices = .failed(error.mobileDescription ?? String(localized: "The devices could not be loaded."))
                return
            }
            failure = error.mobileDescription
        }
    }

    private func remove(_ device: AccountDevice) async {
        failure = nil
        do throws(AccountError) {
            try await account.removeDevice(device.id)
            await load()
        } catch {
            failure = error.mobileDescription
        }
    }
}
