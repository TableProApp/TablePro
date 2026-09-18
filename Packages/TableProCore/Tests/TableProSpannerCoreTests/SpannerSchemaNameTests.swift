import Foundation
import TableProSpannerCore
import Testing

@Suite("SpannerSchemaName")
struct SpannerSchemaNameTests {
    @Test("GoogleSQL maps the default token to the nameless schema")
    func googleSQLName() {
        #expect(SpannerSchemaName.defaultToken == "(default)")
        #expect(SpannerSchemaName.sqlName(nil, dialect: .googleSQL) == "")
        #expect(SpannerSchemaName.sqlName("", dialect: .googleSQL) == "")
        #expect(SpannerSchemaName.sqlName("(default)", dialect: .googleSQL) == "")
        #expect(SpannerSchemaName.sqlName("sales", dialect: .googleSQL) == "sales")
    }

    @Test("GoogleSQL presents the nameless schema as the token")
    func googleSQLPresented() {
        #expect(SpannerSchemaName.presentedName("", dialect: .googleSQL) == "(default)")
        #expect(SpannerSchemaName.presentedName("sales", dialect: .googleSQL) == "sales")
    }

    @Test("PostgreSQL keeps public")
    func postgres() {
        #expect(SpannerSchemaName.sqlName(nil, dialect: .postgreSQL) == "public")
        #expect(SpannerSchemaName.sqlName("", dialect: .postgreSQL) == "public")
        #expect(SpannerSchemaName.sqlName("(default)", dialect: .postgreSQL) == "public")
        #expect(SpannerSchemaName.sqlName("sales", dialect: .postgreSQL) == "sales")
        #expect(SpannerSchemaName.presentedName("public", dialect: .postgreSQL) == "public")
        #expect(SpannerSchemaName.presentedName("sales", dialect: .postgreSQL) == "sales")
    }
}
