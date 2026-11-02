import TableProCoreTypes
import Testing

private func suffixed(_ base: String, _ ordinal: Int) -> String {
    ordinal == 1 ? base : "\(base) (\(ordinal))"
}

@Test func givesEachRepeatTheLowestFreeOrdinal() {
    var names = UniqueNameAllocator(candidate: suffixed)
    let allocated = ["id", "id", "name", "id"].map { names.allocate($0) }
    #expect(allocated == ["id", "id (2)", "name", "id (3)"])
}

@Test func skipsNamesThatAreAlreadyTaken() {
    var names = UniqueNameAllocator(taken: ["id", "id (2)", "id (4)"], candidate: suffixed)
    let first = names.allocate("id")
    let second = names.allocate("id")
    #expect(first == "id (3)")
    #expect(second == "id (5)")
    #expect(names.contains("id (5)"))
}

@Test func aNameReservedLaterIsNeverHandedOut() {
    var names = UniqueNameAllocator(candidate: suffixed)
    let first = names.allocate("a")
    let reserved = names.reserve("a (2)")
    let reservedAgain = names.reserve("a (2)")
    let next = names.allocate("a")
    #expect(first == "a")
    #expect(reserved)
    #expect(!reservedAgain)
    #expect(next == "a (3)")
}

@Test func comparesNamesThroughTheKey() {
    var names = UniqueNameAllocator(taken: ["Orders"], key: { $0.lowercased() }, candidate: suffixed)
    let allocated = names.allocate("orders")
    #expect(allocated == "orders (2)")
}

@Test func aHeaderOfOneRepeatedNameStaysLinear() {
    var keyCalls = 0
    var names = UniqueNameAllocator(
        key: { name in
            keyCalls += 1
            return name
        },
        candidate: suffixed
    )
    let count = 40_000
    var last = ""
    for _ in 0..<count {
        last = names.allocate("id")
    }
    #expect(last == "id (\(count))")
    #expect(keyCalls <= 2 * count)
}
