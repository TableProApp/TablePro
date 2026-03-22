//
//  RedisKeyTreeNodeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("RedisKeyTreeViewModel buildTree")
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
        let keys: [(key: String, type: String)] = [
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
        let keys: [(key: String, type: String)] = [
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
        let keys: [(key: String, type: String)] = [
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
        let keys: [(key: String, type: String)] = [
            ("user:1", "string"),
            ("user:2", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: "")

        #expect(tree.count == 2)
        if case .key = tree[0] {} else { Issue.record("Expected leaf") }
    }

    @Test("Custom separator")
    func customSeparator() {
        let keys: [(key: String, type: String)] = [
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
        let keys: [(key: String, type: String)] = [
            ("a:b:1", "string"),
            ("a:b:2", "string"),
            ("a:c", "string")
        ]
        let tree = RedisKeyTreeViewModel.buildTree(keys: keys, separator: ":")

        if case .namespace(_, _, _, let count) = tree[0] {
            #expect(count == 3)
        }
    }
}
