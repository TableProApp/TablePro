//
//  ManagedPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

private struct StubPolicy: ManagedPolicyReading {
    var strings: [String: String] = [:]

    func string(_ policy: ManagedPolicy) -> String? { strings[policy.key] }
}

struct ManagedPolicyResolverTests {
    private func policy(floor: String?) -> StubPolicy {
        guard let floor else { return StubPolicy() }
        return StubPolicy(strings: [ManagedPolicy.minimumSafeModeLevel.key: floor])
    }

    @Test("with no policy the connection's own level is used")
    func noPolicy() {
        let level = ManagedPolicyResolver.effectiveSafeModeLevel(
            connectionLevel: .silent,
            policy: policy(floor: nil)
        )
        #expect(level == .silent)
    }

    @Test("a weaker connection is raised to the managed floor")
    func raisesWeakerLevel() {
        let level = ManagedPolicyResolver.effectiveSafeModeLevel(
            connectionLevel: .silent,
            policy: policy(floor: SafeModeLevel.readOnly.rawValue)
        )
        #expect(level == .readOnly)
    }

    @Test("a stricter connection is left alone, so the policy is a floor and not a ceiling")
    func doesNotWeaken() {
        let level = ManagedPolicyResolver.effectiveSafeModeLevel(
            connectionLevel: .readOnly,
            policy: policy(floor: SafeModeLevel.alert.rawValue)
        )
        #expect(level == .readOnly)
    }

    @Test("equal levels stay put")
    func equalLevel() {
        let level = ManagedPolicyResolver.effectiveSafeModeLevel(
            connectionLevel: .safeMode,
            policy: policy(floor: SafeModeLevel.safeMode.rawValue)
        )
        #expect(level == .safeMode)
    }

    @Test("an unrecognised policy value never becomes a floor of its own")
    func unknownValueIsIgnored() {
        let level = ManagedPolicyResolver.effectiveSafeModeLevel(
            connectionLevel: .alert,
            policy: policy(floor: "paranoid")
        )
        #expect(level == .alert)
    }

    @Test("every level is ordered, so no pair collapses to a tie")
    func everyLevelIsOrdered() {
        let ordered: [SafeModeLevel] = [.silent, .alert, .alertFull, .safeMode, .safeModeFull, .readOnly]
        #expect(ordered.count == SafeModeLevel.allCases.count)

        for (index, weaker) in ordered.enumerated() {
            for stronger in ordered[(index + 1)...] {
                let raised = ManagedPolicyResolver.effectiveSafeModeLevel(
                    connectionLevel: weaker,
                    policy: policy(floor: stronger.rawValue)
                )
                #expect(raised == stronger, "\(stronger) should outrank \(weaker)")

                let kept = ManagedPolicyResolver.effectiveSafeModeLevel(
                    connectionLevel: stronger,
                    policy: policy(floor: weaker.rawValue)
                )
                #expect(kept == stronger, "\(weaker) should not weaken \(stronger)")
            }
        }
    }
}

// What a configuration profile delivers: the value, and whether the OS marks it forced.
private struct FakePreferences: ManagedPreferences {
    var forced: [String: Any] = [:]
    var unforced: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { forced[defaultName] ?? unforced[defaultName] }
    func objectIsForced(forKey key: String) -> Bool { forced[key] != nil }
}

struct ManagedPolicyReaderTests {
    @Test("an unset policy reads nil")
    func unsetPolicyIsNil() {
        let reader = ManagedPolicyReader(preferences: FakePreferences())
        #expect(reader.string(.minimumSafeModeLevel) == nil)
        #expect(reader.string(.accountServerURL) == nil)
        #expect(reader.bool(.allowOtherAccountServers) == nil)
    }

