import Foundation
import SwiftUI
import TableProDatabase
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct ShortcutsAppLockTests {
    private static let reportedRow = #"{"iban": "DE00 0000 0000 0000 0000 00", "amount": "9000"}"#

    private let file: URL
    private let ledger: DatabaseConnection
    private let defaults: UserDefaults

    init() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcuts-app-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ledger.db")
        let creator = SQLiteDriver(source: .file(file), openMode: .createNew)
        try await creator.connect()
        _ = try await creator.execute(query: "CREATE TABLE payouts (iban TEXT, amount TEXT)")
        try await creator.disconnect()

        self.file = file
        ledger = DatabaseConnection(name: "Ledger", type: .sqlite, database: file.path)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.ShortcutsAppLock.\(UUID().uuidString)"))
        defaults.set(true, forKey: AppLockState.lockEnabledKey)
    }

    private func payoutCount() async throws -> Int? {
        let reader = SQLiteDriver(source: .file(file))
        try await reader.connect()
        let result = try await reader.execute(query: "SELECT count(*) FROM payouts")
        try await reader.disconnect()
        return (result.rows.first?.first ?? nil).flatMap { Int($0) }
    }

    @Test("the table picker lists nothing while TablePro is locked")
    func tablePickerRefusesWhileLocked() async {
        let auth = StubDeviceOwnerAuthenticator(answer: false)
        let lock = AppLockState(auth: auth, defaults: defaults)
        let ledger = ledger
        let scope = TableListingScope(connectionId: ledger.id, namespace: nil)

        await #expect(throws: AppLockedError.self) {
            try await TableEntityQuery.tables(in: scope, lock: lock, savedConnection: { _ in ledger })
        }
        #expect(auth.requests == 0)
        #expect(lock.isLocked)
    }

    @Test("the database picker lists nothing while TablePro is locked")
    func databasePickerRefusesWhileLocked() async {
        let auth = StubDeviceOwnerAuthenticator(answer: false)
        let lock = AppLockState(auth: auth, defaults: defaults)
        let ledger = ledger

        await #expect(throws: AppLockedError.self) {
            try await DatabaseEntityQuery.namespaces(of: ledger.id, lock: lock, savedConnection: { _ in ledger })
        }
        #expect(auth.requests == 0)
        #expect(lock.isLocked)
    }

    @Test("Add Row writes nothing and asks for no Face ID while TablePro is locked")
    func addRowRefusesWhileLocked() async throws {
        let auth = StubDeviceOwnerAuthenticator(answer: false)
        let lock = AppLockState(auth: auth, defaults: defaults)
        let ledger = ledger
        let rows = try RowPayload.parseJSON(Self.reportedRow)

        await #expect(throws: AppLockedError.self) {
            try await IntentDatabaseSession.with(connection: ledger, lock: lock) {
                try await $0.insertRows(namespace: nil, table: "payouts", rows: rows)
            }
        }
        #expect(try await payoutCount() == 0)
        #expect(auth.requests == 0)
        #expect(lock.isLocked)
    }

    @Test("Add Row past the Auto-Lock time writes nothing, with no scene becoming active")
    func addRowRefusesPastIdleTimeout() async throws {
        let auth = StubDeviceOwnerAuthenticator(answer: true)
        let backgroundedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = backgroundedAt
        let lock = AppLockState(auth: auth, defaults: defaults, now: { clock })
        #expect(await lock.unlock())
        lock.handleScenePhase(.background)
        clock = backgroundedAt.addingTimeInterval(300)
        let ledger = ledger
        let rows = try RowPayload.parseJSON(Self.reportedRow)

        await #expect(throws: AppLockedError.self) {
            try await IntentDatabaseSession.with(connection: ledger, lock: lock) {
                try await $0.insertRows(namespace: nil, table: "payouts", rows: rows)
            }
        }
        #expect(try await payoutCount() == 0)
        #expect(auth.requests == 1)
    }

    @Test("once TablePro is unlocked, the table picker lists payouts")
    func tablePickerListsTablesWhenUnlocked() async throws {
        let lock = AppLockState(auth: StubDeviceOwnerAuthenticator(answer: true), defaults: defaults)
        #expect(await lock.unlock())
        let ledger = ledger

        let tables = try await TableEntityQuery.tables(
            in: TableListingScope(connectionId: ledger.id, namespace: nil),
            lock: lock,
            keychain: MockSecureStore(),
            savedConnection: { _ in ledger }
        )
        let names = tables.map { $0.name }

        #expect(names == ["payouts"])
    }

    @Test("once TablePro is unlocked, Add Row writes the row")
    func addRowWritesWhenUnlocked() async throws {
        let lock = AppLockState(auth: StubDeviceOwnerAuthenticator(answer: true), defaults: defaults)
        #expect(await lock.unlock())
        let rows = try RowPayload.parseJSON(Self.reportedRow)

        let inserted = try await IntentDatabaseSession.with(connection: ledger, lock: lock, keychain: MockSecureStore()) {
            try await $0.insertRows(namespace: nil, table: "payouts", rows: rows)
        }

        #expect(inserted == 1)
        #expect(try await payoutCount() == 1)
    }
}
