import Foundation
import TableProConnectionLibrary
@testable import TableProMobile
import TableProModels
import Testing

@Suite("Query editor SELECT template")
struct QueryTemplateTests {
    @Test("SQL Server gets OFFSET/FETCH and the schema the app has selected")
    func mssql() {
        let sql = QueryTemplate.selectAll(table: "t", schema: "sales", type: .mssql)
        #expect(sql == "SELECT * FROM [sales].[t] ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY")
    }

    @Test("Oracle gets FETCH NEXT instead of LIMIT")
    func oracle() {
        let sql = QueryTemplate.selectAll(table: "EMP", schema: "HR", type: .oracle)
        #expect(sql == "SELECT * FROM \"HR\".\"EMP\" ORDER BY 1 OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY")
    }

    @Test("MySQL keeps LIMIT")
    func mysql() {
        let sql = QueryTemplate.selectAll(table: "orders", schema: nil, type: .mysql)
        #expect(sql == "SELECT * FROM `orders` LIMIT 100 OFFSET 0")
    }

    @Test("PostgreSQL names the selected schema")
    func postgresql() {
        let sql = QueryTemplate.selectAll(table: "users", schema: "billing", type: .postgresql)
        #expect(sql == "SELECT * FROM \"billing\".\"users\" LIMIT 100 OFFSET 0")
    }

    @Test("Redis has no SQL template, since its query editor runs commands")
    func redis() {
        #expect(QueryTemplate.selectAll(table: "session:1", schema: nil, type: .redis) == nil)
    }

    @Test("Every iOS engine on the shared non-SQL list gets no SELECT template")
    func templateFollowsTheSharedNonSQLList() {
        for type in IOSDriverFactory().supportedTypes() {
            let hasTemplate = QueryTemplate.selectAll(table: "t", schema: nil, type: type) != nil
            #expect(
                hasTemplate == SQLDDLFallbackPolicy.allowsGeneratedDDL(databaseTypeId: type.rawValue),
                "\(type.rawValue)"
            )
        }
    }
}