    @Test("a forced value is read back")
    func readsForcedValues() {
        let reader = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.minimumSafeModeLevel.key: SafeModeLevel.readOnly.rawValue,
            ManagedPolicy.accountServerURL.key: "https://api.example.com",
            ManagedPolicy.allowOtherAccountServers.key: false
        ]))
        #expect(reader.string(.minimumSafeModeLevel) == SafeModeLevel.readOnly.rawValue)
        #expect(reader.string(.accountServerURL) == "https://api.example.com")
        #expect(reader.bool(.allowOtherAccountServers) == false)
    }

    @Test("a value written to the same key without a profile is not policy")
    func unforcedValueIsIgnored() {
        let reader = ManagedPolicyReader(preferences: FakePreferences(unforced: [
            ManagedPolicy.minimumSafeModeLevel.key: SafeModeLevel.readOnly.rawValue,
            ManagedPolicy.accountServerURL.key: "https://api.example.com",
            ManagedPolicy.allowOtherAccountServers.key: false
        ]))
        #expect(reader.string(.minimumSafeModeLevel) == nil)
        #expect(reader.string(.accountServerURL) == nil)
        #expect(reader.bool(.allowOtherAccountServers) == nil)
    }

    @Test("a value set in a defaults suite is not forced")
    func userDefaultsValueIsNotForced() throws {
        let suite = try EphemeralDefaults()
        suite.defaults.set(SafeModeLevel.readOnly.rawValue, forKey: ManagedPolicy.minimumSafeModeLevel.key)
        let reader = ManagedPolicyReader(preferences: suite.defaults)
        #expect(reader.string(.minimumSafeModeLevel) == nil)
    }

    @Test("a forced value of the wrong type reads nil")
    func wrongTypeIsIgnored() {
        let reader = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.accountServerURL.key: 42,
            ManagedPolicy.allowOtherAccountServers.key: "false",
            ManagedPolicy.usageDataAllowed.key: "NO",
            ManagedPolicy.iCloudSyncAllowed.key: NSNumber(value: 0)
        ]))
        #expect(reader.string(.accountServerURL) == nil)
        #expect(reader.bool(.allowOtherAccountServers) == nil)
        #expect(reader.bool(.usageDataAllowed) == nil)
        #expect(reader.bool(.iCloudSyncAllowed) == nil)
    }

    @Test("a number is not a boolean policy")
    func numberIsNotBoolean() {
        let reader = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.allowOtherAccountServers.key: NSNumber(value: 0)
        ]))
        #expect(reader.bool(.allowOtherAccountServers) == nil)
    }

    @Test("the keys a profile forces read as one set, and a person's own values for them are not policy")
    func snapshotReadsOnlyForcedValues() {
        let values: [String: Any] = [
            ManagedPolicy.accountServerURL.key: "https://tablepro.corp.example",
            ManagedPolicy.allowOtherAccountServers.key: false,
            ManagedPolicy.personalSyncProvider.key: ["tablepro-sync", "off"],
            ManagedPolicy.usageDataAllowed.key: false,
            ManagedPolicy.pluginCatalogAllowed.key: false,
            ManagedPolicy.iCloudSyncAllowed.key: false
        ]

        let forced = ManagedPolicySnapshot(reading: ManagedPolicyReader(preferences: FakePreferences(forced: values)))
        let written = ManagedPolicySnapshot(reading: ManagedPolicyReader(preferences: FakePreferences(unforced: values)))

        #expect(forced == ManagedPolicySnapshot(
            accountServerURL: "https://tablepro.corp.example",
            allowOtherAccountServers: false,
            personalSyncProvider: ["tablepro-sync", "off"],
            usageDataAllowed: false,
            pluginCatalogAllowed: false,
            iCloudSyncAllowed: false
        ))
        #expect(!forced.allowsUsageData && !forced.allowsPluginCatalog && !forced.allowsICloudSync)
        #expect(written == ManagedPolicySnapshot())
        #expect(written.allowsUsageData && written.allowsPluginCatalog && written.allowsICloudSync)
    }

    @Test("a list keeps its strings and skips any other entry; a list key of another type reads nil")
    func listEntriesThatAreNotStringsAreSkipped() {
        let mixed = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.personalSyncProvider.key: ["icloud", 7, "off"] as [Any]
        ]))
        let single = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.personalSyncProvider.key: "icloud"
        ]))
        let empty = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.personalSyncProvider.key: [String]()
        ]))

        #expect(mixed.strings(.personalSyncProvider) == ["icloud", "off"])
        #expect(single.strings(.personalSyncProvider) == nil)
        #expect(empty.strings(.personalSyncProvider) == [])
    }

    @Test("a Safe Mode floor of another type or an unknown level sets no floor")
    func safeModeFloorOfAnotherTypeIsNoFloor() {
        let number = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.minimumSafeModeLevel.key: 2
        ]))
        let unknown = ManagedPolicyReader(preferences: FakePreferences(forced: [
            ManagedPolicy.minimumSafeModeLevel.key: "paranoid"
        ]))

        #expect(ManagedPolicyResolver.minimumSafeModeLevel(policy: number) == nil)
        #expect(ManagedPolicyResolver.minimumSafeModeLevel(policy: unknown) == nil)
        #expect(ManagedPolicyResolver.effectiveSafeModeLevel(connectionLevel: .silent, policy: number) == .silent)
    }

    @Test("policy keys are distinct and namespaced apart from the settings blobs")
    func keysAreDistinct() {
        let keys = ManagedPolicy.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
        for key in keys {
            #expect(key.hasPrefix("com.TablePro.policy."))
        }
    }
}
