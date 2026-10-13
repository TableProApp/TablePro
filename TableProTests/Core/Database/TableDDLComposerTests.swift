//
//  TableDDLComposerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TableDDLComposerTests {
    private let tableDDL = "CREATE TABLE \"app\".\"orders\" (\n    id integer\n)"
    private let comment = "COMMENT ON TABLE \"app\".\"orders\" IS 'Orders table'"
    private let index = "CREATE INDEX idx_orders_day ON \"app\".\"orders\" (day)"

    private func offset(of needle: String, in text: String) throws -> Int {
        let range = try #require(text.range(of: needle), "\(needle) missing from the composition")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    @Test("Comments sit after the table statement and before the indexes, as a dump writes them")
    func commentsSitBetweenTheTableAndItsIndexes() throws {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [index], commentDDL: [comment])

        #expect(try offset(of: "CREATE TABLE", in: composed) < offset(of: "COMMENT ON TABLE", in: composed))
        #expect(try offset(of: "COMMENT ON TABLE", in: composed) < offset(of: "CREATE INDEX", in: composed))
    }

    @Test("Every statement is terminated once, even one the driver already terminated")
    func statementsAreTerminatedOnce() {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL,
            indexDDL: ["\(index);"],
            commentDDL: [comment])

        #expect(composed.contains("IS 'Orders table';"))
        #expect(!composed.contains("IS 'Orders table';;"))
        #expect(composed.contains("(day);"))
        #expect(!composed.contains("(day);;"))
    }

    @Test("The preamble stays first")
    func preambleStaysFirst() throws {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL,
            indexDDL: [],
            commentDDL: [comment],
            preamble: "CREATE SEQUENCE orders_id_seq;")

        #expect(try offset(of: "CREATE SEQUENCE", in: composed) < offset(of: "CREATE TABLE", in: composed))
        #expect(try offset(of: "CREATE TABLE", in: composed) < offset(of: "COMMENT ON TABLE", in: composed))
    }

    @Test("An empty comment list composes exactly as it did before comments existed")
    func emptyCommentListChangesNothing() {
        let withComments = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [index], commentDDL: [])
        let withoutComments = TableDDLComposer.compose(tableDDL: tableDDL, indexDDL: [index])

        #expect(withComments == withoutComments)
    }

    @Test("Comments alone still terminate the table statement and stand in their own block")
    func commentsAloneComposeWithoutIndexes() {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [], commentDDL: [comment])

        #expect(composed == "\(tableDDL);\n\n\(comment);")
    }

    @Test("A blank comment statement is dropped rather than written as an empty line")
    func blankStatementsAreDropped() {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [], commentDDL: ["", "   \n"])

        #expect(composed == tableDDL)
    }

    /// SQL Server reads everything after a `CREATE VIEW` in its batch as part of the view: measured on
    /// Azure SQL Edge, a view and its index after a `;` failed with Msg 156.
    @Test("A SQL Server view and its index each end in their own batch")
    func sqlServerStatementsEndTheirBatch() {
        let view = "-- owner: finance\ncreate view [dbo].[v] WITH SCHEMABINDING AS SELECT id FROM dbo.t -- note"
        let composed = TableDDLComposer.compose(
            tableDDL: view,
            indexDDL: ["CREATE UNIQUE CLUSTERED INDEX [IX_v] ON [dbo].[v] ([id])"],
            databaseType: .mssql
        )

        #expect(composed == """
            \(view)
            ;
            GO

            CREATE UNIQUE CLUSTERED INDEX [IX_v] ON [dbo].[v] ([id]);
            GO
            """)
    }

    @Test("A SQL Server view with nothing after it is its stored text alone")
    func sqlServerLoneViewIsUnchanged() {
        let view = "CREATE VIEW dbo.v AS SELECT 1 AS a"
        #expect(TableDDLComposer.compose(tableDDL: view, indexDDL: [], databaseType: .mssql) == view)
    }

    /// SQL Server's own scripts end every statement with a `GO` line, tables included.
    @Test("A SQL Server table and its indexes each end in their own batch")
    func sqlServerTableStatementsEndTheirBatch() {
        let composed = TableDDLComposer.compose(
            tableDDL: "CREATE TABLE [dbo].[t] (\n    [id] INT NOT NULL\n);",
            indexDDL: ["CREATE UNIQUE INDEX [UQ_a] ON [dbo].[t] ([a])", "CREATE INDEX [IX_b] ON [dbo].[t] ([b]);"],
            databaseType: .mssql
        )

        #expect(composed == """
            CREATE TABLE [dbo].[t] (
                [id] INT NOT NULL
            );
            GO

            CREATE UNIQUE INDEX [UQ_a] ON [dbo].[t] ([a]);
            GO
            CREATE INDEX [IX_b] ON [dbo].[t] ([b]);
            GO
            """)
    }

    /// A view's stored text can end in a line comment, which a `;` written after it would join.
    @Test("A statement ending in a line comment is terminated on its own line")
    func lineCommentKeepsItsTerminatorOutside() {
        let view = "CREATE VIEW \"app\".\"v\" AS SELECT 1 -- note"
        let composed = TableDDLComposer.compose(
            tableDDL: view, indexDDL: [], commentDDL: [comment], databaseType: .postgresql)

        #expect(composed == "\(view)\n;\n\n\(comment);")
    }

    @Test("A SQL Server view read through the driver keeps its index out of its batch")
    @MainActor
    func fetchedSQLServerViewSeparatesItsIndex() async throws {
        let stub = SourceDefinitionStubDriver()
        stub.tableDDL["v"] = "CREATE VIEW dbo.v WITH SCHEMABINDING AS SELECT id FROM dbo.t"
        stub.indexDDL["v"] = ["CREATE UNIQUE CLUSTERED INDEX [IX_v] ON [dbo].[v] ([id])"]
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .mssql), pluginDriver: stub)

        let ddl = try await TableDDLComposer.fetchDDL(for: "v", using: adapter, includesDependencies: true)

        #expect(ddl == """
            CREATE VIEW dbo.v WITH SCHEMABINDING AS SELECT id FROM dbo.t;
            GO

            CREATE UNIQUE CLUSTERED INDEX [IX_v] ON [dbo].[v] ([id]);
            GO
            """)
    }

    @Test("An engine without batch separator lines composes as before")
    func otherEnginesKeepTheirComposition() {
        let composed = TableDDLComposer.compose(
            tableDDL: tableDDL, indexDDL: [index], commentDDL: [comment], databaseType: .postgresql)

        #expect(composed == TableDDLComposer.compose(tableDDL: tableDDL, indexDDL: [index], commentDDL: [comment]))
        #expect(!composed.contains("GO"))
    }
}
