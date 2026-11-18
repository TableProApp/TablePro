import CloudKit
import Foundation
import Testing

import TableProSyncTransport

@MainActor
struct SyncPushChannelTests {
    private let metadata: SyncMetadataStorage
    private let calls = RegistrarCalls()

    init() {
        metadata = SyncMetadataStorage(userDefaults: ScratchDefaults.make() ?? .standard)
        metadata.lastAccountId = "account-a"
    }

    private func makeChannel() -> SyncPushChannel {
        let calls = calls
        return SyncPushChannel(
            registrar: SyncPushRegistrar(register: { calls.registrations += 1 }, unregister: { calls.unregistrations += 1 }),
            metadata: metadata
        )
    }

    @Test("Registering twice asks once, and nothing is taken back that was never asked for")
    func registrationIsAskedOnce() {
        let channel = makeChannel()
        channel.unregister()
        #expect(calls.unregistrations == 0)

        channel.register()
        channel.register()
        #expect(calls.registrations == 1)

        channel.unregister()
        #expect(calls.unregistrations == 1)
    }

    @Test("Push is live only with a device registration and this account's subscription")
    func liveNeedsRegistrationAndSubscription() async {
        let channel = makeChannel()
        channel.registrationDidFinish(registered: true)
        #expect(!channel.isLive)

        channel.register()
        channel.registrationDidFinish(registered: true)
        #expect(!channel.isLive)

        await channel.saveSubscriptionIfNeeded {}
        #expect(channel.isLive)

        metadata.lastAccountId = "account-b"
        #expect(!channel.isLive)
    }

    @Test("A failed registration or turning sync off ends push")
    func failedRegistrationEndsPush() async {
        let channel = makeChannel()
        channel.register()
        await channel.saveSubscriptionIfNeeded {}
        channel.registrationDidFinish(registered: false)
        #expect(!channel.isLive)

        channel.registrationDidFinish(registered: true)
        #expect(channel.isLive)
        channel.unregister()
        #expect(!channel.isLive)
    }

    @Test("Unannounced changes end push and save the subscription again, until the next notice")
    func unannouncedChangesEndPush() async {
        let channel = makeChannel()
        #expect(!channel.activationFoundUnannouncedChanges(noticesSince: channel.noticesReceived))

        channel.register()
        channel.registrationDidFinish(registered: true)
        await channel.saveSubscriptionIfNeeded {}
        #expect(channel.activationFoundUnannouncedChanges(noticesSince: channel.noticesReceived))
        #expect(!channel.isLive)
        #expect(metadata.subscribedAccountId == nil)

        var saves = 0
        await channel.saveSubscriptionIfNeeded { saves += 1 }
        #expect(saves == 1)
        #expect(!channel.isLive)

        channel.noticeArrived()
        #expect(channel.isLive)
    }

    @Test("Changes an activation brings are announced when a notice came since the last download began")
    func noticeSinceTheLastDownloadAnnouncesChanges() async {
        let channel = makeChannel()
        channel.register()
        channel.registrationDidFinish(registered: true)
        await channel.saveSubscriptionIfNeeded {}
        let atLastDownload = channel.noticesReceived

        channel.noticeArrived()

        #expect(!channel.activationFoundUnannouncedChanges(noticesSince: atLastDownload))
        #expect(channel.isLive)
    }

    @Test("The subscription is saved once per account")
    func savedOncePerAccount() async {
        let channel = makeChannel()
        var saves = 0
        await channel.saveSubscriptionIfNeeded { saves += 1 }
        await channel.saveSubscriptionIfNeeded { saves += 1 }
        #expect(saves == 1)
        #expect(metadata.subscribedAccountId == "account-a")

        metadata.lastAccountId = "account-b"
        await channel.saveSubscriptionIfNeeded { saves += 1 }
        #expect(saves == 2)
        #expect(metadata.subscribedAccountId == "account-b")

        channel.forgetSubscription()
        await channel.saveSubscriptionIfNeeded { saves += 1 }
        #expect(saves == 3)
    }

    @Test("A save that fails for a reason that can pass is tried again on the next run",
          arguments: [CKError.Code.networkFailure, .accountTemporarilyUnavailable, .internalError, .serviceUnavailable])
    func passingFailureRetries(_ code: CKError.Code) async {
        let channel = makeChannel()
        var saves = 0
        await channel.saveSubscriptionIfNeeded {
            saves += 1
            throw CKError(code)
        }
        #expect(metadata.subscribedAccountId == nil)

        await channel.saveSubscriptionIfNeeded { saves += 1 }
        #expect(saves == 2)
        #expect(metadata.subscribedAccountId == "account-a")
    }

    @Test("A save CloudKit refuses is not sent again for that account, but is for the next one")
    func refusedSaveIsNotRepeated() async {
        let channel = makeChannel()
        var saves = 0
        let refuse: () async throws -> Void = {
            saves += 1
            throw CKError(.permissionFailure)
        }
        await channel.saveSubscriptionIfNeeded(refuse)
        await channel.saveSubscriptionIfNeeded(refuse)
        #expect(saves == 1)

        metadata.lastAccountId = "account-b"
        await channel.saveSubscriptionIfNeeded(refuse)
        #expect(saves == 2)

        channel.forgetSubscription()
        await channel.saveSubscriptionIfNeeded(refuse)
        #expect(saves == 3)
    }
}

@MainActor
private final class RegistrarCalls {
    var registrations = 0
    var unregistrations = 0
}
