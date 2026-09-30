//
//  EtcdKeyspaceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct EtcdKeyspaceRootRowTests {
    @Test("The (root) row has no drop or truncate statement", arguments: ["", "/", "/myapp", "/myapp/"])
    func rootRowIsNeverDeletedWhole(keyPrefixRoot: String) {
        let keyspace = EtcdKeyspace(keyPrefixRoot: keyPrefixRoot)

        #expect(keyspace.dropStatement(forTable: EtcdKeyspace.rootTableName) == nil)
        #expect(keyspace.truncateStatements(forTable: EtcdKeyspace.rootTableName) == nil)
    }

    @Test("A table name that resolves to the whole root has no drop or truncate statement")
    func emptyTableNameIsNeverDeletedWhole() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/myapp")

        #expect(keyspace.dropStatement(forTable: "") == nil)
        #expect(keyspace.truncateStatements(forTable: "") == nil)
    }

    @Test("A child prefix drops and truncates only its own keys")
    func childPrefixStatements() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/myapp")

        #expect(keyspace.dropStatement(forTable: "app/") == "del /myapp/app/ --prefix")
        #expect(keyspace.truncateStatements(forTable: "app/") == ["del /myapp/app/ --prefix"])
    }

    @Test("A child prefix under an empty root keeps its own name")
    func childPrefixUnderEmptyRoot() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "")

        #expect(keyspace.dropStatement(forTable: "/services/") == "del /services/ --prefix")
    }

    @Test("A prefix with whitespace is quoted so the command parser reads it back whole")
    func quotedPrefix() throws {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/my app")
        let statement = try #require(keyspace.dropStatement(forTable: "a b/"))

        #expect(statement == "del \"/my app/a b/\" --prefix")
        guard case let .del(key, prefix) = try EtcdCommandParser.parse(statement) else {
            Issue.record("Expected a del operation")
            return
        }
        #expect(key == "/my app/a b/")
        #expect(prefix)
    }
}

struct EtcdKeyspaceRootPrefixTests {
    @Test("A root without a trailing slash is bounded at the slash", arguments: ["/myapp", "/myapp/"])
    func rootIsBoundedAtSlash(keyPrefixRoot: String) {
        let keyspace = EtcdKeyspace(keyPrefixRoot: keyPrefixRoot)

        #expect(keyspace.root == "/myapp/")
        #expect(keyspace.prefix(forTable: EtcdKeyspace.rootTableName) == "/myapp/")
        #expect(keyspace.exportQuery(forTable: EtcdKeyspace.rootTableName) == "get /myapp/ --prefix")
        #expect(keyspace.keysOnlyListing == "get /myapp/ --prefix --keys-only")
    }

    @Test("An empty root and a slash root are kept as they are")
    func emptyAndSlashRoots() {
        #expect(EtcdKeyspace(keyPrefixRoot: "").root == "")
        #expect(EtcdKeyspace(keyPrefixRoot: "/").root == "/")
    }

    @Test("A key added to the (root) row lands under the root, not beside it")
    func insertIntoRootRowStaysUnderRoot() throws {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/myapp")
        let generator = EtcdStatementGenerator(
            prefix: keyspace.prefix(forTable: EtcdKeyspace.rootTableName),
            columns: ["Key", "Value", "Version", "ModRevision", "CreateRevision", "Lease"]
        )
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)

        let writes = try generator.generateRowWrites(
            from: [change],
            insertedRowData: [0: ["feature", "on", nil, nil, nil, nil]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(writes.map(\.statement) == ["put /myapp/feature on"])
    }
}

struct EtcdKeyspaceTableNameTests {
    @Test("Keys group by their first segment under the root")
    func groupsByFirstSegment() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/myapp")

        #expect(keyspace.tableName(forKey: "/myapp/app/config") == "app/")
        #expect(keyspace.tableName(forKey: "/myapp/app/nested/deep") == "app/")
        #expect(keyspace.tableName(forKey: "/myapp/solo") == EtcdKeyspace.rootTableName)
    }

