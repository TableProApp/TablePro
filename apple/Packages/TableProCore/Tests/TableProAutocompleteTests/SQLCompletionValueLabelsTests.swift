import TableProAutocomplete
import Testing

struct SQLCompletionValueLabelsTests {
    @Test("a scalar enum column offers its labels")
    func scalarColumn() {
        #expect(SQLCompletionValueLabels.values(["new", "paid"], ofColumnType: "ENUM") == ["new", "paid"])
        #expect(SQLCompletionValueLabels.values(["a"], ofColumnType: "Enum8('a' = 1)") == ["a"])
    }

    @Test("a list column's element labels are not its values", arguments: ["ENUM[]", "ENUM('a', 'b')[]", "ENUM('a')[2]"])
    func listColumn(typeName: String) {
        #expect(SQLCompletionValueLabels.values(["a", "b"], ofColumnType: typeName) == nil)
    }

    @Test("no labels offer nothing")
    func noLabels() {
        #expect(SQLCompletionValueLabels.values(nil, ofColumnType: "ENUM") == nil)
        #expect(SQLCompletionValueLabels.values([], ofColumnType: "ENUM") == nil)
    }
}
