//
//  ManagedPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

private struct StubPolicy: ManagedPolicyReading {
    var managed: Set<String> = []
    var bools: [String: Bool] = [:]
    var strings: [String: String] = [:]

    func isManaged(_ policy: ManagedPolicy) -> Bool { managed.contains(policy.key) }
    func bool(_ policy: ManagedPolicy) -> Bool { bools[policy.key] ?? false }
    func string(_ policy: ManagedPolicy) -> String? { strings[policy.key] }
}

@Suite("ManagedPolicyResolver")
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

@Suite("ManagedPolicyReader")
struct ManagedPolicyReaderTests {
    private func makeReader(_ values: [String: Any]) -> ManagedPolicyReader {
        let suiteName = "com.TablePro.tests.policy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create an isolated UserDefaults suite")
        }
        for (key, value) in values { defaults.set(value, forKey: key) }
        return ManagedPolicyReader(defaults: defaults, applicationID: suiteName)
    }

    @Test("an unset boolean policy reads false rather than nil")
    func unsetBoolIsFalse() {
        let reader = makeReader([:])
        #expect(reader.bool(.mcpServerDisabled) == false)
        #expect(reader.bool(.aiAssistantDisabled) == false)
        #expect(reader.bool(.pluginInstallDisabled) == false)
    }

    @Test("a set policy value is read back")
    func readsSetValues() {
        let reader = makeReader([
            ManagedPolicy.mcpServerDisabled.key: true,
            ManagedPolicy.minimumSafeModeLevel.key: SafeModeLevel.readOnly.rawValue,
        ])
        #expect(reader.bool(.mcpServerDisabled))
        #expect(reader.string(.minimumSafeModeLevel) == SafeModeLevel.readOnly.rawValue)
    }

    @Test("a value set by the user rather than by a profile is not reported as managed")
    func userSetValueIsNotManaged() {
        let reader = makeReader([ManagedPolicy.mcpServerDisabled.key: true])
        #expect(reader.isManaged(.mcpServerDisabled) == false)
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
