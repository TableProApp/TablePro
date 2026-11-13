import CloudKit
import Foundation
import Testing

import TableProSyncTransport

struct SyncPushSubscriptionTests {
    // The shape CloudKit sends for a database subscription, read back by CloudKit's own parser.
    static func payload(
        subscriptionID: String = SyncPushSubscription.id,
        container: String = CloudKitSyncEngine.defaultContainerID
    ) -> [AnyHashable: Any] {
        [
            "aps": ["content-available": 1],
            "ck": [
                "ce": 2,
                "cid": container,
                "nid": UUID().uuidString,
                "met": ["dbs": 1, "sid": subscriptionID]
            ] as [String: Any]
        ]
    }

    @Test("The subscription covers the whole private database and is silent")
    func subscriptionIsSilent() throws {
        let subscription = SyncPushSubscription.make()
        #expect(subscription.subscriptionID == SyncPushSubscription.id)
        #expect(subscription.recordType == nil)
        let info = try #require(subscription.notificationInfo)
        #expect(info.shouldSendContentAvailable)
        #expect(info.alertBody == nil)
        #expect(info.alertLocalizationKey == nil)
        #expect(info.title == nil)
        #expect(info.soundName == nil)
        #expect(!info.shouldBadge)
    }

    @Test("A notice from the subscription announces a change")
    func ownNoticeAnnouncesChange() {
        #expect(SyncPushSubscription.announcesChange(Self.payload()))
    }

    @Test("Another subscription, another container or another kind of push announces nothing")
    func otherPushesAnnounceNothing() {
        #expect(!SyncPushSubscription.announcesChange(Self.payload(subscriptionID: "other")))
        #expect(!SyncPushSubscription.announcesChange(Self.payload(container: "iCloud.com.example")))
        #expect(!SyncPushSubscription.announcesChange(["aps": ["content-available": 1]]))
        #expect(!SyncPushSubscription.announcesChange(["aps": ["alert": "Hello"]]))
        let zoneNotice: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "ck": [
                "ce": 2,
                "cid": CloudKitSyncEngine.defaultContainerID,
                "nid": UUID().uuidString,
                "fet": ["dbs": 1, "sid": SyncPushSubscription.id, "zid": CloudKitSyncEngine.zoneName, "zoid": "_owner"]
            ] as [String: Any]
        ]
        #expect(!SyncPushSubscription.announcesChange(zoneNotice))
    }
}
