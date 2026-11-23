import Foundation
@testable import TablePro
import Testing

private final class CountingKeychain: KeychainStoring, @unchecked Sendable {
    private let stored = InMemoryKeychain()
    private let lock = NSLock()
    private var readCount = 0

    var reads: Int {
        lock.withLock { readCount }
    }

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        stored.writeString(value, forKey: key)
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        lock.withLock { readCount += 1 }
        return stored.readStringResult(forKey: key)
    }

    func delete(forKey key: String) {
        stored.delete(forKey: key)
    }
}

enum LegacySetAsideDigest: CaseIterable, Sendable {
    case absent
    case matching
    case notMatching
}

private struct LegacyLicenseFixture {
    static let machineID = "legacy-license-test-mac"
    static let storedKey = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"
    static let otherKey = "ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ"

    let keychain = CountingKeychain()
    let suite: EphemeralDefaults
    let store: LegacyLicenseStore

    init(payload: Bool, digest: LegacySetAsideDigest) throws {
        suite = try EphemeralDefaults()
        store = LegacyLicenseStore(keychain: keychain, defaults: suite.defaults, machineID: Self.machineID, verify: { $0.data })
        switch digest {
        case .absent:
            break
        case .matching:
            keychain.writeString(Self.storedKey, forKey: LegacyLicenseStore.keychainKey)
            store.setAside()
        case .notMatching:
            keychain.writeString(Self.otherKey, forKey: LegacyLicenseStore.keychainKey)
            store.setAside()
        }
        keychain.writeString(Self.storedKey, forKey: LegacyLicenseStore.keychainKey)
        if payload {
            let data = LicensePayloadData(
                billingCycle: nil,
                licenseKey: Self.storedKey,
                email: "ada@m16.example",
                status: "active",
                expiresAt: nil,
                issuedAt: ISO8601DateFormatter().string(from: Date()),
                tier: "starter",
                machineId: Self.machineID
            )
            let cached = License(
                signedPayload: SignedLicensePayload(data: data, signature: "sig"),
                cachedOnMachineId: Self.machineID
            )
            suite.defaults.set(try JSONEncoder().encode(cached), forKey: LegacyLicenseStore.payloadKey)
        }
    }
}

struct LegacyLicenseStoreTests {
    @Test("isSetAside reads no Keychain item when nothing was set aside")
    func isSetAsideWithoutDigestReadsNoKeychain() throws {
        let fixture = try LegacyLicenseFixture(payload: true, digest: .absent)
        let before = fixture.keychain.reads

        #expect(!fixture.store.isSetAside())
        #expect(fixture.keychain.reads == before)
    }

    @Test("entitlement reads no Keychain item when no payload is stored", arguments: LegacySetAsideDigest.allCases)
    func entitlementWithoutPayloadReadsNoKeychain(digest: LegacySetAsideDigest) throws {
        let fixture = try LegacyLicenseFixture(payload: false, digest: digest)
        let before = fixture.keychain.reads

        #expect(fixture.store.entitlement() == nil)
        #expect(fixture.keychain.reads == before)
    }

    @Test(
        "entitlement and isSetAside answer from the payload and the set-aside digest",
        arguments: [false, true], LegacySetAsideDigest.allCases
    )
    func answersFollowPayloadAndDigest(payload: Bool, digest: LegacySetAsideDigest) throws {
        let fixture = try LegacyLicenseFixture(payload: payload, digest: digest)

        #expect(fixture.store.isSetAside() == (digest == .matching))
        if payload && digest != .matching {
            #expect(fixture.store.entitlement()?.features == LegacyEntitlement.starterFeatures)
        } else {
            #expect(fixture.store.entitlement() == nil)
        }
    }

    @Test("A key set aside reads as set aside and grants nothing")
    func setAsideKeyStaysSetAside() throws {
        let fixture = try LegacyLicenseFixture(payload: true, digest: .absent)
        #expect(fixture.store.entitlement() != nil)

        fixture.store.setAside()

        #expect(fixture.store.isSetAside())
        #expect(fixture.store.entitlement() == nil)
    }
}
