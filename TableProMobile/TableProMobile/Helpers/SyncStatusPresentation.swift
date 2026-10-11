import Foundation
import TableProSyncTransport

/// What the person can do about a sync problem from where it is shown.
nonisolated enum SyncStatusAction: Hashable, Identifiable, Sendable {
    case tryAgain
    case uploadAgain
    case turnOffSync

    var id: Self { self }

    var title: String {
        switch self {
        case .tryAgain:
            return String(localized: "Try Again")
        case .uploadAgain:
            return String(localized: "Upload Again")
        case .turnOffSync:
            return String(localized: "Turn Off iCloud Sync")
        }
    }
}

/// How a sync outcome reads on iPhone and iPad.
///
/// Every outcome is worded here, exhaustively, so CloudKit's own text never reaches the screen: it
/// is untranslated English with record ids in it. "Try Again" is offered only where trying again
/// can help.
nonisolated struct SyncStatusPresentation: Equatable, Sendable {
    let title: String
    let message: String

    /// The path to the fix, for a fix that lives in the Settings app. iOS has no public URL that
    /// opens iCloud settings, so it is said in words rather than offered as a button.
    let guidance: String?
    let systemImage: String
    let actions: [SyncStatusAction]

    init(_ error: SyncError) {
        switch error {
        case .blocked(let blocker):
            self.init(blocker)
        case .offline:
            self.init(
                title: String(localized: "Offline"),
                message: String(localized: "Cannot reach iCloud. Changes sync when this device is back online."),
                systemImage: "icloud.slash",
                actions: [.tryAgain]
            )
        case .busy:
            self.init(
                title: String(localized: "Waiting to Retry"),
                message: String(localized: "iCloud asked TablePro to wait. It tries again on its own shortly."),
                systemImage: "exclamationmark.icloud",
                actions: [.tryAgain]
            )
        case .recordsRejected(let count):
            self.init(
                title: String(localized: "Some Changes Not Uploaded"),
                message: Self.rejectedMessage(count: count),
                systemImage: "exclamationmark.icloud",
                actions: [.tryAgain]
            )
        case .pullNotSaved:
            self.init(
                title: String(localized: "Changes Not Saved"),
                message: String(localized: "Changes from iCloud could not be saved on this device. They download again on the next sync."),
                systemImage: "exclamationmark.icloud",
                actions: [.tryAgain]
            )
        case .unexpected:
            self.init(
                title: String(localized: "Sync Failed"),
                message: String(localized: "iCloud could not complete the sync. TablePro tries again on the next sync."),
                systemImage: "exclamationmark.icloud",
                actions: [.tryAgain]
            )
        }
    }

    private init(_ blocker: SyncBlocker) {
        switch blocker {
        case .storageFull:
            let message = String(
                localized: "TablePro cannot upload changes until there is space in iCloud. Changes on this device are kept here and upload once you free up space or add storage."
            )
            self.init(
                title: String(localized: "iCloud Storage Is Full"),
                message: message,
                guidance: String(localized: "To free up space, open Settings, tap your name, then tap iCloud."),
                systemImage: "exclamationmark.icloud",
                actions: [.tryAgain]
            )
        case .signedOut:
            self.init(
                title: String(localized: "Not Signed In to iCloud"),
                message: String(localized: "Sign in to iCloud in the Settings app to sync your connections."),
                systemImage: "icloud.slash",
                actions: [.tryAgain]
            )
        case .accountNotReady:
            self.init(
                title: String(localized: "iCloud Is Not Ready"),
                message: String(localized: "iCloud is not ready on this device yet. Sync resumes on its own when it is."),
                systemImage: "icloud.slash",
                actions: [.tryAgain]
            )
        case .accountRestricted:
            self.init(
                title: String(localized: "iCloud Is Restricted"),
                message: String(localized: "Screen Time or device management does not allow iCloud on this device, so TablePro cannot sync."),
                systemImage: "icloud.slash",
                actions: []
            )
        case .dataDeletedFromICloud:
            self.init(
                title: String(localized: "TablePro Data Was Removed from iCloud"),
                message: String(
                    localized: "TablePro's data is no longer in iCloud. It may have been deleted in iCloud settings. Upload what this device has again, or turn off iCloud Sync to keep it here only."
                ),
                systemImage: "exclamationmark.icloud",
                actions: [.uploadAgain, .turnOffSync]
            )
        case .appUpdateRequired:
            self.init(
                title: String(localized: "Update Required"),
                message: String(localized: "This version of TablePro can no longer sync with iCloud. Update TablePro in the App Store to resume."),
                systemImage: "exclamationmark.icloud",
                actions: []
            )
        case .unavailable:
            self.init(
                title: String(localized: "Sync Is Unavailable"),
                message: String(localized: "iCloud sync is not available in this build of TablePro."),
                systemImage: "icloud.slash",
                actions: []
            )
        }
    }

    private init(
        title: String,
        message: String,
        guidance: String? = nil,
        systemImage: String,
        actions: [SyncStatusAction]
    ) {
        self.title = title
        self.message = message
        self.guidance = guidance
        self.systemImage = systemImage
        self.actions = actions
    }

    private static func rejectedMessage(count: Int) -> String {
        guard count != 1 else {
            return String(localized: "1 change could not be uploaded to iCloud. It stays on this device and goes again on the next sync.")
        }
        return String(
            format: String(localized: "%lld changes could not be uploaded to iCloud. They stay on this device and go again on the next sync."),
            Int64(count)
        )
    }
}

extension AppState {
    /// Turning sync off goes through the same path as the Settings toggle, so the choice is
    /// recorded as the person's.
    func performSyncAction(_ action: SyncStatusAction) {
        switch action {
        case .tryAgain:
            Task { await syncCoordinator.sync(.userRequest) }
        case .uploadAgain:
            Task { await syncCoordinator.uploadAgain() }
        case .turnOffSync:
            setCloudSyncEnabled(false)
        }
    }
}
