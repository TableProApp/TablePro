//
//  CassandraBrowseClassificationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// A table browse reaches the statement gates as text, so MCP and Safe Mode read it before the plugin
/// does. Its window rides in a leading comment, which the classifier skips, and what follows is a SELECT.
struct CassandraBrowseClassificationTests {
    private func browseText(values: [String]) -> String {
        CassandraBrowseRenderer.browse(
            keyspace: "shop", table: "users", columns: [],
            filters: values.map {
                PluginQueryFilter(column: "name", op: "=", value: $0, secondValue: nil, elementScope: nil)
            },
            matchAll: true, sorted: false, limit: 100, offset: 200
        ).text
    }

    @Test("A browse is a read on both engines")
    func browseIsARead() {
        for type in [DatabaseType.cassandra, .scylladb] {
            #expect(QueryClassifier.classify(browseText(values: []), databaseType: type).tier == .safe)
            #expect(!QueryClassifier.isWriteQuery(browseText(values: ["x"]), databaseType: type))
        }
    }

    @Test("A filter value that reads like a write stays a value")
    func writeWordsInAValueStayInTheComment() {
        let text = browseText(values: ["x'; DROP TABLE users; --", "*/ DELETE FROM users /*"])

        #expect(QueryClassifier.classify(text, databaseType: .cassandra).tier == .safe)
        #expect(!QueryClassifier.isDangerousQuery(text, databaseType: .cassandra))
    }
}