    @Test("Keys under an empty root keep their leading slash in the segment")
    func emptyRootSegments() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "")

        #expect(keyspace.tableName(forKey: "/services/api") == "/services/")
        #expect(keyspace.tableName(forKey: "services/api") == "services/")
        #expect(keyspace.tableName(forKey: "/solo") == EtcdKeyspace.rootTableName)
        #expect(keyspace.tableName(forKey: "solo") == EtcdKeyspace.rootTableName)
    }

    @Test("A key that is only a slash below the root has no segment of its own")
    func slashOnlyKeyIsBare() {
        #expect(EtcdKeyspace(keyPrefixRoot: "").tableName(forKey: "/") == EtcdKeyspace.rootTableName)
        #expect(EtcdKeyspace(keyPrefixRoot: "/myapp").tableName(forKey: "/myapp//") == EtcdKeyspace.rootTableName)
    }
}

struct EtcdKeyspaceTableListTests {
    @Test("A root with no keys lists only an empty (root) row")
    func noKeysListsEmptyRoot() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/myapp")

        #expect(keyspace.tables(forKeys: []) == [EtcdKeyspace.Table(name: EtcdKeyspace.rootTableName, keyCount: 0)])
    }

    @Test("Keys that all sit in a prefix list no (root) row")
    func onlyChildKeysListNoRoot() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/myapp")

        let tables = keyspace.tables(forKeys: ["/myapp/b/1", "/myapp/a/1", "/myapp/a/2"])

        #expect(tables == [
            EtcdKeyspace.Table(name: "a/", keyCount: 2),
            EtcdKeyspace.Table(name: "b/", keyCount: 1)
        ])
    }

    @Test("Bare keys list (root) first with their own count, then the sorted prefixes")
    func bareAndChildKeysListRootFirst() {
        let keyspace = EtcdKeyspace(keyPrefixRoot: "/myapp")

        let tables = keyspace.tables(forKeys: ["/myapp/b/1", "/myapp/solo", "/myapp/a/1", "/myapp//", "/myapp/"])

        #expect(tables == [
            EtcdKeyspace.Table(name: EtcdKeyspace.rootTableName, keyCount: 3),
            EtcdKeyspace.Table(name: "a/", keyCount: 1),
            EtcdKeyspace.Table(name: "b/", keyCount: 1)
        ])
    }
}

struct EtcdKeyspaceDeletionScopeTests {
    private static let keysUnderMyApp = [
        "/myapp/",
        "/myapp//",
        "/myapp//a/1",
        "/myapp///x",
        "/myapp/a/1",
        "/myapp/a/2",
        "/myapp/a/\u{301}",
        "/myapp/ab/1",
        "/myapp/b/1",
        "/myapp/solo"
    ]

    private static let keysUnderEmptyRoot = [
        "/",
        "//x",
        "/a/1",
        "/solo",
        "\u{301}x/1",
        "a/1",
        "ab/1",
        "solo",
        "x/1"
    ]

    @Test("Every row's delete covers exactly the keys that row lists")
    func deleteCoversExactlyTheListedKeys() throws {
        try assertDeletionScopes(keyspace: EtcdKeyspace(keyPrefixRoot: "/myapp"), keys: Self.keysUnderMyApp)
        try assertDeletionScopes(keyspace: EtcdKeyspace(keyPrefixRoot: ""), keys: Self.keysUnderEmptyRoot)
    }

    private func assertDeletionScopes(keyspace: EtcdKeyspace, keys: [String]) throws {
        let tables = Set(keys.map(keyspace.tableName(forKey:)))
        for table in tables {
            guard let statement = keyspace.dropStatement(forTable: table) else {
                #expect(table == EtcdKeyspace.rootTableName)
                continue
            }
            guard case let .del(deletedPrefix, isPrefix) = try EtcdCommandParser.parse(statement) else {
                Issue.record("Row \(table) drops with \(statement), which is not a del")
                continue
            }
            #expect(isPrefix)
            #expect(Array(deletedPrefix.unicodeScalars) == Array(keyspace.prefix(forTable: table).unicodeScalars))
            let deleted = keys.filter { $0.utf8.starts(with: deletedPrefix.utf8) }
            let listed = keys.filter { keyspace.tableName(forKey: $0) == table }
            #expect(deleted == listed, "Row \(table) deletes \(deleted) but lists \(listed)")
        }
    }
}
