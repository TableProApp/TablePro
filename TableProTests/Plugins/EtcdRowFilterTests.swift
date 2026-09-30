//
//  EtcdRowFilterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct EtcdRowFilterTests {
    private func row(
        _ key: String,
        value: String? = "v",
        version: String = "1",
        modRevision: String = "1",
        createRevision: String = "1",
        lease: String = "0"
    ) -> EtcdFilterRow {
        EtcdFilterRow(
            key: key, value: value, version: version,
            modRevision: modRevision, createRevision: createRevision, lease: lease
        )
    }

    private func keep(
        _ rows: [EtcdFilterRow],
        _ filters: [PluginQueryFilter],
        logicMode: String = "and"
    ) throws -> [String] {
        let matcher = try EtcdRowFilter(filters: filters, logicMode: logicMode).matcher()
        return rows.filter(matcher.matches).map(\.key)
    }

    private func refusal(_ filters: [PluginQueryFilter]) -> String? {
        do {
            _ = try EtcdRowFilter(filters: filters, logicMode: "and")
            return nil
        } catch {
            return (error as? EtcdFilterRefusal)?.pluginErrorMessage
        }
    }

    @Test("Key NOT CONTAINS drops the keys that contain the text")
    func keyNotContains() throws {
        let kept = try keep(
            [row("/app/x1"), row("/app/y1")],
            [PluginQueryFilter(column: "Key", op: "NOT CONTAINS", value: "x")]
        )
        #expect(kept == ["/app/y1"])
    }

    @Test("A Key filter tests the key alone, never the value", arguments: ["CONTAINS", "STARTS WITH"])
    func keyFilterIgnoresValue(op: String) throws {
        let kept = try keep(
            [row("/a", value: "/zzz"), row("/zzz", value: "a")],
            [PluginQueryFilter(column: "Key", op: op, value: "/z")]
        )
        #expect(kept == ["/zzz"])
    }

    @Test("Two Key filters in OR mode keep a key matching either")
    func keyFiltersInOrMode() throws {
        let kept = try keep(
            [row("/a"), row("/b"), row("/c")],
            [
                PluginQueryFilter(column: "Key", op: "=", value: "/a"),
                PluginQueryFilter(column: "Key", op: "=", value: "/c"),
            ],
            logicMode: "or"
        )
        #expect(kept == ["/a", "/c"])
    }

    @Test("Two filters in AND mode keep only a key matching both")
    func filtersInAndMode() throws {
        let kept = try keep(
            [row("/a/1", value: "on"), row("/a/2", value: "off"), row("/b/1", value: "on")],
            [
                PluginQueryFilter(column: "Key", op: "STARTS WITH", value: "/a/"),
                PluginQueryFilter(column: "Value", op: "=", value: "on"),
            ]
        )
        #expect(kept == ["/a/1"])
    }

    @Test("A Value filter reads the value")
    func valueContains() throws {
        let kept = try keep(
            [row("/a", value: "enabled=true"), row("/b", value: "enabled=false")],
            [PluginQueryFilter(column: "Value", op: "CONTAINS", value: "TRUE", isCaseSensitive: false)]
        )
        #expect(kept == ["/a"])
    }

    @Test("Version compares as a number, not as text")
    func versionIsNumeric() throws {
        let kept = try keep(
            [row("/a", version: "9"), row("/b", version: "10")],
            [PluginQueryFilter(column: "Version", op: ">", value: "9")]
        )
        #expect(kept == ["/b"])
    }

    @Test("BETWEEN on ModRevision includes both bounds")
    func modRevisionBetween() throws {
        let rows = [row("/a", modRevision: "4"), row("/b", modRevision: "5"), row("/c", modRevision: "7"),
                    row("/d", modRevision: "8")]
        let kept = try keep(
            rows,
            [PluginQueryFilter(
                column: "ModRevision", op: "BETWEEN", value: "5,7", secondValue: "7", elementScope: nil
            )]
        )
        #expect(kept == ["/b", "/c"])
    }

    @Test("A Lease filter matches the lease however its id is written", arguments: ["0x7b", "7b", "123"])
    func leaseEquals(written: String) throws {
        let kept = try keep(
            [row("/leased", lease: "123"), row("/other", lease: "124"), row("/none")],
            [PluginQueryFilter(column: "Lease", op: "=", value: written)]
        )
        #expect(kept == ["/leased"])
    }

    @Test("Lease = 0 keeps the keys that have no lease")
    func leaseZeroMeansNone() throws {
        let kept = try keep(
            [row("/leased", lease: "123"), row("/none")],
            [PluginQueryFilter(column: "Lease", op: "=", value: "0")]
        )
        #expect(kept == ["/none"])
    }

    @Test("IS NULL keeps a key whose empty value etcd left out")
    func valueIsNull() throws {
        let kept = try keep(
            [row("/empty", value: nil), row("/full", value: "x")],
            [PluginQueryFilter(column: "Value", op: "IS NULL", value: "")]
        )
        #expect(kept == ["/empty"])
    }

    @Test("IN and NOT IN read a comma-separated list")
    func inAndNotIn() throws {
        let rows = [row("/a"), row("/b"), row("/c")]
        #expect(try keep(rows, [PluginQueryFilter(column: "Key", op: "IN", value: "/a, /c")]) == ["/a", "/c"])
        #expect(try keep(rows, [PluginQueryFilter(column: "Key", op: "NOT IN", value: "/a, /c")]) == ["/b"])
    }

    @Test("REGEX matches the key, ignoring case when asked")
    func keyRegex() throws {
        let kept = try keep(
            [row("/Service/1"), row("/service/22"), row("/other/1")],
            [PluginQueryFilter(column: "Key", op: "REGEX", value: "^/service/[0-9]$", isCaseSensitive: false)]
        )
        #expect(kept == ["/Service/1"])
    }

    @Test("Ordering on Key follows etcd's byte order")
    func keyOrderingIsByteOrder() throws {
        let kept = try keep(
            [row("/B"), row("/a"), row("/b")],
            [PluginQueryFilter(column: "Key", op: ">=", value: "/a")]
        )
        #expect(kept == ["/a", "/b"])
    }

    @Test("An empty filter keeps every key")
    func noFilterKeepsAll() throws {
        #expect(try keep([row("/a"), row("/b")], []) == ["/a", "/b"])
        #expect(EtcdRowFilter.unfiltered.isUnfiltered)
    }

    @Test("A filter etcd cannot evaluate is refused rather than dropped")
    func refusals() {
        #expect(refusal([PluginQueryFilter(column: "__RAW__", op: "=", value: "a = 1")])
            == "etcd cannot filter with a raw SQL condition.")
        #expect(refusal([PluginQueryFilter(column: "Owner", op: "=", value: "x")]) == "etcd has no Owner column.")
        #expect(refusal([PluginQueryFilter(column: "Key", op: "SOUNDS LIKE", value: "x")])
            == "etcd cannot filter with SOUNDS LIKE.")
        #expect(refusal([PluginQueryFilter(column: "Version", op: ">", value: "ten")])
            == "Version can only be compared with a whole number.")
        #expect(refusal([PluginQueryFilter(column: "Lease", op: "=", value: "lease")])
            == "Lease can only be compared with a lease ID, such as 0x7b.")
        #expect(refusal([PluginQueryFilter(column: "Key", op: "REGEX", value: "(")])
            == "'(' is not a valid regular expression.")
        #expect(refusal([PluginQueryFilter(column: "Key", op: "IN", value: " , ")])
            == "Enter at least one value to filter with IN.")
        #expect(refusal([PluginQueryFilter(column: "Version", op: "BETWEEN", value: "1")])
            == "Enter both bounds to filter with BETWEEN.")
    }
}
