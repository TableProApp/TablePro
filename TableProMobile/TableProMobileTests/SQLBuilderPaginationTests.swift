import Foundation
import TableProModels
import Testing

@testable import TableProMobile

/// `LIMIT` is not portable. SQL Server and Oracle both take OFFSET/FETCH, and both take it only as
/// part of an ORDER BY, which is why `paginationClause` supplies a filler when the caller has no
/// order of its own. The foreign-key preview wrote `LIMIT 1` by hand instead of calling this, so
/// every preview on those two engines failed and was rendered as a row that does not exist.
@Suite("SQLBuilder pagination")
struct SQLBuilderPaginationTests {
    @Test("SQL Server gets OFFSET/FETCH behind a filler ORDER BY")
    func mssqlUsesOffsetFetch() {
        let clause = SQLBuilder.paginationClause(orderBy: "", limit: 1, offset: 0, for: .mssql)
        #expect(clause == "ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY")
        #expect(!clause.contains("LIMIT"))
    }

    @Test("Oracle gets OFFSET/FETCH behind its own filler ORDER BY")
    func oracleUsesOffsetFetch() {
        let clause = SQLBuilder.paginationClause(orderBy: "", limit: 1, offset: 0, for: .oracle)
        #expect(clause == "ORDER BY 1 OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY")
        #expect(!clause.contains("LIMIT"))
    }

    @Test("A caller's own order replaces the filler rather than stacking with it")
    func callerOrderReplacesTheFiller() {
        let clause = SQLBuilder.paginationClause(orderBy: "ORDER BY [id]", limit: 10, offset: 20, for: .mssql)
        #expect(clause == "ORDER BY [id] OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY")
    }

    @Test("A LIMIT engine gets LIMIT and OFFSET")
    func limitEnginesUseLimit() {
        #expect(SQLBuilder.paginationClause(orderBy: "", limit: 1, offset: 0, for: .postgresql) == "LIMIT 1 OFFSET 0")
        #expect(SQLBuilder.paginationClause(orderBy: "", limit: 1, offset: 0, for: .mysql) == "LIMIT 1 OFFSET 0")
        #expect(SQLBuilder.paginationClause(orderBy: "", limit: 1, offset: 0, for: .sqlite) == "LIMIT 1 OFFSET 0")
    }

    @Test("Every SQL type iOS ships produces a clause the engine can parse")
    func everyShippedTypeProducesAUsableClause() {
        for type in IOSDriverFactory().supportedTypes() where type != .redis {
            let clause = SQLBuilder.paginationClause(orderBy: "", limit: 1, offset: 0, for: type)
            #expect(!clause.isEmpty, "\(type.rawValue) produced no pagination clause")
            if type == .mssql || type == .oracle {
                #expect(
                    clause.contains("FETCH NEXT"),
                    "\(type.rawValue) rejects LIMIT, so its clause must be OFFSET/FETCH"
                )
            }
        }
    }
}
