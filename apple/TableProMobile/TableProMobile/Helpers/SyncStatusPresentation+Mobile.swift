import Foundation
import TableProSyncTransport

// The wording for iPhone and iPad. Titles, symbols and actions come from the shared presentation,
// and CloudKit's own text never reaches the screen.
nonisolated extension SyncStatusPresentation {
    var message: String {
        guard let error = status.error else { return "" }
        return Self.message(for: error)
    }

    // iOS has no public URL that opens iCloud settings, so that path is said in words.
    var guidance: String? {
        blocker == .storageFull
            ? String(localized: "To free up space, open Settings, tap your name, then tap iCloud.")
            : nil
    }

    // No public URL opens the Apple Account or storage pane, and the App Store updates the app.
    var mobileActions: [SyncStatusAction] {
        actions.filter { action in
            switch action {
            case .tryAgain, .uploadAgain, .turnOffSync:
                true
            case .manageStorage, .openAccountSettings, .checkForUpdates:
                false
            }
        }
    }

    private static func message(for error: SyncError) -> String {
        switch error {
        case .blocked(let blocker):
            return message(for: blocker)
        case .offline:
            return String(localized: "Cannot reach iCloud. Changes sync when this device is back online.")
        case .busy:
            return String(localized: "iCloud asked TablePro to wait. It tries again on its own shortly.")
        case .recordsRejected(let count):
            guard count != 1 else {
                return String(localized: "1 change could not be uploaded to iCloud. It stays on this device and goes again on the next sync.")
            }
            return String(
                format: String(localized: "%lld changes could not be uploaded to iCloud. They stay on this device and go again on the next sync."),
                Int64(count)
            )
        case .pullNotSaved:
            return String(localized: "Changes from iCloud could not be saved on this device. They download again on the next sync.")
        case .unexpected:
            return String(localized: "iCloud could not complete the sync. TablePro tries again on the next sync.")
        }
    }

    private static func message(for blocker: SyncBlocker) -> String {
        switch blocker {
        case .storageFull:
            return String(
                localized: "TablePro cannot upload changes until there is space in iCloud. Changes on this device are kept here and upload once you free up space or add storage."
            )
        case .signedOut:
            return String(localized: "Sign in to iCloud in the Settings app to sync your connections.")
        case .accountNotReady:
            return String(localized: "iCloud is not ready on this device yet. Sync resumes on its own when it is.")
        case .accountRestricted:
            return String(localized: "Screen Time or device management does not allow iCloud on this device, so TablePro cannot sync.")
        case .dataDeletedFromICloud:
            return String(
                localized: "TablePro's data is no longer in iCloud. It may have been deleted in iCloud settings. Upload what this device has again, or turn off iCloud Sync to keep it here only."
            )
        case .appUpdateRequired:
            return String(localized: "This version of TablePro can no longer sync with iCloud. Update TablePro in the App Store to resume.")
        case .unavailable:
            return String(localized: "iCloud sync is not available in this build of TablePro.")
        }
    }
}

extension AppState {
    // Turning sync off goes through the same path as the Settings toggle, so the choice is
    // recorded as the person's.
    func performSyncAction(_ action: SyncStatusAction) {
        switch action {
        case .tryAgain:
            Task { await syncCoordinator.sync(.userRequest) }
        case .uploadAgain:
            Task { await syncCoordinator.uploadAgain() }
        case .turnOffSync:
            setCloudSyncEnabled(false)
        case .manageStorage, .openAccountSettings, .checkForUpdates:
            break
        }
    }
}
