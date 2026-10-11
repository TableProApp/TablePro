//
//  ConsoleRequestFormatterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConsoleRequestFormatterTests {
    private func formatted(_ text: String, for databaseType: DatabaseType = .elasticsearch) throws -> String {
        let formatter = try #require(QueryFormatterFactory.make(for: databaseType))
        return try formatter.format(text, cursorOffset: nil).text
    }

    @Test("A request body is indented and its request line kept", arguments: [
        DatabaseType.elasticsearch, .typesense, .weaviate
    ])
    func bodyIsIndentedUnderItsRequestLine(databaseType: DatabaseType) throws {
        let request = """
        POST /products/_search
        {"query":{"match":{"title":"lamp"}},"size":10}
        """

        #expect(try formatted(request, for: databaseType) == """
        POST /products/_search
        {
          "query": {
            "match": {
              "title": "lamp"
            }
          },
          "size": 10
        }
        """)
    }

    @Test("A request line is a URL, so its wildcard and colons are left alone")
    func requestLineIsVerbatim() throws {
        let request = "GET /_cat/indices/*?v&q=name:lamp"

        #expect(try formatted(request) == request)
    }

    @Test("Requests separated by semicolons are each indented and keep their separator")
    func eachRequestIsIndented() throws {
        let document = """
        GET /a/_search
        {"size":1};

        GET /b/_count
        {"query":{"match_all":{}}}
        """

        #expect(try formatted(document) == """
        GET /a/_search
        {
          "size": 1
        };

        GET /b/_count
        {
          "query": {
            "match_all": {}
          }
        }
        """)
    }

    @Test("A body that is not one JSON value is left as typed")
    func nonJSONBodyIsVerbatim() throws {
        let bulk = """
        POST /_bulk
        {"index":{"_index":"products","_id":"1"}}
        {"title":"lamp"}
        """
        let graphQL = "{ Get { Article(limit: 10) { title } } }"
        let inlineBody = #"POST /objects {"class":"Article","properties":{"title":"lamp"}}"#
        let encodedBrowse = "__TABLEPRO_SEARCH__cHJvZHVjdHM=:0:200:W10=:W10=:QU5E"

        for document in [bulk, graphQL, inlineBody, encodedBrowse] {
            #expect(try formatted(document) == document)
        }
    }

    /// Each line is one record to these endpoints, so indenting a lone document splits it into broken records.
    @Test("A line-delimited body keeps one document per line, even when it holds only one")
    func lineDelimitedBodyIsVerbatim() throws {
        let typesenseImport = """
        POST /collections/books/documents/import?action=upsert
        {"id":"1","title":"lamp"}
        """
        let bulkDelete = """
        POST /_bulk
        {"delete":{"_index":"products","_id":"1"}}
        """

        #expect(try formatted(typesenseImport, for: .typesense) == typesenseImport)
        #expect(try formatted(bulkDelete) == bulkDelete)
    }

    /// Formatting a selection puts the selection's own leading and trailing whitespace back, so the
    /// formatter returning it as well doubled it.
    @Test("The result is trimmed like every other formatter's")
    func resultIsTrimmed() throws {
        let selection = "\nGET /a/_search\n{\"size\":1}\n"
        let result = try formatted(selection)

        #expect(result == "GET /a/_search\n{\n  \"size\": 1\n}")
        #expect(FormatScopeResolver.reapplyBoundaryWhitespace(from: selection, to: result) == "\n" + result + "\n")
    }

    @Test("Only MongoDB is formatted as a shell script")
    func formatterFollowsTheQueryLanguage() {
        #expect(QueryFormatterFactory.make(for: .mongodb) is MongoShellFormatter)
        for databaseType in [DatabaseType.elasticsearch, .typesense, .weaviate] {
            #expect(QueryFormatterFactory.make(for: databaseType) is ConsoleRequestFormatter)
        }
        #expect(QueryFormatterFactory.make(for: .postgresql) is SQLQueryFormatter)
    }

    /// The SQL formatter turned `HSET user:1` into `HSET user :1`, `put /config/name` into
    /// `put / config / name`, and `person:tobie` into `person :tobie`: each a different command.
    @Test("A command line or a plugin's own language is not run through the SQL formatter", arguments: [
        DatabaseType.redis, .etcd, .surrealdb, .kafka
    ])
    func commandLanguagesHaveNoFormatter(databaseType: DatabaseType) {
        #expect(QueryFormatterFactory.make(for: databaseType) == nil)
        #expect(!QueryFormatterFactory.supportsFormatting(databaseType))
    }
}
