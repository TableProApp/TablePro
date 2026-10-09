import Foundation
import Network
import os

/// Reports each return to a usable network path.
///
/// CloudKit's guidance for a network failure is to wait for reachability and send the operation
/// again, so a run that could not reach iCloud resumes when the path comes back instead of at the
/// next activation or edit.
public final class SyncNetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()
    private let wasSatisfied = OSAllocatedUnfairLock(initialState: true)

    public init() {}

    deinit {
        monitor.cancel()
    }

    /// `onRestored` runs on a private queue each time the path turns usable after it was not.
    public func start(onRestored: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [wasSatisfied] path in
            let satisfied = path.status == .satisfied
            let restored = wasSatisfied.withLock { previous in
                defer { previous = satisfied }
                return satisfied && !previous
            }
            if restored {
                onRestored()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.TablePro.syncNetworkMonitor"))
    }
}
