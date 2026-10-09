import Foundation

/// How the last sync run ended, in terms the person can act on.
///
/// Carries no text. Each app words it for its own platform ("this Mac", "the Settings app"), and
/// CloudKit's own descriptions never reach the screen: they are untranslated English with record ids
/// in them.
public enum SyncError: Equatable, Sendable {
    /// A condition outside the sync stops it until it changes.
    case blocked(SyncBlocker)

    /// iCloud could not be reached.
    case offline

    /// iCloud asked TablePro to slow down; the next attempt waits for the time it named.
    case busy

    /// iCloud refused these items one by one. They stay on the device and go again on the next run;
    /// everything else synced.
    case recordsRejected(count: Int)

    /// Downloaded changes could not be saved on this device. They download again next time.
    case pullNotSaved

    /// Anything else CloudKit refused. The detail goes to the log, not the screen.
    case unexpected

    /// Nil for a cancellation, which ends a run without an outcome to report.
    public init?(_ failure: SyncFailure) {
        switch failure {
        case .blocked(let blocker):
            self = .blocked(blocker)
        case .offline:
            self = .offline
        case .busy:
            self = .busy
        case .failed, .tokenExpired:
            self = .unexpected
        case .cancelled:
            return nil
        }
    }

    public init?(_ error: any Error) {
        self.init(SyncFailure(error))
    }

    public var blocker: SyncBlocker? {
        guard case .blocked(let blocker) = self else { return nil }
        return blocker
    }
}
