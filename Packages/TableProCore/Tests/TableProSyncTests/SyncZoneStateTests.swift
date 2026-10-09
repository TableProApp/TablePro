import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync zone state")
struct SyncZoneStateTests {
    private static let removedFailure = SyncStepFailure(
        failure: .blocked(.dataDeletedFromICloud),
        error: .blocked(.dataDeletedFromICloud),
        retryAfter: nil
    )

    @Test("Only a run that may upload creates a zone this device never saw")
    func zoneCreation() {
        #expect(SyncZoneState.unknown.createsZone(in: .full))
        #expect(!SyncZoneState.unknown.createsZone(in: .downloadOnly))
        #expect(!SyncZoneState.confirmed.createsZone(in: .full))
        #expect(!SyncZoneState.removed.createsZone(in: .full))
    }

    /// A new device whose first zone save failed on full storage has a zone to wait for, not a
    /// deleted one.
    @Test("A missing zone this device never saw is nothing to download, not a deletion")
    func unknownZoneIsNotRemoved() {
        #expect(SyncZoneState.unknown.reconciled(downloadFailure: Self.removedFailure) == nil)
        #expect(SyncZoneState.confirmed.reconciled(downloadFailure: Self.removedFailure) == Self.removedFailure)
        #expect(SyncZoneState.removed.reconciled(downloadFailure: Self.removedFailure) == Self.removedFailure)
    }

    @Test("A zone found gone is removed; a download that reached it confirms it")
    func stateAfterARun() {
        #expect(SyncZoneState.confirmed.after(failure: Self.removedFailure, reachedZone: false) == .removed)
        #expect(SyncZoneState.removed.after(failure: nil, reachedZone: true) == .confirmed)
        #expect(SyncZoneState.unknown.after(failure: nil, reachedZone: false) == .unknown)
        #expect(SyncZoneState.confirmed.after(failure: .pullNotSaved, reachedZone: false) == .confirmed)
    }

    /// Held only in memory, the block was gone after a relaunch, and the first run recreated the
    /// zone and uploaded into it without asking.
    @Test("A removed zone still waits for the person after a relaunch")
    func removedSurvivesRelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.zone.\(UUID().uuidString)"))
        SyncMetadataStorage(userDefaults: defaults).zoneState = .removed

        let relaunched = SyncMetadataStorage(userDefaults: defaults)

        #expect(relaunched.zoneState == .removed)
        #expect(relaunched.zoneState.initialStatus == .error(.blocked(.dataDeletedFromICloud)))
        #expect(SyncZoneState.unknown.initialStatus == .idle)
    }

    /// Builds before the key saved the zone on every run, so a device they synced has seen it.
    @Test("A device an earlier build synced reads its zone as confirmed; a new install does not")
    func legacyDevicesHaveSeenTheZone() throws {
        let synced = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.zone.\(UUID().uuidString)"))
        )
        synced.lastSyncDate = Date(timeIntervalSince1970: 1_000)
        let fresh = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.zone.\(UUID().uuidString)"))
        )

        #expect(synced.zoneState == .confirmed)
        #expect(fresh.zoneState == .unknown)
    }

    @Test("Another account forgets the zone")
    func accountSwitchForgetsTheZone() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.zone.\(UUID().uuidString)"))
        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.adoptAccount("a")
        storage.zoneState = .removed

        storage.adoptAccount("b")

        #expect(storage.zoneState == .unknown)
    }
}
