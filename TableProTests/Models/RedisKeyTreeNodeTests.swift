//
//  RedisKeyTreeNodeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
struct RedisKeyTreeBuildTests {
    @Test("Empty keys produces empty tree")
    func emptyKeys() {
        let tree = RedisKeyTreeViewModel.buildTree(keys: [], separator: ":")
        #expect(tree.isEmpty)
    }

    @Test("Single key without separator is a leaf at root")
    func singleKeyNoSeparator() {
        let tree = RedisKeyTreeViewModel.buildTree(keys: [("mykey", "string")], separator: ":")
        #expect(tree.count == 1)
        if case .key(let name, let fullKey, _) = tree[0] {
            #expect(name == "mykey")
            #expect(fullKey == "mykey")
        } else {
            Issue.record("Expected leaf key")
        }
    }

    @Test("Keys with same prefix are grouped under namespace")
    func samePrefix() {
        let keys: [(key: String, type: String?)] = [
            ("user:1", "string"),
            ("user:2", "string"),
            ("user:3", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        #expect(tree.count == 1)
        if case .namespace(let name, _, let children, let count) = tree[0] {
            #expect(name == "user")
            #expect(children.count == 3)
            #expect(count == 3)
        } else {
            Issue.record("Expected namespace")
        }
    }

    @Test("Mixed namespaced and bare keys")
    func mixedKeys() {
        let keys: [(key: String, type: String?)] = [
            ("user:1", "string"),
            ("config", "hash"),
            ("user:2", "string"),
            ("counter", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        // Should have: user (namespace), config (leaf), counter (leaf)
        // Namespaces first, then leafs — both sorted alphabetically
        #expect(tree.count == 3)
        if case .namespace(let name, _, _, _) = tree[0] {
            #expect(name == "user")
        }
        if case .key(let name, _, _) = tree[1] {
            #expect(name == "config")
        }
        if case .key(let name, _, _) = tree[2] {
            #expect(name == "counter")
        }
    }

    @Test("Multi-level nesting")
    func multiLevel() {
        let keys: [(key: String, type: String?)] = [
            ("app:cache:session:1", "string"),
            ("app:cache:session:2", "string"),
            ("app:config", "hash")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        #expect(tree.count == 1)
        if case .namespace(_, _, let appChildren, let count) = tree[0] {
            #expect(count == 3)
            #expect(appChildren.count == 2)
        }
    }

    @Test("Empty separator returns all keys as flat leaves")
    func emptySeparator() {
        let keys: [(key: String, type: String?)] = [
            ("user:1", "string"),
            ("user:2", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: "")

        #expect(tree.count == 2)
        if case .key = tree[0] {} else { Issue.record("Expected leaf") }
    }

    @Test("Custom separator")
    func customSeparator() {
        let keys: [(key: String, type: String?)] = [
            ("user/profile/1", "string"),
            ("user/profile/2", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: "/")

        #expect(tree.count == 1)
        if case .namespace(let name, _, _, _) = tree[0] {
            #expect(name == "user")
        }
    }

    @Test("Key count is recursive")
    func recursiveKeyCount() {
        let keys: [(key: String, type: String?)] = [
            ("a:b:1", "string"),
            ("a:b:2", "string"),
            ("a:c", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        if case .namespace(_, _, _, let count) = tree[0] {
            #expect(count == 3)
        }
    }

    @Test("Consecutive separators create empty-name segments")
    func consecutiveSeparators() {
        let keys: [(key: String, type: String?)] = [
            ("a::b", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        #expect(tree.count == 1)
        if case .namespace(let name, _, _, _) = tree[0] {
            #expect(name == "a")
        }
    }

    @Test("Multi-character separator")
    func multiCharSeparator() {
        let keys: [(key: String, type: String?)] = [
            ("user::1", "string"),
            ("user::2", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: "::")

        #expect(tree.count == 1)
        if case .namespace(let name, _, let children, _) = tree[0] {
            #expect(name == "user")
            #expect(children.count == 2)
        }
    }

    @Test("Preserves key type information")
    func preservesKeyType() {
        let keys: [(key: String, type: String?)] = [
            ("myhash", "hash"),
            ("mylist", "list")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        #expect(tree.count == 2)
        if case .key(_, _, let keyType) = tree[0] {
            #expect(keyType == "hash")
        }
        if case .key(_, _, let keyType) = tree[1] {
            #expect(keyType == "list")
        }
    }

    @Test("A key whose type the server withheld keeps no type")
    func unknownTypeStaysUnknown() {
        let keys: [(key: String, type: String?)] = [
            ("app:1", "STRING"),
            ("other:1", nil)
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: "")

        #expect(tree.count == 2)
        if case .key(_, _, let keyType) = tree[1] {
            #expect(keyType == nil)
        } else {
            Issue.record("Expected leaf key")
        }
    }

    @Test("Deeply nested keys")
    func deeplyNested() {
        let keys: [(key: String, type: String?)] = [
            ("a:b:c:d:e", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        #expect(tree.count == 1)
        if case .namespace(let name, _, let children, let count) = tree[0] {
            #expect(name == "a")
            #expect(count == 1)
            if case .namespace(let name2, _, let children2, _) = children[0] {
                #expect(name2 == "b")
                if case .namespace(let name3, _, _, _) = children2[0] {
                    #expect(name3 == "c")
                }
            }
        }
    }

    @Test("Keys sorted alphabetically within namespace")
    func sortedKeys() {
        let keys: [(key: String, type: String?)] = [
            ("ns:zebra", "string"),
            ("ns:apple", "string"),
            ("ns:mango", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        if case .namespace(_, _, let children, _) = tree[0] {
            let names = children.map(\.displayName)
            #expect(names == ["apple", "mango", "zebra"])
        }
    }

    @Test("Namespaces sorted before leaf keys")
    func namespacesBeforeLeafs() {
        let keys: [(key: String, type: String?)] = [
            ("z-bare-key", "string"),
            ("a-namespace:child", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        #expect(tree.count == 2)
        if case .namespace = tree[0] {} else { Issue.record("Expected namespace first") }
        if case .key = tree[1] {} else { Issue.record("Expected leaf second") }
    }
}

// MARK: - RedisKeyNode Model Tests

struct RedisKeyNodeTests {
    @Test("Namespace id starts with ns:")
    func namespaceId() {
        let node = RedisKeyNode.namespace(name: "user", fullPrefix: "user:", children: [], keyCount: 0)
        #expect(node.id == "ns:user:")
    }

    @Test("Key id starts with key:")
    func keyId() {
        let node = RedisKeyNode.key(name: "1", fullKey: "user:1", keyType: "string")
        #expect(node.id == "key:user:1")
    }

    @Test("DisplayName returns name for both cases")
    func displayName() {
        let ns = RedisKeyNode.namespace(name: "cache", fullPrefix: "cache:", children: [], keyCount: 5)
        let key = RedisKeyNode.key(name: "session", fullKey: "cache:session", keyType: "hash")
        #expect(ns.displayName == "cache")
        #expect(key.displayName == "session")
    }

    @Test("A key of unknown type shows the plain key glyph")
    func unknownTypeIcon() {
        #expect(RedisKeyNode.iconName(forKeyType: nil) == "key")
        #expect(RedisKeyNode.iconName(forKeyType: "HASH") == "square.grid.2x2")
        #expect(RedisKeyNode.iconName(forKeyType: "ReJSON-RL") == "key")
    }

    @Test("Equality based on id only")
    func equalityById() {
        let a = RedisKeyNode.namespace(name: "x", fullPrefix: "x:", children: [], keyCount: 0)
        let b = RedisKeyNode.namespace(name: "x", fullPrefix: "x:", children: [
            .key(name: "1", fullKey: "x:1", keyType: "string")
        ], keyCount: 1)
        #expect(a == b)
    }
}

// MARK: - DisplayNodes Tests

struct RedisKeyTreeDisplayTests {
    @Test("displayNodes returns the whole tree when search is empty")
    func emptySearch() {
        let content = RedisKeyTreeContent(database: "0", separator: ":", keys: [(key: "test", type: "string")])
        let result = content.displayNodes(searchText: "")
        #expect(result.count == 1)
        #expect(result == content.rootNodes)
    }

    @Test("displayNodes filters by search text")
    func searchFilters() {
        let content = RedisKeyTreeContent(
            database: "0",
            separator: ":",
            keys: [(key: "user:1", type: "string"), (key: "session:abc", type: "string")]
        )
        let result = content.displayNodes(searchText: "user")
        #expect(result.count == 1)
        if case .namespace(let name, _, _, _) = result[0] {
            #expect(name == "user")
        }
    }

    @Test("displayNodes returns empty for no match")
    func noMatch() {
        let content = RedisKeyTreeContent(database: "0", separator: ":", keys: [(key: "user:1", type: "string")])
        #expect(content.displayNodes(searchText: "xyz").isEmpty)
    }

    @Test("A load that reaches the key limit is marked truncated, and one below it is not")
    func truncationFollowsTheKeyLimit() {
        let full = (0..<RedisKeyTreeViewModel.maxKeys).map { (key: "k\($0)", type: "string") }
        #expect(RedisKeyTreeContent(database: "0", separator: ":", keys: full).isTruncated)
        #expect(!RedisKeyTreeContent(database: "0", separator: ":", keys: Array(full.dropLast())).isTruncated)
    }

    @Test("A KEYTREE result is read by its Key and Type columns")
    func readsTheKeyTreeResult() {
        let result = QueryResult(
            columns: ["Type", "Key"],
            columnTypes: [],
            rows: [[.text("hash"), .text("user:1")], [.text("string"), .text("counter")]],
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
        let content = RedisKeyTreeContent(result: result, database: "3", separator: ":")
        #expect(content.database == "3")
        #expect(content.keys.map(\.key) == ["user:1", "counter"])
        #expect(content.keys.map(\.type) == ["hash", "string"])
    }
}

// MARK: - Rows

struct RedisKeyTreeRowsTests {
    private let content = RedisKeyTreeContent(
        database: "0",
        separator: ":",
        keys: [(key: "user:1", type: "string"), (key: "counter", type: "string")]
    )

    @Test("Nothing asked for yet lists nothing")
    func idleListsNothing() {
        #expect(RedisKeyTreeRows.rows(for: .idle, searchText: "").isEmpty)
    }

    @Test("A load in flight lists the loading row")
    func loadingListsTheSpinner() {
        #expect(RedisKeyTreeRows.rows(for: .loading, searchText: "") == [.status(.loading)])
    }

    /// A refused `SCAN` used to read as "No items", which says the database is empty when the
    /// server only declined to say.
    @Test("A failed load lists its error, never the empty row, whatever the search")
    func failureListsTheError() {
        let message = "NOPERM User noscan has no permissions to run the 'scan' command"
        #expect(RedisKeyTreeRows.rows(for: .failed(message), searchText: "") == [.status(.error(message))])
        #expect(RedisKeyTreeRows.rows(for: .failed(message), searchText: "user") == [.status(.error(message))])
    }

    @Test("A loaded tree lists its nodes")
    func loadedListsTheNodes() {
        let expected = content.rootNodes.map(RedisKeyTreeRows.Row.node)
        #expect(RedisKeyTreeRows.rows(for: .loaded(content), searchText: "") == expected)
    }

    @Test("A loaded tree that matches nothing lists the empty row")
    func noMatchListsTheEmptyRow() {
        #expect(RedisKeyTreeRows.rows(for: .loaded(content), searchText: "xyz") == [.status(.empty)])
    }

    @Test("A database with no keys lists the empty row")
    func noKeysListsTheEmptyRow() {
        let empty = RedisKeyTreeContent(database: "0", separator: ":", keys: [])
        #expect(RedisKeyTreeRows.rows(for: .loaded(empty), searchText: "") == [.status(.empty)])
    }

    @Test("A truncated tree lists its nodes and then the truncation row")
    func truncatedTreeEndsWithTheTruncationRow() {
        let keys = (0..<RedisKeyTreeViewModel.maxKeys).map { (key: "k\($0)", type: "string") }
        let truncated = RedisKeyTreeContent(database: "0", separator: ":", keys: keys)
        let rows = RedisKeyTreeRows.rows(for: .loaded(truncated), searchText: "")
        #expect(rows.count == truncated.rootNodes.count + 1)
        #expect(rows.last == .status(.truncated(RedisKeyTreeTruncation.message(limit: RedisKeyTreeViewModel.maxKeys))))
    }
}
