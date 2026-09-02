//
//  AgentIdentityPreferenceTests.swift
//  TableProTests
//
//  A 1Password agent holds one key per server, and `MaxAuthTries` defaults to 6, so the order
//  keys are offered in decides whether the connection works at all (#2601). The order under test
//  is the one `pubkey_prepare()` in OpenSSH documents: certificates from the config, then agent
//  keys the config named, then the rest, and the rest only without `IdentitiesOnly`.
//

import Foundation
import Testing

@testable import TablePro

@Suite("Agent identity preference")
struct AgentIdentityPreferenceTests {
    private static let ed25519 = "ssh-ed25519"
    private static let certificate = "ssh-ed25519-cert-v01@openssh.com"

    private static func agent(_ seeds: [UInt8]) -> [Data] {
        seeds.map { SSHPublicKeyFixture.blob(type: ed25519, seed: $0) }
    }

    private static func preferred(_ seeds: [UInt8]) -> [SSHPublicKeyBlob] {
        seeds.map {
            SSHPublicKeyBlob(keyType: ed25519, blob: SSHPublicKeyFixture.blob(type: ed25519, seed: $0))
        }
    }

    @Test("No identity file leaves the agent's own order in place")
    func noPreferenceOffersEverythingInAgentOrder() {
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: Self.agent([1, 2, 3]),
            preferred: [],
            identitiesOnly: false
        )

        #expect(order == [0, 1, 2])
    }

    @Test("IdentitiesOnly with no identity file still offers everything, rather than nothing")
    func identitiesOnlyWithoutPreferenceDoesNotFilter() {
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: Self.agent([1, 2, 3]),
            preferred: [],
            identitiesOnly: true
        )

        #expect(order == [0, 1, 2])
    }

    @Test("The key an identity file names is offered first, then the rest in agent order")
    func matchedKeyLeadsTheOffer() {
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: Self.agent(Array(1...30)),
            preferred: Self.preferred([20]),
            identitiesOnly: false
        )

        #expect(order.first == 19)
        #expect(order.count == 30)
        #expect(Set(order).count == 30)
    }

    @Test("IdentitiesOnly offers the matched key alone")
    func identitiesOnlyDropsTheRest() {
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: Self.agent(Array(1...30)),
            preferred: Self.preferred([20]),
            identitiesOnly: true
        )

        #expect(order == [19])
    }

    @Test("Several identity files are offered in the order the config lists them")
    func preferredOrderIsConfigOrder() {
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: Self.agent([1, 2, 3, 4]),
            preferred: Self.preferred([4, 2]),
            identitiesOnly: true
        )

        #expect(order == [3, 1])
    }

    @Test("A certificate is offered before a plain key, whatever order the config lists them in")
    func certificatesComeFirst() {
        let plain = SSHPublicKeyBlob(
            keyType: Self.ed25519,
            blob: SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 1)
        )
        let cert = SSHPublicKeyBlob(
            keyType: Self.certificate,
            blob: SSHPublicKeyFixture.blob(type: Self.certificate, seed: 2)
        )

        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: [plain.blob, cert.blob],
            preferred: [plain, cert],
            identitiesOnly: true
        )

        #expect(order == [1, 0])
    }

    @Test("IdentitiesOnly with nothing matching offers nothing, so the caller can say why")
    func identitiesOnlyWithNoMatchOffersNothing() {
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: Self.agent([1, 2, 3]),
            preferred: Self.preferred([99]),
            identitiesOnly: true
        )

        #expect(order.isEmpty)
    }

    @Test("Without IdentitiesOnly, an identity file the agent lacks still offers every agent key")
    func unmatchedPreferenceKeepsEveryKey() {
        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: Self.agent([1, 2, 3]),
            preferred: Self.preferred([99]),
            identitiesOnly: false
        )

        #expect(order == [0, 1, 2])
    }

    @Test("An agent holding the same key twice matches it once per identity file")
    func duplicateAgentEntriesAreNotOfferedTwice() {
        let blob = SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 1)

        let order = AgentIdentityPreference.offerOrder(
            agentIdentities: [blob, blob, SSHPublicKeyFixture.blob(type: Self.ed25519, seed: 2)],
            preferred: Self.preferred([1]),
            identitiesOnly: true
        )

        #expect(order == [0])
    }
}
