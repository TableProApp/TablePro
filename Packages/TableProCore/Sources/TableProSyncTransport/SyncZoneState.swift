import Foundation

/// What this device knows about TablePro's zone in iCloud.
///
/// Persisted, because the one state that waits for the person has to survive a relaunch: held only
/// in memory, the first run after launch recreated a zone the person had deleted in iCloud settings
/// and filled it again without asking, which Apple asks apps never to do.
public enum SyncZoneState: String, Sendable {
    /// Never created or seen from this device, or forgotten with the account it belonged to.
    case unknown
    case confirmed
    /// It existed and is gone. Nothing uploads until the person chooses.
    case removed

    /// Only a run that may upload creates the zone, and only when this device has never seen it.
    public func createsZone(in admission: SyncAdmission) -> Bool {
        self == .unknown && admission == .full
    }

    /// The download failure that counts. A zone this device never saw is not a deleted one: it
    /// has nothing to download yet, as on a new device whose first zone save failed on full storage.
    public func reconciled(downloadFailure: SyncStepFailure?) -> SyncStepFailure? {
        guard self == .unknown, downloadFailure?.error == .blocked(.dataDeletedFromICloud) else { return downloadFailure }
        return nil
    }

    /// What the zone is known to be once a run ends with `failure`, and with or without a download
    /// that reached it.
    public func after(failure: SyncStepFailure?, reachedZone: Bool) -> SyncZoneState {
        if failure?.error == .blocked(.dataDeletedFromICloud) {
            return .removed
        }
        return reachedZone ? .confirmed : self
    }

    /// The status sync starts from: a removed zone is still waiting for the person after a relaunch.
    public var initialStatus: SyncStatus {
        self == .removed ? .error(.blocked(.dataDeletedFromICloud)) : .idle
    }
}
