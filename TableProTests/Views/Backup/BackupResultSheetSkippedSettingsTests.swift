import Foundation
import Testing

@testable import TablePro

@Suite("BackupResultSheet skipped settings note")
struct BackupResultSheetSkippedSettingsTests {
    @Test("No note when nothing was skipped")
    func noSettings() {
        #expect(BackupResultSheet.skippedSettingsNote([]) == nil)
    }

    @Test("One setting is named on its own")
    func oneSetting() {
        let note = BackupResultSheet.skippedSettingsNote(["transaction_timeout"])
        #expect(note?.contains("transaction_timeout") == true)
    }

    @Test("Every setting is named, however many there are")
    func severalSettings() {
        let settings = [
            "lock_timeout", "idle_in_transaction_session_timeout", "transaction_timeout",
            "row_security", "default_table_access_method"
        ]
        let note = BackupResultSheet.skippedSettingsNote(settings)
        for setting in settings {
            #expect(note?.contains(setting) == true)
        }
    }
}
