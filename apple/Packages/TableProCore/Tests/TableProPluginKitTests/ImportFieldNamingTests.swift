import TableProPluginKit
import Testing

@Test func namesBlanksAndRepeatsAfterTheLiteralHeaders() {
    let names = ImportFieldNaming.uniqueNames(for: ["id", "id", nil, "id 2", " name "]) { "column \($0 + 1)" }
    #expect(names == ["id", "id 3", "column 3", "id 2", "name"])
}

// A quadratic loop takes over 20 minutes on 200,000 repeats.
@Test(.timeLimit(.minutes(1)))
func aHeaderOfOneRepeatedNameIsNamedInLinearTime() {
    let count = 200_000
    let names = ImportFieldNaming.uniqueNames(for: Array(repeating: "id", count: count)) { "column \($0 + 1)" }
    #expect(names.last == "id \(count)")
    #expect(Set(names).count == count)
}
