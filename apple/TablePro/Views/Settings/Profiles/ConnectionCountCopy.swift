import SwiftUI

enum ProfileKind: Hashable, Sendable {
    case credential
    case ssh

    func isLinked(_ connection: DatabaseConnection, to profileId: UUID) -> Bool {
        switch self {
        case .credential: connection.credentialMode == .profile(id: profileId)
        case .ssh: connection.isLinked(toSSHProfile: profileId)
        }
    }
}

struct PendingProfileDeletion: Identifiable, Equatable, Sendable {
    let kind: ProfileKind
    let id: UUID
    let name: String
    let dependentCount: Int
    let someConnectionsUnreadable: Bool

    // Nil while the connections can't be read: the count, and so the consequences, are unknown.
    @MainActor
    static func make(
        kind: ProfileKind,
        id: UUID,
        name: String,
        connectionStorage: ConnectionStorage = .shared
    ) -> PendingProfileDeletion? {
        let connections = connectionStorage.loadConnections()
        guard !connectionStorage.lastLoadFailed else { return nil }
        return PendingProfileDeletion(
            kind: kind,
            id: id,
            name: name,
            dependentCount: connections.filter { kind.isLinked($0, to: id) }.count,
            someConnectionsUnreadable: !connectionStorage.unreadableConnectionIds.isEmpty
        )
    }

    var title: String {
        String(format: String(localized: "Delete “%@”?"), name)
    }

    var message: String {
        let consequence = ConnectionCountCopy.deletionConsequence(kind: kind, dependentCount: dependentCount)
        guard someConnectionsUnreadable else { return consequence }
        let unknown = String(localized: "TablePro can't read some saved connections, so it can't tell whether they use this profile.")
        return "\(consequence) \(unknown)"
    }
}

enum ConnectionCountCopy {
    static func usage(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "Not used")
        case 1: String(format: String(localized: "%lld connection"), Int64(count))
        default: String(format: String(localized: "%lld connections"), Int64(count))
        }
    }

    static func deletionConsequence(kind: ProfileKind, dependentCount: Int) -> String {
        switch (kind, dependentCount) {
        case (_, 0):
            String(localized: "This profile will be permanently deleted.")
        case (.credential, 1):
            String(localized: "1 connection uses this profile. It keeps these credentials as its own.")
        case (.credential, _):
            String(
                format: String(localized: "%lld connections use this profile. They keep these credentials as their own."),
                Int64(dependentCount)
            )
        case (.ssh, 1):
            String(localized: "1 connection uses this profile. It keeps this configuration as its own SSH tunnel.")
        case (.ssh, _):
            String(
                format: String(localized: "%lld connections use this profile. They keep this configuration as their own SSH tunnel."),
                Int64(dependentCount)
            )
        }
    }

    static func unreadableProfiles(_ count: Int) -> String {
        switch count {
        case 1:
            String(localized: "1 profile was saved by a newer version of TablePro and can't be shown here.")
        default:
            String(
                format: String(localized: "%lld profiles were saved by a newer version of TablePro and can't be shown here."),
                Int64(count)
            )
        }
    }

    static var deleteFailedTitle: String {
        String(localized: "Couldn't Delete Profile")
    }

    static var deleteFailedMessage: String {
        String(localized: "Its saved secrets or the connections that use it couldn't be updated, so nothing was deleted.")
    }

    static var duplicateFailedTitle: String {
        String(localized: "Couldn't Duplicate Profile")
    }

    static var duplicateFailedMessage: String {
        String(localized: "Its saved secrets couldn't be read or copied, so no copy was made.")
    }
}

extension View {
    func profileDeletionAlert(
        _ pending: Binding<PendingProfileDeletion?>,
        onDelete: @escaping (PendingProfileDeletion) -> Void
    ) -> some View {
        alert(
            pending.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            presenting: pending.wrappedValue
        ) { item in
            Button(String(localized: "Delete"), role: .destructive) { onDelete(item) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { item in
            Text(verbatim: item.message)
        }
    }
}
