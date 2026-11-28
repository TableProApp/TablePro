//
//  AccountTeamsPageTests.swift
//  TableProTests
//

import AppKit
import ApplicationServices
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct AccountTeamsPageTests {
    @Test("A team the page loads after it shows is a row VoiceOver reaches, under the drill identifier that opens its keys")
    func teamRowIsReachable() async throws {
        let fixture = try AccountFixture()
        await fixture.server.set {
            $0.memberships = [FakeAccountServer.membership(teamID: "team_e2e", name: "E2E Team", role: "owner", hasSeat: true)]
        }
        try await fixture.signIn()
        let model = AccountSettingsModel(services: fixture.services)
        let window = try await HostedAccessibility.host(
            NavigationStack { AccountTeamsPage(model: model) },
            showing: SettingsPage.accountTeams.pageIdentifier
        )
        defer { window.orderOut(nil) }

        await model.loadProfile()

        let identifier = try #require(SettingsRoute.team(id: "team_e2e", name: "E2E Team").settingsDrillIdentifier)
        #expect(identifier == "settings-drill-team-team_e2e")
        try await waitUntil(timeout: .seconds(3)) {
            guard let page = HostedAccessibility.element(SettingsPage.accountTeams.pageIdentifier, in: window) else { return false }
            return HostedAccessibility.element(identifier, below: page) != nil
        }
        let row = try #require(HostedAccessibility.element(identifier, in: window))
        #expect(HostedAccessibility.label(of: row)?.contains("E2E Team") == true)
        #expect(HostedAccessibility.actions(of: row).contains(kAXPressAction as String))
    }

    @Test("Only a page and a team have a drill identifier")
    func drillIdentifiers() {
        #expect(SettingsRoute.page(.accountTeams).settingsDrillIdentifier == "settings-drill-teams")
        #expect(SettingsRoute.team(id: "t1", name: "One").settingsDrillIdentifier == "settings-drill-team-t1")
        #expect(SettingsRoute.plugin(id: "p").settingsDrillIdentifier == nil)
    }
}
