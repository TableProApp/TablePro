import SwiftUI
import TableProSyncTransport

struct ConnectionListEmptyActions {
    let addConnection: () -> Void
    let openSample: () -> Void
    let turnOnICloud: (() -> Void)?
    let importConnections: () -> Void
    let performSyncAction: (SyncStatusAction) -> Void
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
        let presentation = SyncStatusPresentation(error)
        return ContentUnavailableView {
            Label(presentation.title, systemImage: presentation.systemImage)
        } description: {
            VStack(spacing: 8) {
                Text(presentation.message)
                if let guidance = presentation.guidance {
                    Text(guidance)
                }
            }
        } actions: {
            ForEach(presentation.actions) { action in
                SyncActionButton(
                    action: action,
                    isPrimary: action == presentation.actions.first,
                    perform: actions.performSyncAction
                )
            }
            if presentation.actions.isEmpty {
                Button("Add Connection", action: actions.addConnection)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Add Connection", action: actions.addConnection)
                    .buttonStyle(.bordered)
            }
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
    let perform: (SyncStatusAction) -> Void

    var body: some View {
        let presentation = SyncStatusPresentation(error)
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                Text(presentation.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let guidance = presentation.guidance {
                    Text(guidance)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !presentation.actions.isEmpty {
                    HStack(spacing: 20) {
                        ForEach(presentation.actions) { action in
                            /// Borderless, so each button takes its own taps inside the list row.
                            Button(action.title) { perform(action) }
                                .buttonStyle(.borderless)
                                .font(.subheadline)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(.orange)
        }
    }
}

private struct SyncActionButton: View {
    let action: SyncStatusAction
    let isPrimary: Bool
    let perform: (SyncStatusAction) -> Void

    var body: some View {
        if isPrimary {
            Button(action.title) { perform(action) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.title) { perform(action) }
                .buttonStyle(.bordered)
        }
    }
}
