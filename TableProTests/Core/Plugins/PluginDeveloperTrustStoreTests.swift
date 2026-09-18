//
//  PluginDeveloperTrustStoreTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("PluginDeveloperTrustStore")
struct PluginDeveloperTrustStoreTests {
    private func makeStore() -> PluginDeveloperTrustStore {
        let suiteName = "com.TablePro.tests.pluginTrust.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create an isolated UserDefaults suite")
        }
        return PluginDeveloperTrustStore(defaults: defaults)
    }

    private let acme = PluginDeveloperIdentity(teamID: "ABCDE12345", name: "Acme Databases")
    private let other = PluginDeveloperIdentity(teamID: "ZZZZZ99999", name: "Someone Else")

    @Test("a developer is untrusted until trusted")
    func untrustedByDefault() {
        let store = makeStore()
        #expect(store.isTrusted(acme) == false)
        store.trust(acme)
        #expect(store.isTrusted(acme))
    }

    @Test("trusting one developer does not trust another")
    func trustIsPerDeveloper() {
        let store = makeStore()
        store.trust(acme)
        #expect(store.isTrusted(other) == false)
    }

    @Test("trust is keyed on the team id, so a display name change keeps it")
    func trustSurvivesRename() {
        let store = makeStore()
        store.trust(acme)
        let renamed = PluginDeveloperIdentity(teamID: acme.teamID, name: "Acme Data Inc")
        #expect(store.isTrusted(renamed))
    }

    @Test("an empty team id can never be trusted")
    func emptyTeamIDRejected() {
        let store = makeStore()
        let anonymous = PluginDeveloperIdentity(teamID: "", name: "No Team")
        store.trust(anonymous)
        #expect(store.isTrusted(anonymous) == false)
        #expect(store.trustedDevelopers().isEmpty)
    }

    @Test("revoking removes the developer and every plugin they signed with it")
    func revoke() {
        let store = makeStore()
        store.trust(acme)
        store.trust(other)
        store.revoke(teamID: acme.teamID)
        #expect(store.isTrusted(acme) == false)
        #expect(store.isTrusted(other))
    }

    @Test("trusting the same developer twice keeps one entry")
    func trustIsIdempotent() {
        let store = makeStore()
        store.trust(acme)
        store.trust(acme)
        #expect(store.trustedDevelopers().count == 1)
    }

    @Test("trusted developers are listed most recent first")
    func listingOrder() {
        let store = makeStore()
        store.trust(acme)
        store.trust(other)
        #expect(store.trustedDevelopers().first?.identity.teamID == other.teamID)
    }
}

@Suite("PluginSignatureTrust")
struct PluginSignatureTrustTests {
    @Test("a first-party bundle needs no consent, a third-party one does")
    func consentRequirement() {
        #expect(PluginSignatureTrust.firstParty.requiresUserConsent == false)
        let identity = PluginDeveloperIdentity(teamID: "ABCDE12345", name: "Acme")
        #expect(PluginSignatureTrust.developerID(identity).requiresUserConsent)
    }
}
