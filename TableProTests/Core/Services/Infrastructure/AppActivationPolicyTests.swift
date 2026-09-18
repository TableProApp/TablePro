//
//  AppActivationPolicyTests.swift
//  TableProTests
//
//  The MCP bridge launches TablePro to answer a client, and that launch opens no window. The app
//  used to take a Dock icon and an app-switcher entry for it anyway, which is a process claiming to
//  be something the person never started.
//

import Foundation
@testable import TablePro
import Testing

@Suite("App activation policy")
struct AppActivationPolicyTests {
    @Test("The bridge's launch flag makes the session a machine's")
    func launchFlagResolvesOrigin() {
        #expect(
            AppActivationPolicyDecision.launchOrigin(
                for: [BackgroundLaunchFlag.variable: BackgroundLaunchFlag.value]
            ) == .machine
        )
        #expect(AppActivationPolicyDecision.launchOrigin(for: [:]) == .user)
        #expect(AppActivationPolicyDecision.launchOrigin(for: [BackgroundLaunchFlag.variable: "0"]) == .user)
        #expect(AppActivationPolicyDecision.launchOrigin(for: [BackgroundLaunchFlag.variable: ""]) == .user)
    }

    @Test("Starting the MCP server is the one intent that puts nothing on screen")
    func onlyTheServerIntentIsHeadless() {
        #expect(!LaunchIntent.startMCPServer.impliesUserInterface)
        #expect(LaunchIntent.openConnection(UUID()).impliesUserInterface)
        #expect(LaunchIntent.openQuery(connectionId: UUID(), sql: "SELECT 1").impliesUserInterface)
        #expect(LaunchIntent.openSQLFile(URL(fileURLWithPath: "/tmp/q.sql")).impliesUserInterface)
        #expect(LaunchIntent.openInspectorFile(URL(fileURLWithPath: "/tmp/rows.csv")).impliesUserInterface)
        #expect(LaunchIntent.openConnectionShare(URL(string: "tablepro://share")!).impliesUserInterface)
        #expect(LaunchIntent.installPlugin(URL(string: "tablepro://plugin")!).impliesUserInterface)
        #expect(
            LaunchIntent.openTable(
                connectionId: UUID(), database: nil, schema: nil, table: "users", isView: false
            ).impliesUserInterface
        )
    }

    @Test("A launch whose only reason is the server is a machine's launch, flag or no flag")
    func headlessLaunchWithoutTheFlag() {
        #expect(
            AppActivationPolicyDecision.origin(
                adopting: [.startMCPServer], current: .user, isLaunching: true
            ) == .machine
        )
    }

    @Test("The same URL arriving at a running app leaves the origin alone")
    func aRunningAppKeepsItsOrigin() {
        #expect(
            AppActivationPolicyDecision.origin(
                adopting: [.startMCPServer], current: .user, isLaunching: false
            ) == .user
        )
        #expect(
            AppActivationPolicyDecision.origin(
                adopting: [.startMCPServer], current: .machine, isLaunching: false
            ) == .machine
        )
    }

    @Test("A plain launch with nothing to route stays the person's own")
    func plainLaunchStaysUser() {
        #expect(
            AppActivationPolicyDecision.origin(adopting: [], current: .user, isLaunching: true) == .user
        )
    }

    @Test("Anything that puts a window on screen hands the session to the person for good")
    func userInterfaceIntentClaimsTheSession() {
        #expect(
            AppActivationPolicyDecision.origin(
                adopting: [.startMCPServer, .openConnection(UUID())], current: .machine, isLaunching: true
            ) == .user
        )
        #expect(
            AppActivationPolicyDecision.origin(
                adopting: [.openConnection(UUID())], current: .machine, isLaunching: false
            ) == .user
        )
    }

    @Test("A machine session is in the Dock exactly while it has a window to show")
    func machineSessionFollowsItsWindows() {
        #expect(
            AppActivationPolicyDecision.role(origin: .machine, hasUserFacingWindow: false) == .background
        )
        #expect(
            AppActivationPolicyDecision.role(origin: .machine, hasUserFacingWindow: true) == .foreground
        )
    }

    @Test("A session the person launched is never sent to the background")
    func userSessionIsNeverDemoted() {
        #expect(AppActivationPolicyDecision.role(origin: .user, hasUserFacingWindow: true) == .foreground)
        #expect(AppActivationPolicyDecision.role(origin: .user, hasUserFacingWindow: false) == .foreground)
    }

    @Test("Closing the last window of a machine session opens nothing")
    func machineSessionDoesNotPresentWelcome() {
        #expect(
            !WelcomeVisibilityPolicy.shouldPresentWelcome(
                closingWindowWasPrimary: true,
                remainingVisiblePrimaryWindows: 0,
                sessionOrigin: .machine
            )
        )
        #expect(
            WelcomeVisibilityPolicy.shouldPresentWelcome(
                closingWindowWasPrimary: true,
                remainingVisiblePrimaryWindows: 0,
                sessionOrigin: .user
            )
        )
    }
}
