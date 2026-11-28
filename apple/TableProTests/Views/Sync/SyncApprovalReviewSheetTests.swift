//
//  SyncApprovalReviewSheetTests.swift
//  TableProTests
//

import AppKit
import Combine
import SwiftUI
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct SyncApprovalReviewSheetTests {
    private static func model(_ engine: FakeSyncApprovalEngine) async -> SyncApprovalsModel {
        let model = SyncApprovalsModel(engine: { engine }, changes: Empty().eraseToAnyPublisher(), readCoreWrites: {})
        await model.refresh()
        return model
    }

    @Test("Each record's actions carry an identifier and name the record, and Approve decides that record")
    func actionsNameTheirRecord() async throws {
        let engine = FakeSyncApprovalEngine([SyncApprovalFixture.newConnection(), SyncApprovalFixture.changedConnection()])
        let model = await Self.model(engine)
        let approveID = "sync-approval-approve-\(SyncApprovalFixture.newID)"
        let window = try await HostedAccessibility.host(
            SyncApprovalReviewSheet(model: model, lookup: .none),
            showing: approveID,
            size: NSSize(width: 640, height: 640)
        )
        defer { window.orderOut(nil) }

        let approve = try #require(HostedAccessibility.element(approveID, in: window))
        #expect(HostedAccessibility.label(of: approve) == String(format: String(localized: "Approve %@"), "Orders Production"))
        let reject = try #require(HostedAccessibility.element("sync-approval-reject-\(SyncApprovalFixture.changedID)", in: window))
        #expect(HostedAccessibility.label(of: reject) == String(format: String(localized: "Don't Apply %@"), "Analytics"))
        #expect(HostedAccessibility.element("sync-approvals-approve-all", in: window) != nil)
        #expect(HostedAccessibility.element("sync-approvals-done", in: window) != nil)
        let host = try #require(HostedAccessibility.element("sync-approval-field-\(SyncApprovalFixture.changedID)-/host", in: window))
        let row = SyncApprovalItem.Row(
            id: "/host",
            label: String(localized: "Host"),
            from: .text("analytics.internal"),
            to: .text("analytics.example.net")
        )
        #expect(HostedAccessibility.label(of: host) == SyncApprovalPresentation.spoken(row))

        HostedAccessibility.press(approve)

        try await waitUntil { engine.decided == ["\(SyncApprovalFixture.newID) approve"] }
        try await waitUntil { model.records.count == 1 }
    }

    @Test("What VoiceOver reads of the status is the count of changes waiting, as the row shows it")
    func statusValueIsTheCount() async throws {
        let title = SyncApprovalPresentation.waitingLine(3)
        let pane = Form {
            Section {
                SyncStatusRow(
                    title: title,
                    symbolName: "exclamationmark.circle",
                    isWarning: true,
                    isBusy: false,
                    detail: nil,
                    review: {}
                )
            }
        }
        .formStyle(.grouped)
        let window = try await HostedAccessibility.host(pane, showing: "settings-sync-status")
        defer { window.orderOut(nil) }

        let status = try #require(HostedAccessibility.element("settings-sync-status", in: window))
        #expect(HostedAccessibility.value(of: status) == title)
        let review = try #require(HostedAccessibility.element("settings-sync-review-approvals", in: window))
        #expect(HostedAccessibility.label(of: review) == String(localized: "Review…"))
    }
}
