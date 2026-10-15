import TableProPluginKit
import Testing

struct MySQLMaintenanceTests {
    private func mysql(_ name: String) throws -> PluginMaintenanceOperation {
        try #require(MySQLMaintenance.operations.first { $0.name == name })
    }

    @Test("CHECK TABLE is the only MySQL operation offered on a view")
    func mysqlViewKinds() throws {
        #expect(try mysql("CHECK TABLE").applies(to: .view))
        #expect(try !mysql("OPTIMIZE TABLE").applies(to: .view))
        #expect(try !mysql("ANALYZE TABLE").applies(to: .view))
        #expect(try !mysql("REPAIR TABLE").applies(to: .view))
    }

    @Test("CHECK TABLE declares its mode, defaulting to MEDIUM")
    func mysqlCheckMode() throws {
        let check = try mysql("CHECK TABLE")
        let mode = try #require(check.options.first)

        #expect(check.options.count == 1)
        #expect(mode.key == "mode")
        #expect(mode.defaultValue == "MEDIUM")
        #expect(mode.choices == ["QUICK", "FAST", "MEDIUM", "EXTENDED", "CHANGED"])
        #expect(!mode.isToggle)
    }

    @Test("A MySQL target is backtick-quoted and qualified only when a schema is handed over")
    func mysqlStatements() {
        #expect(
            MySQLMaintenance.statements(
                operation: "OPTIMIZE TABLE", table: "orders", schema: nil, options: [:], flavor: .mysql
            ) == ["OPTIMIZE TABLE `orders`"]
        )
        #expect(
            MySQLMaintenance.statements(
                operation: "OPTIMIZE TABLE", table: "orders", schema: "shop", options: [:], flavor: .mysql
            ) == ["OPTIMIZE TABLE `shop`.`orders`"]
        )
        #expect(
            MySQLMaintenance.statements(
                operation: "CHECK TABLE", table: "orders", schema: nil, options: [:], flavor: .mysql
            ) == ["CHECK TABLE `orders` MEDIUM"]
        )
        #expect(
            MySQLMaintenance.statements(
                operation: "CHECK TABLE", table: "orders", schema: nil, options: ["mode": "EXTENDED"], flavor: .mysql
            ) == ["CHECK TABLE `orders` EXTENDED"]
        )
    }

    /// The mode lands in the statement text unquoted and reaches here from an MCP client as well as
    /// from the sheet's picker, so anything that is not a declared choice falls back to the default.
    @Test("A check mode outside the declared choices falls back to the default")
    func mysqlRejectsAnUndeclaredMode() {
        #expect(
            MySQLMaintenance.statements(
                operation: "CHECK TABLE",
                table: "orders",
                schema: nil,
                options: ["mode": "EXTENDED; DROP TABLE orders"],
                flavor: .mysql
            ) == ["CHECK TABLE `orders` MEDIUM"]
        )
    }

    @Test("A MySQL operation with no table produces nothing, because the engine has no such form")
    func mysqlNeedsATable() {
        #expect(MySQLMaintenance.operations.allSatisfy { $0.scope == .object })
        #expect(
            MySQLMaintenance.statements(
                operation: "ANALYZE TABLE", table: nil, schema: "shop", options: [:], flavor: .mysql
            ) == nil
        )
    }

    @Test("TiDB and Databend refuse an operation their flavor does not offer")
    func flavorGatesTheStatement() {
        for flavor in [MySQLServerFlavor.tidb(version: nil), .databend] {
            #expect(
                MySQLMaintenance.statements(
                    operation: "REPAIR TABLE", table: "orders", schema: nil, options: [:], flavor: flavor
                ) == nil
            )
            #expect(
                MySQLMaintenance.statements(
                    operation: "ANALYZE TABLE", table: "orders", schema: nil, options: [:], flavor: flavor
                ) != nil
            )
        }
    }

    @Test("OceanBase offers ANALYZE TABLE from 4.2.2, the first release that parses the bare form")
    func oceanbaseAnalyzeFloor() {
        let before = MySQLServerFlavor.oceanbase(version: MySQLEngineVersion(major: 4, minor: 2, patch: 1))
        let from = MySQLServerFlavor.oceanbase(version: MySQLEngineVersion(major: 4, minor: 2, patch: 2))
        #expect(MySQLMaintenance.statements(
            operation: "ANALYZE TABLE", table: "orders", schema: nil, options: [:], flavor: before
        ) == nil)
        #expect(MySQLMaintenance.statements(
            operation: "ANALYZE TABLE", table: "orders", schema: nil, options: [:], flavor: .oceanbase(version: nil)
        ) == nil)
        #expect(MySQLMaintenance.statements(
            operation: "ANALYZE TABLE", table: "orders", schema: "shop", options: [:], flavor: from
        ) == ["ANALYZE TABLE `shop`.`orders`"])
        #expect(MySQLMaintenance.statements(
            operation: "OPTIMIZE TABLE", table: "orders", schema: nil, options: [:], flavor: from
        ) == nil)
    }

    /// An option the descriptor declares that the statement builder never reads is the hardcoding bug
    /// in its other direction: the sheet would show a control that changes nothing.
    @Test("Every option a driver declares changes the statement it is declared on")
    func everyDeclaredOptionIsRead() throws {
        for operation in MySQLMaintenance.operations {
            let base = try #require(MySQLMaintenance.statements(
                operation: operation.name,
                table: "orders",
                schema: nil,
                options: operation.defaultOptionValues,
                flavor: .mysql
            ))
            for option in operation.options {
                var changed = operation.defaultOptionValues
                changed[option.key] = try alternative(to: option)
                let result = try #require(MySQLMaintenance.statements(
                    operation: operation.name, table: "orders", schema: nil, options: changed, flavor: .mysql
                ))
                #expect(result != base, "\(operation.name) ignores its own '\(option.key)' option")
            }
        }
    }

    private func alternative(to option: PluginMaintenanceOption) throws -> String {
        guard let choices = option.choices else {
            return option.defaultValue == "true" ? "false" : "true"
        }
        return try #require(choices.first { $0 != option.defaultValue })
    }
}
