import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Database file error classification")
struct DatabaseFileErrorClassifierTests {
    @Test("A database file that is not on this device is a configuration problem with a way out")
    func unavailableFileIsConfiguration() {
        let error = ErrorClassifier.classify(
            LocalDatabaseFileError.unavailable(fileName: "notes.db", reason: .notOnThisDevice),
            context: ErrorContext(operation: "connect", databaseType: .sqlite)
        )

        #expect(error.category == .config)
        #expect(error.title == String(localized: "Database File Unavailable"))
        #expect(error.message == String(format: String(localized: "“%@” isn't available on this device."), "notes.db"))
        #expect(error.recovery == String(localized: "Edit the connection and choose the database file again."))
    }
}
