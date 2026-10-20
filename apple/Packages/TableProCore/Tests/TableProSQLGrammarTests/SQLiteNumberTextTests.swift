import Foundation
import TableProSQLGrammar
import Testing

struct SQLiteNumberTextTests {
    // Each `true` text is what `sqlite3` 3.54 printed for `CAST(x AS TEXT)` of some number.
    @Test("SQLite's own text for a number is its stored spelling", arguments: [
        "5", "-5", "0", "9223372036854775807", "-9223372036854775808",
        "0.1", "2.5", "7.0", "0.0", "100000.0", "0.0001", "0.30000000000000004", "0.33333333333333332",
        "3.1415926535897931", "1000000000000000.5", "10000000000000000.0", "1.0e+17", "1.2345678901234568e+17",
        "1.0e-05", "-2.5e-07", "1.0e+100", "1.7976931348623157e+308"
    ])
    func storedSpelling(text: String) {
        #expect(SQLiteNumberText.isStoredSpelling(text))
    }

    @Test("Any other spelling of a number stays text", arguments: [
        "05", "+5", "-0", "5.50", "05.5", "5.", ".5", "1e3", "1e20", "1E+20", "1.0e+05", "1.0e+16", "0.00001",
        "1.0e5", "-0.0", "0.00", "9223372036854775808", "0.123456789012345678",
        "inf", "nan", "0x1F", "abc", "", " 5", "5 "
    ])
    func otherSpelling(text: String) {
        #expect(!SQLiteNumberText.isStoredSpelling(text))
    }
}
