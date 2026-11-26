//
//  TeamLibraryHeaderTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct TeamLibraryHeaderTests {
    @Test("The header shows a conflict count button, the edits not uploaded, and a failed sync as a labeled symbol")
    func statusContent() async throws {
        var resolved = 0
        let window = try await HostedAccessibility.host(
            TeamLibrarySyncStatusContent(status: .failed(.offline), conflictCount: 2, resolveConflicts: { resolved += 1 }, notUploadedCount: 3)
                .frame(width: 320, height: 24),
            showing: "team-library-resolve-conflicts"
        )
        defer { window.orderOut(nil) }

        let button = try #require(HostedAccessibility.element("team-library-resolve-conflicts", in: window))
        #expect(HostedAccessibility.label(of: button) == TeamLibrarySyncDescription.conflicts(2))
        let failed = try #require(HostedAccessibility.element("team-library-status-failed", in: window))
        #expect(HostedAccessibility.label(of: failed)?.contains(String(localized: "TablePro couldn't reach the team library.")) == true)
        #expect(HostedAccessibility.element("team-library-not-uploaded", in: window) != nil)

        HostedAccessibility.press(button)
        try await waitUntil { resolved == 1 }
    }

    @Test("A failure that passes says TablePro tries again; one that does not says only what happened")
    func failureDescriptions() {
        let offline = TeamLibrarySyncDescription.failure(.offline)
        #expect(offline.hasPrefix(TeamLibraryPublishing.failureText(.offline)))
        #expect(offline != TeamLibraryPublishing.failureText(.offline))
        #expect(TeamLibrarySyncDescription.failure(.licenseExpired) == TeamLibraryPublishing.failureText(.licenseExpired))
        #expect(TeamLibrarySyncDescription.failure(.deletePending) == TeamLibraryPublishing.failureText(.deletePending))
    }
}
