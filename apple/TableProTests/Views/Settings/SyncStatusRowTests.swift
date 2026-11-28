//
//  SyncStatusRowTests.swift
//  TableProTests
//

import AppKit
import Combine
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class ServiceStatusSource: ObservableObject {
    @Published var status: SyncServiceStatus

    init(_ status: SyncServiceStatus) {
        self.status = status
    }
}

// The row as the pane hosts it: in a grouped form, following a status that changes under it.
private struct ServiceStatusPane: View {
    @ObservedObject var source: ServiceStatusSource

    var body: some View {
        Form {
            Section {
                SyncStatusRow(
                    title: source.status.title,
                    symbolName: source.status.symbolName,
                    isWarning: source.status.isWarning,
                    isBusy: source.status == .syncing,
                    detail: nil
                )
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
struct SyncStatusRowTests {
    @Test("What VoiceOver reads of the status follows the status on screen through a first upload")
    func valueFollowsTheStatus() async throws {
        let source = ServiceStatusSource(.off)
        let window = try await HostedAccessibility.host(ServiceStatusPane(source: source), showing: "settings-sync-status")
        defer { window.orderOut(nil) }

        #expect(readStatus(in: window) == SyncServiceStatus.off.title)

        for status in [SyncServiceStatus.syncing, .upToDate] {
            source.status = status
            try await waitUntil(timeout: .seconds(3)) { readStatus(in: window) == status.title }
        }
    }

    @Test("What VoiceOver reads of Last Synced follows the time on screen after a later pass")
    func lastSyncedFollowsTheDate() async throws {
        let now = Date()
        let source = LastSyncedSource(now.addingTimeInterval(-7_200))
        let window = try await HostedAccessibility.host(LastSyncedPane(source: source), showing: "settings-sync-last-synced")
        defer { window.orderOut(nil) }
        let first = try #require(readValue("settings-sync-last-synced", in: window))

        source.date = now.addingTimeInterval(-3_600)

        try await waitUntil(timeout: .seconds(3)) {
            guard let value = readValue("settings-sync-last-synced", in: window) else { return false }
            return value != first
        }
    }

    private func readStatus(in window: NSWindow) -> String? {
        readValue("settings-sync-status", in: window)
    }

    private func readValue(_ identifier: String, in window: NSWindow) -> String? {
        HostedAccessibility.element(identifier, in: window).flatMap(HostedAccessibility.value(of:))
    }
}

@MainActor
private final class LastSyncedSource: ObservableObject {
    @Published var date: Date?

    init(_ date: Date?) {
        self.date = date
    }
}

private struct LastSyncedPane: View {
    @ObservedObject var source: LastSyncedSource

    var body: some View {
        Form {
            Section {
                LabeledContent("Last Synced") {
                    SyncLastSyncedText(date: source.date)
                }
            }
        }
        .formStyle(.grouped)
    }
}
