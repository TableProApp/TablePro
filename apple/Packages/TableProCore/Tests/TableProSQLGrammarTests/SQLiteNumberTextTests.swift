import Foundation
@testable import TableProSQLGrammar
import Testing

struct SQLiteNumberTextTests {
    // Each right-hand side is what `sqlite3` 3.54 printed for `CAST(x AS TEXT)`.
    @Test("A real reads back the way SQLite prints it", arguments: [
        (0.1, "0.1"), (5.5, "5.5"), (7.0, "7.0"), (100_000.0, "100000.0"), (123_456.789, "123456.789"),
        (0.1 + 0.2, "0.30000000000000004"), (0.001, "0.001"), (0.0001, "0.0001"), (0.00001, "1.0e-05"),
        (1.5e-5, "1.5e-05"), (-2.5e-7, "-2.5e-07"), (1e15, "1000000000000000.0"), (1e15 + 0.5, "1000000000000000.5"),
        (2.5e15, "2500000000000000.0"), (1e16, "10000000000000000.0"), (1e17, "1.0e+17"), (9.9e17, "9.9e+17"),
        (123_456_789_012_345_678.0, "1.2345678901234568e+17"), (1e20, "1.0e+20"), (1.23456e20, "1.23456e+20"),
        (1e100, "1.0e+100"), (1.7976931348623157e308, "1.7976931348623157e+308"), (-0.0, "0.0")
    ])
    func realText(real: Double, text: String) {
        #expect(SQLiteNumberText.realText(real) == text)
    }

    @Test("Only SQLite's own text for a number is its stored spelling", arguments: [
        ("5", true), ("-5", true), ("0", true), ("9223372036854775807", true), ("2.5", true), ("7.0", true),
        ("1.0e+20", true), ("1.0e-05", true), ("05", false), ("+5", false), ("-0", false), ("5.50", false),
        ("1e3", false), ("1e20", false), (".5", false), ("5.", false), ("9223372036854775808", false),
        ("inf", false), ("nan", false), ("0x1F", false), ("abc", false), ("", false), (" 5", false)
    ])
    func storedSpelling(text: String, isStored: Bool) {
        #expect(SQLiteNumberText.isStoredSpelling(text) == isStored)
    }
}
