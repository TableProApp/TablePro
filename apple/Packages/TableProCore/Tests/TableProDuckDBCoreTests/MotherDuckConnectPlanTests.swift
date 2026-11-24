import Foundation
import TableProDuckDBCore
import Testing

struct MotherDuckConnectPlanTests {
    @Test("No database attaches the whole workspace")
    func workspace() throws {
        let plan = try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "eyJ.a.b"))
        #expect(plan.database == nil)
        #expect(plan.settingStatements == [
            "SET motherduck_token = 'eyJ.a.b'",
            "SET motherduck_attach_mode = 'workspace'",
        ])
        #expect(plan.attachStatement == "ATTACH 'md:'")
    }

    @Test("A named database attaches only that one, in single mode")
    func single() throws {
        let plan = try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "eyJ.a.b", database: "  my_db "))
        #expect(plan.database == "my_db")
        #expect(plan.settingStatements.last == "SET motherduck_attach_mode = 'single'")
        #expect(plan.attachStatement == "ATTACH 'md:my_db'")
    }

    @Test("Quotes in the token and the name stay inside their literals")
    func quoting() throws {
        let plan = try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "a'b", database: "it's"))
        #expect(plan.settingStatements.first == "SET motherduck_token = 'a''b'")
        #expect(plan.attachStatement == "ATTACH 'md:it''s'")
    }

    @Test("An empty token is refused before anything opens, since MotherDuck would start a browser sign-in", arguments: [
        "", "   ", "\n\t",
    ])
    func missingToken(token: String) {
        #expect(throws: MotherDuckConnectError.missingToken) {
            try MotherDuckConnectPlan(MotherDuckConnectRequest(token: token, database: "my_db"))
        }
    }

    @Test("A token with a control character is refused without echoing it", arguments: ["eyJ.a\u{0}.b", "eyJ.a\n.b"])
    func invalidToken(token: String) throws {
        #expect(throws: MotherDuckConnectError.invalidToken) {
            try MotherDuckConnectPlan(MotherDuckConnectRequest(token: token))
        }
        let message = try #require(MotherDuckConnectError.invalidToken.errorDescription)
        #expect(!message.contains("eyJ"))
    }

    @Test("A name carrying connection parameters is refused", arguments: [
        "my_db?saas_mode=true", "my_db#x", "my\u{0}db", "my\ndb",
    ])
    func invalidDatabase(name: String) {
        #expect(throws: MotherDuckConnectError.invalidDatabase(name: name)) {
            try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "t", database: name))
        }
    }

    @Test("A share path is accepted as it is")
    func sharePath() throws {
        let plan = try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "t", database: "_share/sample_data/6ae6172b"))
        #expect(plan.attachStatement == "ATTACH 'md:_share/sample_data/6ae6172b'")
    }

    @Test("The deadline reaches MotherDuck in whole seconds, never below one")
    func timeout() {
        #expect(MotherDuckConnectPlan.connectionTimeoutStatement(remaining: .seconds(27.8))
            == "SET motherduck_connection_timeout = '27 seconds'")
        #expect(MotherDuckConnectPlan.connectionTimeoutStatement(remaining: .milliseconds(200))
            == "SET motherduck_connection_timeout = '1 seconds'")
        #expect(MotherDuckConnectPlan.connectionTimeoutStatement(remaining: .seconds(-3))
            == "SET motherduck_connection_timeout = '1 seconds'")
    }

    @Test("The catalog to use is the named one, matched as DuckDB matches a catalog")
    func catalogForANamedDatabase() throws {
        let plan = try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "t", database: "My_DB"))
        #expect(plan.catalogToUse(among: ["my_db"]) == "my_db")
        #expect(plan.catalogToUse(among: ["a", "My_DB"]) == "My_DB")
        #expect(plan.catalogToUse(among: ["a", "b"]) == nil)
        #expect(plan.catalogToUse(among: []) == nil)
    }

    @Test("A share path lands on the one catalog MotherDuck names after the share")
    func catalogForAShare() throws {
        let plan = try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "t", database: "_share/sample_data/6ae6172b"))
        #expect(plan.catalogToUse(among: ["sample_data"]) == "sample_data")
    }

    @Test("With no database named, the first catalog stands in when the account has no default")
    func catalogForTheWorkspace() throws {
        let plan = try MotherDuckConnectPlan(MotherDuckConnectRequest(token: "t"))
        #expect(plan.catalogToUse(among: ["my_db", "sample_data"]) == "my_db")
        #expect(plan.catalogToUse(among: []) == nil)
    }
}

struct DuckDBConnectionModeTests {
    @Test("A connection saved with no mode is a local file")
    func missingIsLocal() {
        #expect(DuckDBConnectionMode(fieldValue: nil) == .local)
        #expect(DuckDBConnectionMode(fieldValue: "") == .local)
    }

    @Test("Each stored value reads as its mode")
    func storedValues() {
        #expect(DuckDBConnectionMode(fieldValue: "local") == .local)
        #expect(DuckDBConnectionMode(fieldValue: "remote") == .remote)
        #expect(DuckDBConnectionMode(fieldValue: "motherduck") == .motherDuck)
    }

    @Test("A mode this build does not know is never read as a local file")
    func unknownIsNil() {
        #expect(DuckDBConnectionMode(fieldValue: "lakehouse") == nil)
    }
}
