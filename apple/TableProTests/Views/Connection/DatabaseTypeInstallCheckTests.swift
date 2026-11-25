//
//  DatabaseTypeInstallCheckTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct DatabaseTypeInstallCheckTests {
    @Test("Only a registry driver that is not installed asks for an install")
    func onlyAMissingRegistryDriverAsks() {
        #expect(DatabaseTypeInstallCheck.requirement(isInstalled: false, isDownloadable: true) == .install)
        #expect(DatabaseTypeInstallCheck.requirement(isInstalled: true, isDownloadable: true) == .ready)
        #expect(DatabaseTypeInstallCheck.requirement(isInstalled: true, isDownloadable: false) == .ready)
    }

    // A download cannot fix a bundled driver that failed to load; the connect attempt says why.
    @Test("A bundled driver that did not load is never offered a download")
    func bundledDriverNeverAsks() {
        #expect(DatabaseTypeInstallCheck.requirement(isInstalled: false, isDownloadable: false) == .ready)
        #expect(DatabaseTypeInstallCheck.requirement(for: .postgresql) == .ready)
    }
}
