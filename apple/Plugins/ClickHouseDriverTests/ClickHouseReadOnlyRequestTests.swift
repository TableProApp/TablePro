//
//  ClickHouseReadOnlyRequestTests.swift
//  ClickHouseDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct ClickHouseReadOnlyRequestTests {
    private static let server258 = ClickHouseServerProfile.testing(
        version: "25.8.33.6",
        writableSettings: Set(ClickHouseURLSetting.allCases)
    )

    private static var externalRead: PluginStatementContext {
        var context = PluginStatementContext()
        context.readOnly = true
        context.origin = .external
        context.allowsServerCode = false
        return context
    }

    private static func items(
        _ shape: ClickHouseResponseShape,
        _ profile: ClickHouseServerProfile,
        readOnly: Bool
    ) -> [URLQueryItem] {
        ClickHousePluginDriver.queryItems(
            database: "default",
            queryId: "q1",
            executionTimeLimit: 30,
            shape: shape,
            profile: profile,
            statementBytes: 300_000,
            readOnly: readOnly
        )
    }

    @Test(
        "A read-only request ends with exactly one readonly=1, on every shape",
        arguments: [ClickHouseResponseShape.buffered(parameters: ["p1": "a"]), .streamed(rowCap: 100), .streamed(rowCap: nil)]
    )
    func readOnlyGoesLastOnce(shape: ClickHouseResponseShape) {
        for profile in [Self.server258, .bootstrap] {
            let items = Self.items(shape, profile, readOnly: true)
            #expect(items.last == URLQueryItem(name: "readonly", value: "1"))
            #expect(items.filter { $0.name == "readonly" }.count == 1)
            #expect(Array(items.dropLast()) == Self.items(shape, profile, readOnly: false))
        }
    }

    @Test("Any other readonly item is dropped, so the last value the server applies is 1")
    func otherReadonlyIsReplaced() {
        let items = [
            URLQueryItem(name: "database", value: "default"),
            URLQueryItem(name: "readonly", value: "0"),
            URLQueryItem(name: "default_format", value: "TabSeparatedWithNamesAndTypes"),
            URLQueryItem(name: "readonly", value: "2"),
        ]
        let guarded = ClickHousePluginDriver.readOnlyItems(items, profile: Self.server258)
        #expect(guarded == [
            URLQueryItem(name: "database", value: "default"),
            URLQueryItem(name: "default_format", value: "TabSeparatedWithNamesAndTypes"),
            URLQueryItem(name: "readonly", value: "1"),
        ])
    }

    @Test("The default context sends no readonly item")
    func defaultSendsNoReadonly() {
        for shape in [ClickHouseResponseShape.buffered(parameters: nil), .streamed(rowCap: 10)] {
            #expect(!Self.items(shape, Self.server258, readOnly: false).contains { $0.name == "readonly" })
        }
    }

    @Test("A login at readonly=2, which may not change readonly, keeps its own level; one at 1 is asked for 1")
    func loginLevelDecides() {
        let columns = ClickHouseSettingsRows.columns20
        func profile(readonly: String) -> ClickHouseServerProfile {
            let row: [PluginCellValue] = [.text("readonly"), .text(readonly), .text("1"), .text(""), .null, .null, .text("1")]
            return ClickHouseServerProfile(versionText: "26.8.36.3", settings: (columns, [row]), catalogRow: nil)
        }
        #expect(profile(readonly: "2").loginReadOnly == 2)
        #expect(!Self.items(.buffered(parameters: nil), profile(readonly: "2"), readOnly: true).contains { $0.name == "readonly" })
        #expect(Self.items(.buffered(parameters: nil), profile(readonly: "1"), readOnly: true).last?.value == "1")
        #expect(Self.items(.buffered(parameters: nil), profile(readonly: "0"), readOnly: true).last?.value == "1")
    }

    @Test("Every entry point the host calls carries readonly=1 for a read-only context, and none for the default")
    func everyEntryPointCarriesIt() async throws {
        let server = ClickHouseStubServer()
        let driver = server.connectedDriver()

        _ = try await driver.execute(query: "SELECT 1", context: Self.externalRead)
        _ = try await driver.executeUserQuery(query: "SELECT 2", rowCap: 10, parameters: nil, context: Self.externalRead)
        _ = try await driver.executeUserQuery(query: "SELECT ?", rowCap: nil, parameters: [.text("3")], context: Self.externalRead)
        _ = try await driver.executeParameterized(query: "SELECT ?", parameters: [.text("4")], context: Self.externalRead)
        for try await _ in driver.streamRows(query: "SELECT 5", context: Self.externalRead) {}

        _ = try await driver.execute(query: "SELECT 6", context: PluginStatementContext())
        _ = try await driver.executeUserQuery(query: "SELECT 7", rowCap: 10, parameters: nil, context: PluginStatementContext())
        for try await _ in driver.streamRows(query: "SELECT 8", context: PluginStatementContext()) {}

        // A finished stream can still send its KILL QUERY, which is not a statement of the caller's.
        let statements = server.requests.filter { !$0.body.hasPrefix("KILL QUERY") }
        let guarded = statements.filter { $0.item("readonly") == "1" }.map(\.body)
        let unguarded = statements.filter { $0.item("readonly") == nil }.map(\.body)
        #expect(guarded == ["SELECT 1", "SELECT 2", "SELECT {p1:String}", "SELECT {p1:String}", "SELECT 5"])
        #expect(unguarded == ["SELECT 6", "SELECT 7", "SELECT 8"])
    }

    @Test("A statement the server refuses under readonly reads as a read-only refusal, and the server's text stays")
    func refusalIsReadOnly() async throws {
        let serverText = "Code: 164. DB::Exception: default: Cannot execute query in readonly mode. (READONLY) (version 26.8.36.3 (official build))"
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 500, body: serverText, headers: ["X-ClickHouse-Exception-Code": "164"])
        }
        let driver = server.connectedDriver()

        do {
            _ = try await driver.executeUserQuery(
                query: "INSERT INTO t VALUES (1)", rowCap: nil, parameters: nil, context: Self.externalRead
            )
            Issue.record("expected a refusal")
        } catch let error as ClickHouseError {
            #expect(error.message == String(localized: "This request is read only, and the statement is not a read."))
            #expect(error.exceptionCode == 164)
            #expect(error.pluginErrorDetail == serverText)
        }

        do {
            for try await _ in driver.streamRows(query: "INSERT INTO t VALUES (1)", context: Self.externalRead) {}
            Issue.record("expected a refusal")
        } catch let error as ClickHouseError {
            #expect(error.exceptionCode == 164)
            #expect(error.pluginErrorDetail == serverText)
        }

        do {
            _ = try await driver.execute(query: "INSERT INTO t VALUES (1)")
            Issue.record("expected the server's failure")
        } catch let error as ClickHouseError {
            #expect(error.message == serverText)
            #expect(error.pluginErrorDetail == nil)
        }
    }

    @Test("The driver says it runs a read-only statement in ClickHouse's own read-only mode")
    func declaresReadOnlyStatements() {
        #expect(ClickHouseStubServer().connectedDriver().capabilities.contains(.readOnlyStatements))
    }
}
