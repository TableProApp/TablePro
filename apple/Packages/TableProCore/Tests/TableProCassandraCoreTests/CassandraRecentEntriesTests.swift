//
//  CassandraRecentEntriesTests.swift
//  TableProCassandraCoreTests
//

import TableProCassandraCore
import Testing

struct CassandraRecentEntriesTests {
    @Test("Past the capacity the entries written longest ago are dropped first")
    func dropsOldestPastCapacity() {
        var entries = CassandraRecentEntries<Int, String>(capacity: 4)
        for key in 1...5 {
            entries.set("v\(key)", for: key)
        }
        #expect(entries.count <= 4)
        #expect(entries[1] == nil)
        #expect(entries[2] == nil)
        #expect(entries[3] == "v3")
        #expect(entries[5] == "v5")

        for key in 6...100 {
            entries.set("v\(key)", for: key)
            #expect(entries.count <= 4)
        }
        #expect(entries[100] == "v100")
        #expect(entries[99] == "v99")
    }

    @Test("Writing a key again replaces its value and keeps it among the newest")
    func rewriteRefreshes() {
        var entries = CassandraRecentEntries<String, Int>(capacity: 4)
        entries.set(1, for: "a")
        entries.set(2, for: "b")
        entries.set(3, for: "c")
        entries.set(10, for: "a")
        entries.set(4, for: "d")
        #expect(entries["a"] == 10)
        #expect(entries["b"] == nil)
        #expect(entries["c"] == 3)
        #expect(entries["d"] == 4)
        #expect(entries.count == 3)
        entries.removeValue(for: "a")
        #expect(entries["a"] == nil)
        entries.removeAll()
        #expect(entries["c"] == nil)
        #expect(entries["d"] == nil)
    }
}
