//
//  ConsoleRequestDiagnosticsProducerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct ConsoleRequestDiagnosticsProducerTests {
    private let producer = ConsoleRequestDiagnosticsProducer()

    private static let searchRequest = """
        GET /products/_search
        {
          "query": {
            "match": {
              "name": "desk lamp"
            }
          }
        }
        """

    @Test("A search request with a Query DSL body is not flagged")
    func validSearchRequestIsQuiet() {
        #expect(producer.diagnostics(for: Self.searchRequest).isEmpty)
    }

    @Test("A wildcard in the request path is not read as a comment")
    func wildcardPathIsQuiet() {
        #expect(producer.diagnostics(for: "GET /_cat/indices/*?v").isEmpty)
        #expect(producer.diagnostics(for: "\n  get /*/_search\n{\"size\": 0}").isEmpty)
    }

    @Test("A bracket in the query string is not checked")
    func queryStringBracketIsQuiet() {
        #expect(producer.diagnostics(for: "GET /products/_search?q=name:(lamp OR desk))").isEmpty)
    }

    @Test("A body written on the request line is checked")
    func inlineBodyIsChecked() {
        let text = "POST /objects {\"class\": \"Article\"}}"
        #expect(producer.diagnostics(for: text).map(\.range) == [NSRange(location: (text as NSString).length - 1, length: 1)])
        #expect(producer.diagnostics(for: "POST /objects {\"class\": \"Article\"}").isEmpty)
    }

    @Test("A closing bracket in the body with no opener is reported where it was typed")
    func unmatchedCloseInBodyIsReported() {
        let text = "POST /products/_search\n{\"size\": 1}}"
        let results = producer.diagnostics(for: text)
        #expect(results.map(\.range) == [NSRange(location: (text as NSString).length - 1, length: 1)])
        #expect(results.first?.severity == .error)
    }

    @Test("An unterminated comment in the body is reported")
    func unterminatedCommentInBodyIsReported() {
        let results = producer.diagnostics(for: "GET /products/_search\n/* size\n{\"size\": 1}")
        #expect(results.map(\.range) == [NSRange(location: 22, length: 2)])
    }

    @Test("A half-typed body is left alone")
    func partialBodyIsQuiet() {
        #expect(producer.diagnostics(for: "GET /products/_search\n{\"query\": {\"match\": {").isEmpty)
    }

    @Test("A document with no request line, such as a GraphQL query, is checked whole")
    func documentWithoutRequestLineIsCheckedWhole() {
        #expect(producer.diagnostics(for: "{\n  Get {\n    Article { title }\n  }\n}").isEmpty)
        #expect(producer.diagnostics(for: "{ Get { Article { title } } } }").count == 1)
    }
}

@MainActor
struct QueryDiagnosticsFactoryLanguageTests {
    @Test(
        "A console request is checked as a request, not parsed as a MongoDB script",
        arguments: [DatabaseType.elasticsearch, .typesense, .weaviate]
    )
    func consoleRequestIsNotParsedAsJavaScript(type: DatabaseType) {
        let text = "GET /products/_search\n{\n  \"query\": {\n    \"match\": {\"name\": \"desk lamp\"}\n  }\n}"
        #expect(QueryDiagnosticsFactory.make(for: type).diagnostics(for: text).isEmpty)
        #expect(QueryDiagnosticsFactory.make(for: type).diagnostics(for: text + "}").count == 1)
    }

    @Test("A MongoDB script is still parsed as JavaScript")
    func mongoScriptIsStillParsed() {
        #expect(QueryDiagnosticsFactory.make(for: .mongodb).diagnostics(for: "db.orders.find({status: })").count == 1)
    }

    @Test("A bracket in a command's arguments is not flagged", arguments: [DatabaseType.redis, .etcd])
    func commandArgumentsAreQuiet(type: DatabaseType) {
        #expect(QueryDiagnosticsFactory.make(for: type).diagnostics(for: "SET smile :)").isEmpty)
        #expect(QueryDiagnosticsFactory.make(for: type).diagnostics(for: "KEYS cache/*").isEmpty)
    }
}
