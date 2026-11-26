//
//  AccountKeysScreenTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProFFI
import Testing

// Every end-to-end screen drawn in a window in both appearances, each kept as an attachment of the run. Windows are
// never ordered front and never closed.
@MainActor
struct AccountKeysScreenTests {
    enum Screen: String, CaseIterable {
        case pageNoKeys = "page-no-keys"
        case pageNeedsApproval = "page-needs-approval"
        case pageApproved = "page-approved"
        case pageLocked = "page-locked"
        case setUpKey = "setup-key"
        case setUpCheck = "setup-check"
        case setUpDone = "setup-done"
        case replaceCurrentKey = "replace-current-key"
        case replaceDevices = "replace-devices"
        case approvalWaiting = "approval-waiting"
        case approvalWords = "approval-words"
        case approverReview = "approver-review"
        case approvalMismatch = "approval-mismatch"
        case removalKey = "removal-key"
        case removalReview = "removal-review"
        case removalSeats = "removal-seats"
        case recover = "recover"
    }

    private static let words = ["amber", "canyon", "lilac", "orbit", "tundra"]

    @Test("Every key screen draws in light and dark", arguments: Screen.allCases)
    func draws(screen: Screen) async throws {
        let fixture = AccountKeysFixture()
        let view = await Self.view(screen, fixture)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let png = try Self.render(view, page: screen.rawValue.hasPrefix("page"), appearance: appearance)
            #expect(png.count > 1_000, "\(screen.rawValue) drew nothing in \(name)")
            Attachment.record(png, named: "\(screen.rawValue)-\(name).png")
        }
    }

    private static func view(_ screen: Screen, _ fixture: AccountKeysFixture) async -> AnyView {
        let flows = fixture.flows
        let model = fixture.model()
        switch screen {
        case .pageNoKeys:
            await model.reload()
            return AnyView(AccountKeysPage(model: model))
        case .pageNeedsApproval:
            flows.state = .needsApproval(request: nil)
            await model.reload()
            return AnyView(AccountKeysPage(model: model))
        case .pageApproved:
            flows.state = .approved(av: 3, keyDevice: "key-this")
            flows.devices = [
                FakeAccountKeyFlows.device("key-this", row: "row-this", name: "MacBook Air", thisDevice: true),
                FakeAccountKeyFlows.device("key-mini", row: "row-mini", name: "Mac mini", compared: true),
                FakeAccountKeyFlows.device("key-old", name: "Old MacBook Pro"),
            ]
            flows.requests = [FakeAccountKeyFlows.request("request-1", name: "Studio")]
            await model.reload()
            return AnyView(AccountKeysPage(model: model))
        case .pageLocked:
            flows.state = .locked(cause: .leftOutOfRotation)
            await model.reload()
            return AnyView(AccountKeysPage(model: model))
        case .setUpKey, .setUpCheck, .setUpDone:
            let flow = AccountRecoveryKeyFlow(purpose: .setUp) { flows }
            await flow.start()
            if screen != .setUpKey {
                await flow.advance()
            }
            if screen == .setUpDone {
                flow.typed = ["0021", "0077"]
                await flow.advance()
            }
            return sheet(.recoveryKey(flow), model)
        case .replaceCurrentKey, .replaceDevices:
            flows.rotationDevices = [
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-this", name: "MacBook Air", thisDevice: true), keepByDefault: false),
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-mini", name: "Mac mini", compared: true), keepByDefault: true),
                ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-phone", name: "iPhone"), keepByDefault: false),
            ]
            let flow = AccountRecoveryKeyFlow(purpose: .replace) { flows }
            if screen == .replaceDevices {
                flow.currentKey = FakeAccountKeyFlows.recoveryKey
                await flow.advance()
            }
            return sheet(.recoveryKey(flow), model)
        case .approvalWaiting, .approvalWords, .approvalMismatch:
            flows.sessionPhases = [screen == .approvalWaiting ? .open : .compare(words: words)]
            let flow = AccountApprovalFlow(role: .newDevice, flows: { flows }, clock: fixture.clock)
            await flow.start()
            if screen == .approvalMismatch {
                await flow.wordsDiffer()
            }
            return sheet(.approval(flow), model)
        case .approverReview:
            let flow = AccountApprovalFlow(
                role: .approver(FakeAccountKeyFlows.request("request-1", name: "Studio")),
                flows: { flows },
                clock: fixture.clock
            )
            return sheet(.approval(flow), model)
        case .removalKey, .removalReview, .removalSeats:
            flows.review = AccountRemovalReview(
                review: "review-1",
                devices: [
                    ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-this", name: "MacBook Air", thisDevice: true), keepByDefault: false),
                    ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-mini", name: "Mac mini", compared: true), keepByDefault: true),
                    ReviewedDeviceInfo(device: FakeAccountKeyFlows.device("key-old", name: "Old MacBook Pro"), keepByDefault: false),
                ],
                members: [
                    .init(record: ReviewedMemberInfo(team: "team_a", account: "A", confirmedUnderAv: 2), teamID: "TEAM-A", teamName: "Data Platform", name: "Ana Silva", email: "ana@example.com"),
                    .init(record: ReviewedMemberInfo(team: "team_a", account: "B", confirmedUnderAv: 2), teamID: "TEAM-A", teamName: "Data Platform", name: "Bao Tran", email: "bao@example.com"),
                ]
            )
            let flow = AccountRemovalFlow(
                lost: FakeAccountKeyFlows.device("key-old", name: "Old MacBook Pro"),
                flows: { flows },
                portal: { AccountPortal(server: .production) },
                openURL: { _ in }
            )
            if screen != .removalKey {
                flow.recoveryKey = FakeAccountKeyFlows.recoveryKey
                await flow.advance()
            }
            if screen == .removalSeats, let member = flow.review?.members.last {
                flow.setRemoving(member, true)
                await flow.advance()
            }
            return sheet(.removal(flow), model)
        case .recover:
            return sheet(.recover(AccountRecoverFlow { flows }), model)
        }
    }

    private static func sheet(_ sheet: AccountKeysModel.Sheet, _ model: AccountKeysModel) -> AnyView {
        AnyView(AccountKeysSheetContent(sheet: sheet, model: model).background(Color(nsColor: .windowBackgroundColor)))
    }

    private static func render(_ view: AnyView, page: Bool, appearance: NSAppearance.Name) throws -> Data {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: page ? 640 : 520, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer { window.contentView = nil }
        if !page {
            let size = host.fittingSize
            window.setContentSize(NSSize(width: 520, height: min(max(size.height, 160), 640)))
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
