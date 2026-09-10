//
//  AppSettingsCategoryParityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Guards the shape that let `mcp` and `sync` sit in the dirty set forever.
///
/// A settings category is spelled out in four places: the `markDirty` call in its `didSet`, the
/// seed list that runs when sync is switched on, and the encode and decode switches. A category
/// in the first and missing from the rest is marked dirty, never encodes, never clears, and never
/// reaches the user's other Mac, with nothing reporting a problem.
@Suite("AppSettingsCategory parity")
struct AppSettingsCategoryParityTests {
    private static let managerSource = sourceFile("TablePro/Core/Storage/AppSettingsManager.swift")
    private static let syncSource = sourceFile("TablePro/Core/Sync/SyncCoordinator.swift")

    @Test("Every synced category can be encoded and decoded")
    func syncedCategoriesRoundTrip() throws {
        let source = try #require(Self.syncSource)
        for category in AppSettingsCategory.synced {
            #expect(
                source.contains("case AppSettingsCategory.\(category):"),
                "Category '\(category)' is missing from SyncCoordinator's encode or decode switch"
            )
        }
    }

    @Test("No category is marked dirty by a raw string that bypasses the shared names")
    func noRawCategoryStrings() throws {
        let source = try #require(Self.managerSource)
        #expect(
            !source.contains("markDirty(.settings, id: \""),
            "A settings category is marked dirty by a raw string instead of AppSettingsCategory"
        )
    }

    /// Not syncing these is the documented contract, so they must not be marked dirty at all.
    /// Marking them was the live defect: the flags were set and could never be cleared, because
    /// clearing only happens for a record the server actually saved.
    @Test("Device-local categories are never marked dirty")
    func deviceLocalCategoriesAreNotMarkedDirty() throws {
        let source = try #require(Self.managerSource)
        for category in AppSettingsCategory.deviceLocal {
            #expect(
                !source.contains("markDirty(.settings, id: AppSettingsCategory.\(category))"),
                "Device-local category '\(category)' must not be marked dirty"
            )
        }
        #expect(AppSettingsCategory.deviceLocal.isDisjoint(with: Set(AppSettingsCategory.synced)))
    }

    @Test("Notification settings are among the synced categories")
    func notificationsSync() {
        #expect(AppSettingsCategory.synced.contains(AppSettingsCategory.notifications))
    }

    private static func sourceFile(_ relativePath: String) -> String? {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 8 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent(relativePath)
            if let contents = try? String(contentsOf: candidate, encoding: .utf8) { return contents }
        }
        return nil
    }
}
