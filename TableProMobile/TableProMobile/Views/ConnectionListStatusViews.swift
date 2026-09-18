import SwiftUI
import TableProSyncTransport

struct ConnectionListEmptyActions {
    let addConnection: () -> Void
    let openSample: () -> Void
    let turnOnICloud: (() -> Void)?
    let importConnections: () -> Void
    let retrySync: () -> Void
    let retryLoad: () -> Void
}

struct ConnectionListStatusView: View {
    let state: ConnectionListState
    let actions: ConnectionListEmptyActions

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            failedView
        case .checkingICloud:
            checkingView
        case .iCloudUnavailable(let error):
            unavailableView(error)
        case .empty(let syncsWithICloud):
            emptyView(syncsWithICloud: syncsWithICloud)
        case .content:
            EmptyView()
        }
    }

    private var failedView: some View {
        ContentUnavailableView {
            Label("Connections Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("TablePro could not read your saved connections. Nothing on this device has been changed.")
        } actions: {
            Button("Try Again", action: actions.retryLoad)
                .buttonStyle(.borderedProminent)
        }
    }

    private var checkingView: some View {
        ContentUnavailableView {
            Label {
                Text("Checking iCloud")
            } icon: {
                ProgressView()
                    .controlSize(.large)
            }
        } description: {
            Text("Connections from your other devices appear here.")
        }
    }

    private func unavailableView(_ error: SyncError) -> some View {
        ContentUnavailableView {
            Label("iCloud Unavailable", systemImage: "exclamationmark.icloud")
        } description: {
            Text(ConnectionListSyncMessage.text(for: error))
        } actions: {
            Button("Try Again", action: actions.retrySync)
                .buttonStyle(.borderedProminent)
            Button("Add Connection", action: actions.addConnection)
                .buttonStyle(.bordered)
        }
    }

    private func emptyView(syncsWithICloud: Bool) -> some View {
        ContentUnavailableView {
            Label("No Connections", systemImage: "server.rack")
        } description: {
            if syncsWithICloud {
                Text("Connections you add here or in TablePro on your Mac appear on all your devices.")
            } else {
                Text("Add a connection to your database, or explore TablePro with the sample database.")
            }
        } actions: {
            Button("Add Connection", action: actions.addConnection)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("empty-add-connection")
            Button("Open Sample Database", action: actions.openSample)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("empty-open-sample")
            if let turnOnICloud = actions.turnOnICloud {
                Button("Turn On iCloud Sync", action: turnOnICloud)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("empty-turn-on-icloud")
            } else {
                Button("Import Connections", action: actions.importConnections)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("empty-import-connections")
            }
        }
    }
}

struct ConnectionListSyncProblemRow: View {
    let error: SyncError
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label {
                Text(ConnectionListSyncMessage.text(for: error))
                    .font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again", action: retry)
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
    }
}

enum ConnectionListSyncMessage {
    static func text(for error: SyncError) -> String {
        switch error {
        case .accountUnavailable:
            return String(localized: "Sign in to iCloud in the Settings app to sync your connections.")
        default:
            return error.localizedDescription
        }
    }
}
