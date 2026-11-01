//
//  MySQLViewRowEditingTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// Definitions and catalog rows as MySQL 8.4.13 and MariaDB 11.8.9 store them for the views named.
private enum Fixture {
    static let table = MySQLViewRowEditing.Relation(database: "impb", name: "t")

    static let mysqlV = """
        select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name`,`impb`.`t`.`qty` AS `qty`,\
        (`impb`.`t`.`qty` + 1) AS `q2`,`impb`.`t`.`gen` AS `gen`,`impb`.`t`.`req` AS `req` from `impb`.`t`
        """
    static let mariaDBV = """
        select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name`,`impb`.`t`.`qty` AS `qty`,\
        `impb`.`t`.`qty` + 1 AS `q2`,`impb`.`t`.`gen` AS `gen`,`impb`.`t`.`req` AS `req` from `impb`.`t`
        """
    static let vColumns = ["id", "name", "qty", "q2", "gen", "req"]

    // CREATE VIEW v_cols (name, id, qty) AS SELECT id, name, qty FROM t
    static let mysqlColumnList = """
        select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name`,`impb`.`t`.`qty` AS `qty` from `impb`.`t`
        """
    static let mariaDBColumnList = """
        select `impb`.`t`.`id` AS `name`,`impb`.`t`.`name` AS `id`,`impb`.`t`.`qty` AS `qty` from `impb`.`t`
        """

    static let rename = """
        select `impb`.`t`.`qty` AS `amount`,`impb`.`t`.`id` AS `key_id`,`impb`.`t`.`name` AS `Label`,\
        `impb`.`t`.`req` AS `req` from `impb`.`t`
        """

    static let base = """
        select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name`,`impb`.`t`.`qty` AS `qty`,\
        `impb`.`t`.`gen` AS `gen`,`impb`.`t`.`vgen` AS `vgen`,`impb`.`t`.`req` AS `req`,`impb`.`t`.`ts` AS `ts`,\
        `impb`.`t`.`ex` AS `ex`,`impb`.`t`.`dn` AS `dn`,`impb`.`t`.`nd` AS `nd`,`impb`.`t`.`s` AS `s`,\
        `impb`.`t`.`nn` AS `nn` from `impb`.`t`
        """
    static let baseColumns = ["id", "name", "qty", "gen", "vgen", "req", "ts", "ex", "dn", "nd", "s", "nn"]

    static let mysqlNested = """
        select `impb`.`v_base`.`id` AS `id`,`impb`.`v_base`.`name` AS `name`,`impb`.`v_base`.`req` AS `req` \
        from `impb`.`v_base`
        """
    static let mariaDBNested = """
        select `v_base`.`id` AS `id`,`v_base`.`name` AS `name`,`v_base`.`req` AS `req` from `impb`.`v_base`
        """

    // CREATE VIEW tcv AS SELECT id AS `<U+0301> AS q,t.id AS name from t where x`, name, qty FROM tc
    static let combiningMark = "select `impb`.`tc`.`id` AS `\u{301} AS q,t.id AS name from t where x`,"
        + "`impb`.`tc`.`name` AS `name`,`impb`.`tc`.`qty` AS `qty` from `impb`.`tc`"

    // COLUMN_NAME, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_TYPE of `t`, ordered by ORDINAL_POSITION.
    static let mysqlTableRows: [[String?]] = [
        ["id", "NO", nil, "auto_increment", "int"],
        ["name", "YES", nil, "", "varchar(20)"],
        ["qty", "NO", "0", "", "int"],
        ["gen", "YES", nil, "STORED GENERATED", "int"],
        ["vgen", "YES", nil, "VIRTUAL GENERATED", "int"],
        ["req", "NO", nil, "", "varchar(5)"],
        ["ts", "YES", "CURRENT_TIMESTAMP", "DEFAULT_GENERATED", "timestamp"],
        ["ex", "YES", "uuid()", "DEFAULT_GENERATED", "varchar(40)"],
        ["dn", "YES", nil, "", "varchar(5)"],
        ["nd", "YES", nil, "", "varchar(5)"],
        ["s", "YES", "abc", "", "varchar(5)"],
        ["nn", "NO", "x", "", "varchar(5)"],
    ]
    static let mariaDBTableRows: [[String?]] = [
        ["id", "NO", nil, "auto_increment", "int(11)"],
        ["name", "YES", "NULL", "", "varchar(20)"],
        ["qty", "NO", "0", "", "int(11)"],
        ["gen", "YES", "NULL", "STORED GENERATED", "int(11)"],
        ["vgen", "YES", "NULL", "VIRTUAL GENERATED", "int(11)"],
        ["req", "NO", nil, "", "varchar(5)"],
        ["ts", "YES", "current_timestamp()", "", "timestamp"],
        ["ex", "YES", "uuid()", "", "varchar(40)"],
        ["dn", "YES", "NULL", "", "varchar(5)"],
        ["nd", "YES", "NULL", "", "varchar(5)"],
        ["s", "YES", "'abc'", "", "varchar(5)"],
        ["nn", "NO", "'x'", "", "varchar(5)"],
    ]
    static let keyRows: [[String?]] = [["id"]]
}

private struct UnexpectedStep: Error {
    let step: MySQLViewRowEditing.Step
}

struct MySQLViewRowEditingTests {
    private func rows(_ names: [String]) -> [[String?]] {
        names.map { [$0] }
    }

    private func level(_ definition: String, columns: [String]) throws -> MySQLViewRowEditing.Level {
        let view = MySQLViewRowEditing.View(
            relation: .init(database: "impb", name: "v"),
            isUpdatable: true,
            definition: definition
        )
        let step = try MySQLViewRowEditing.step(view: view, columnRows: rows(columns))
        guard case .reads(let level) = step else { throw UnexpectedStep(step: step) }
        return level
    }

    private func answer(
        _ levels: [MySQLViewRowEditing.Level],
        keys: [[String?]] = Fixture.keyRows,
        tableRows: [[String?]] = Fixture.mysqlTableRows,
        quotesDefaults: Bool = false,
        insertNeedsPlainColumns: Bool = true,
        hasColumnGrants: Bool = false
    ) -> PluginViewRowEditing {
        MySQLViewRowEditing.answer(
            levels: levels,
            keyRows: keys,
            columnRows: tableRows,
            quotesDefaults: quotesDefaults,
            insertNeedsPlainColumns: insertNeedsPlainColumns,
            hasColumnGrants: hasColumnGrants
        )
    }

    @Test("A backquote followed by a combining mark still opens a quoted name")
    func combiningMarkAfterBackquote() {
        let tokens = MySQLViewRowEditing.tokenize("`\u{301} AS q,t.id`,`x`")
        let kinds = tokens.map { $0.kind }
        #expect(kinds == [.quoted, .symbol, .quoted])
        #expect(tokens.first?.text == "\u{301} AS q,t.id")
    }

    @Test("Doubled backquotes are undone, literals stay opaque and parentheses carry depth")
    func tokenizer() {
        let tokens = MySQLViewRowEditing.tokenize(#"`wei``rd, from` 'it\'s, `x` from' 'b\\c' (f(`a`))"#)
        let kinds = tokens.map { $0.kind }
        let depths = tokens.map { $0.depth }
        #expect(kinds == [.quoted, .literal, .literal, .symbol, .word, .symbol, .quoted, .symbol, .symbol])
        #expect(depths == [0, 0, 0, 0, 1, 1, 2, 1, 0])
        #expect(tokens.first?.text == "wei`rd, from")
        #expect(tokens.dropFirst().first?.text == #"'it\'s, `x` from'"#)
    }

    @Test("A combining mark in a stored name maps the view to its real table and columns")
    func combiningMarkDefinition() {
        #expect(MySQLViewRowEditing.select(definition: Fixture.combiningMark) == .oneTable(
            .init(database: "impb", name: "tc"),
            sources: ["id", "name", "qty"]
        ))
    }

    @Test("Plain column references map to the base, a computed item maps to nothing")
    func computedColumn() {
        let expected = MySQLViewRowEditing.Select.oneTable(
            Fixture.table,
            sources: ["id", "name", "qty", nil, "gen", "req"]
        )
        #expect(MySQLViewRowEditing.select(definition: Fixture.mysqlV) == expected)
        #expect(MySQLViewRowEditing.select(definition: Fixture.mariaDBV) == expected)
    }

    @Test("Literals, functions and subqueries in the select list are computed")
    func computedItems() {
        let definition = #"""
            select `impb`.`t`.`id` AS `id`,'it\'s, `x` from' AS `a`,ucase(`impb`.`t`.`name`) AS `u`,\
            (select count(0) from `impb`.`t2`) AS `c`,`impb`.`t`.`req` AS `wei``rd, from` from `impb`.`t`
            """#
        #expect(MySQLViewRowEditing.select(definition: definition) == .oneTable(
            Fixture.table,
            sources: ["id", nil, nil, nil, "req"]
        ))
    }

    @Test("An aliased table, a select modifier, unquoted names and a subquery in WHERE")
    func tableForms() {
        let forms = [
            "select `x`.`id` AS `id`,`x`.`name` AS `name` from `impb`.`t` `x`",
            "select straight_join `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name` from `impb`.`t`",
            "select impb.t.id AS id,impb.t.`name` AS `name` from impb.t",
            "(select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name` from `impb`.`t`)",
            """
            select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name` from `impb`.`t` where \
            (`impb`.`t`.`qty` > (select count(0) from `impb`.`t2` where (`impb`.`t2`.`t_id` = `impb`.`t`.`id`)))
            """,
            """
            with `c` as (select `impb`.`t2`.`id` AS `id` from `impb`.`t2`) select `impb`.`t`.`id` AS `id`,\
            `impb`.`t`.`name` AS `name` from `impb`.`t` where `impb`.`t`.`id` in (select `c`.`id` from `c`)
            """,
        ]
        for form in forms {
            #expect(MySQLViewRowEditing.select(definition: form) == .oneTable(Fixture.table, sources: ["id", "name"]))
        }
    }

    @Test("A join, MySQL's comma join and a table function read several tables")
    func severalTables() {
        let forms = [
            """
            select `impb`.`t`.`id` AS `id`,`impb`.`t2`.`note` AS `note` from (`impb`.`t` join `impb`.`t2` \
            on((`impb`.`t2`.`t_id` = `impb`.`t`.`id`)))
            """,
            """
            select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name` from `impb`.`t` join `impb`.`t2` \
            where (`impb`.`t2`.`t_id` = `impb`.`t`.`id`)
            """,
            """
            select `impb`.`t`.`id` AS `id`,`j`.`x` AS `x` from `impb`.`t` join json_table('[1,2]', '$[*]' \
            columns (`x` int path '$')) `j`
            """,
        ]
        for form in forms {
            #expect(MySQLViewRowEditing.select(definition: form) == .severalTables)
        }
    }

    @Test("A derived table, a common table expression or no FROM reads no base table")
    func noTable() {
        let forms = [
            """
            select `d`.`id` AS `id`,`d`.`name` AS `name` from (select `impb`.`t`.`id` AS `id`,\
            `impb`.`t`.`name` AS `name` from `impb`.`t`) `d`
            """,
            """
            with c as (select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name` from `impb`.`t`)\
            select `c`.`id` AS `id`,`c`.`name` AS `name` from `c`
            """,
            "select 1 AS `one`",
        ]
        for form in forms {
            #expect(MySQLViewRowEditing.select(definition: form) == .noTable)
        }
    }

    @Test("Each server's reference to an inner view names it as the base")
    func nestedForms() {
        let inner = MySQLViewRowEditing.Relation(database: "impb", name: "v_base")
        let expected = MySQLViewRowEditing.Select.oneTable(inner, sources: ["id", "name", "req"])
        #expect(MySQLViewRowEditing.select(definition: Fixture.mysqlNested) == expected)
        #expect(MySQLViewRowEditing.select(definition: Fixture.mariaDBNested) == expected)

        let rename = MySQLViewRowEditing.Relation(database: "impb", name: "v_rename")
        let aliased = MySQLViewRowEditing.Select.oneTable(rename, sources: ["key_id", "req"])
        let mysqlAliased = """
            select `impb`.`r`.`key_id` AS `key_id`,`impb`.`r`.`req` AS `req` from `impb`.`v_rename` `r`
            """
        let mariaDBAliased = "select `r`.`key_id` AS `key_id`,`r`.`req` AS `req` from `impb`.`v_rename` `r`"
        #expect(MySQLViewRowEditing.select(definition: mysqlAliased) == aliased)
        #expect(MySQLViewRowEditing.select(definition: mariaDBAliased) == aliased)
    }

    @Test("The server's answer comes first, then a hidden definition, then the FROM clause")
    func readOnlySteps() throws {
        let relation = MySQLViewRowEditing.Relation(database: "impb", name: "v")
        let notUpdatable = MySQLViewRowEditing.View(relation: relation, isUpdatable: false, definition: Fixture.mysqlV)
        #expect(try MySQLViewRowEditing.step(view: notUpdatable, columnRows: []) == .readOnly(.notUpdatable))

        let hidden = MySQLViewRowEditing.View(relation: relation, isUpdatable: true, definition: "")
        #expect(try MySQLViewRowEditing.step(view: hidden, columnRows: []) == .readOnly(.baseTableHidden))

        let derived = MySQLViewRowEditing.View(
            relation: relation,
            isUpdatable: true,
            definition: "select `d`.`id` AS `id` from (select `impb`.`t`.`id` AS `id` from `impb`.`t`) `d`"
        )
        #expect(try MySQLViewRowEditing.step(view: derived, columnRows: rows(["id"])) == .readOnly(.notUpdatable))

        let join = MySQLViewRowEditing.View(
            relation: relation,
            isUpdatable: true,
            definition: "select `impb`.`t`.`id` AS `id` from `impb`.`t` join `impb`.`t2`"
        )
        #expect(try MySQLViewRowEditing.step(view: join, columnRows: rows(["id"])) == .readOnly(.readsSeveralTables))
    }

    @Test("A select list that does not match the view's columns fails the check")
    func columnCountMismatch() {
        let view = MySQLViewRowEditing.View(
            relation: .init(database: "impb", name: "v"),
            isUpdatable: true,
            definition: Fixture.mysqlV
        )
        #expect(throws: MySQLViewRowEditing.ColumnCountMismatch(view: view.relation, items: 6, columns: 2)) {
            try MySQLViewRowEditing.step(view: view, columnRows: [["id"], ["name"]])
        }
    }

    @Test("A VIEWS row becomes the view; no row means the name is not a view")
    func viewRow() {
        #expect(MySQLViewRowEditing.view(rows: []) == nil)
        #expect(MySQLViewRowEditing.view(rows: [["impb", "v", "YES", ""]]) == MySQLViewRowEditing.View(
            relation: .init(database: "impb", name: "v"),
            isUpdatable: true,
            definition: ""
        ))
        #expect(MySQLViewRowEditing.view(rows: [["impb", "v", "NO", nil]])?.isUpdatable == false)
    }

    @Test("Edits key on the base table's key, computed and generated columns stay read-only")
    func simpleView() throws {
        let result = answer([try level(Fixture.mysqlV, columns: Fixture.vColumns)])
        let target = try #require(result.writeTarget)
        #expect(target.baseTable == PluginViewBaseTable(database: "impb", name: "t"))
        #expect(target.keyColumns == ["id"])
        #expect(target.readOnlyColumns == ["q2", "gen"])
        #expect(target.operations == [.update, .delete])
    }

    @Test("A key column a column grant hides keeps the view read-only")
    func columnGrantHidesKeyColumn() throws {
        let definition = "select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name` from `impb`.`t`"
        let result = answer(
            [try level(definition, columns: ["id", "name"])],
            keys: [["tenant_id"], ["id"]],
            tableRows: [["id", "NO", nil, "", "int"], ["name", "YES", nil, "", "varchar(20)"]]
        )
        #expect(result == .readOnly(.keyNotExposed))
    }

    @Test("Column grants on the base table leave its column list partial, so Add Row stays off")
    func columnGrantsDropInsert() throws {
        let level = try level(Fixture.mysqlV, columns: Fixture.vColumns)
        let target = try #require(answer([level], insertNeedsPlainColumns: false, hasColumnGrants: true).writeTarget)
        #expect(target.operations == [.update, .delete])
        #expect(MySQLViewRowEditing.hasColumnGrants(rows: [["2"]]))
        #expect(!MySQLViewRowEditing.hasColumnGrants(rows: [["0"]]))
    }

    @Test("MariaDB inserts through a view with a computed column when the INSERT leaves it out")
    func mariaDBInsertsPastComputedColumns() throws {
        let result = answer([try level(Fixture.mysqlV, columns: Fixture.vColumns)], insertNeedsPlainColumns: false)
        #expect(result.writeTarget?.operations == [.update, .insert, .delete])
    }

    @Test("Columns map by position, never by the alias MySQL stores beside a column list")
    func columnList() throws {
        let mysql = answer([try level(Fixture.mysqlColumnList, columns: ["name", "id", "qty"])])
        let mariaDB = answer([try level(Fixture.mariaDBColumnList, columns: ["name", "id", "qty"])])
        for result in [mysql, mariaDB] {
            let target = try #require(result.writeTarget)
            #expect(target.keyColumns == ["name"])
            #expect(target.baseColumnNames == ["name": "id", "id": "name", "qty": "qty"])
        }

        let list = answer([try level(Fixture.mysqlColumnList, columns: ["a", "b", "qty"])])
        #expect(list.writeTarget?.keyColumns == ["a"])
    }

    @Test("A renamed key is the view's name for it")
    func renamedKey() throws {
        let result = answer([try level(Fixture.rename, columns: ["amount", "key_id", "Label", "req"])])
        #expect(result.writeTarget?.keyColumns == ["key_id"])
        #expect(result.writeTarget?.operations == [.update, .insert, .delete])
    }

    @Test("A view that leaves out the key, or over a table without one, stays read-only")
    func missingKey() throws {
        let noKey = "select `impb`.`t`.`name` AS `name`,`impb`.`t`.`qty` AS `qty` from `impb`.`t`"
        #expect(answer([try level(noKey, columns: ["name", "qty"])]) == .readOnly(.keyNotExposed))
        let keyless = answer([try level(Fixture.mysqlV, columns: Fixture.vColumns)], keys: [])
        #expect(keyless == .readOnly(.baseTableHasNoKey))
    }

    @Test("A composite key comes back in the key's order, under the view's names")
    func compositeKey() throws {
        let definition = """
            select `impb`.`ck`.`a` AS `a`,`impb`.`ck`.`b` AS `b`,`impb`.`ck`.`c` AS `c` from `impb`.`ck`
            """
        let tableRows: [[String?]] = [
            ["a", "NO", nil, "", "int"],
            ["b", "NO", nil, "", "int"],
            ["c", "YES", nil, "", "text"],
        ]
        let result = answer(
            [try level(definition, columns: ["a", "b", "c"])],
            keys: [["b"], ["a"]],
            tableRows: tableRows
        )
        #expect(result.writeTarget?.keyColumns == ["b", "a"])
    }

    @Test("A base table the user cannot read hides the key")
    func hiddenBase() throws {
        let result = answer([try level(Fixture.mysqlV, columns: Fixture.vColumns)], keys: [], tableRows: [])
        #expect(result == .readOnly(.baseTableHidden))
    }

    @Test("A view over a view resolves to the table underneath, on both servers")
    func nestedView() throws {
        for nested in [Fixture.mysqlNested, Fixture.mariaDBNested] {
            let levels = [
                try level(nested, columns: ["id", "name", "req"]),
                try level(Fixture.base, columns: Fixture.baseColumns),
            ]
            let target = try #require(answer(levels).writeTarget)
            #expect(target.baseTable == PluginViewBaseTable(database: "impb", name: "t"))
            #expect(target.keyColumns == ["id"])
            #expect(target.operations == [.update, .insert, .delete])
        }
    }

    @Test("Renames compose through three levels")
    func threeLevels() throws {
        let top = "select `impb`.`v_over_rename`.`key_id` AS `k3`,`impb`.`v_over_rename`.`lbl` AS `lbl` "
            + "from `impb`.`v_over_rename`"
        let middle = "select `v_rename`.`key_id` AS `key_id`,`v_rename`.`Label` AS `lbl`,`v_rename`.`req` AS `req` "
            + "from `impb`.`v_rename`"
        let levels = [
            try level(top, columns: ["k3", "lbl"]),
            try level(middle, columns: ["key_id", "lbl", "req"]),
            try level(Fixture.rename, columns: ["amount", "key_id", "Label", "req"]),
        ]
        let target = try #require(answer(levels).writeTarget)
        #expect(target.keyColumns == ["k3"])
        #expect(target.baseColumnNames == ["k3": "id", "lbl": "name"])
        // `req` is NOT NULL with no default and not shown.
        #expect(!target.operations.contains(.insert))
    }

    @Test("Add Row needs every view column to be a base column shown once", arguments: [
        ("select `impb`.`t`.`id` AS `id`,`impb`.`t`.`id` AS `id2`,`impb`.`t`.`req` AS `req` from `impb`.`t`", false),
        ("select `impb`.`t`.`id` AS `id`,'x' AS `k`,`impb`.`t`.`req` AS `req` from `impb`.`t`", false),
        ("select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name`,`impb`.`t`.`req` AS `req` from `impb`.`t`", true),
    ])
    func insertRule(definition: String, allowsInsert: Bool) throws {
        let result = answer([try level(definition, columns: ["id", "x", "req"])])
        #expect(result.writeTarget?.operations.contains(.insert) == allowsInsert)
    }

    @Test("An inner view's computed column the outer view does not show leaves Add Row on, as MySQL does")
    func insertThroughNestedViews() throws {
        let middle = """
            select `impb`.`v_base`.`id` AS `id`,`impb`.`v_base`.`name` AS `name`,`impb`.`v_base`.`req` AS `req`,\
            (`impb`.`v_base`.`qty` * 3) AS `q3` from `impb`.`v_base`
            """
        let middleLevel = try level(middle, columns: ["id", "name", "req", "q3"])
        let baseLevel = try level(Fixture.base, columns: Fixture.baseColumns)

        let hidesComputed = "select `impb`.`v_mid`.`id` AS `id`,`impb`.`v_mid`.`name` AS `name`,"
            + "`impb`.`v_mid`.`req` AS `req` from `impb`.`v_mid`"
        let top = try level(hidesComputed, columns: ["id", "name", "req"])
        #expect(answer([top, middleLevel, baseLevel]).writeTarget?.operations == [.update, .insert, .delete])

        let showsComputed = "select `impb`.`v_mid`.`id` AS `id`,`impb`.`v_mid`.`q3` AS `q3`,"
            + "`impb`.`v_mid`.`req` AS `req` from `impb`.`v_mid`"
        let computedTop = try level(showsComputed, columns: ["id", "q3", "req"])
        let target = try #require(answer([computedTop, middleLevel, baseLevel]).writeTarget)
        #expect(target.readOnlyColumns == ["q3"])
        #expect(target.operations == [.update, .delete])
    }

    @Test("A view hiding a NOT NULL column without a default allows no Add Row")
    func hiddenRequiredColumn() throws {
        let definition = """
            select `impb`.`t`.`id` AS `id`,`impb`.`t`.`name` AS `name`,`impb`.`t`.`qty` AS `qty` from `impb`.`t`
            """
        let result = answer([try level(definition, columns: ["id", "name", "qty"])])
        #expect(result.writeTarget?.operations == [.update, .delete])
    }

    @Test("Base columns read the same from MySQL's bare catalog and MariaDB's quoted one")
    func baseColumns() throws {
        for (rows, quotes) in [(Fixture.mysqlTableRows, false), (Fixture.mariaDBTableRows, true)] {
            let columns = rows.compactMap { MySQLViewRowEditing.baseColumn(row: $0, quotesDefaults: quotes) }
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
            let id = try #require(byName["id"])
            #expect(id.assignsValue && id.acceptsWrites && !id.isRequiredOnInsert)
            #expect(byName["gen"]?.acceptsWrites == false)
            #expect(byName["vgen"]?.acceptsWrites == false)
            #expect(byName["ts"]?.acceptsWrites == true)
            #expect(byName["req"]?.isRequiredOnInsert == true)
            #expect(byName["req"]?.defaultValue == nil)
            #expect(byName["name"]?.defaultValue == "NULL")
            #expect(byName["qty"]?.defaultValue == "0")
            #expect(byName["s"]?.defaultValue == "'abc'")
            #expect(byName["nn"]?.isRequiredOnInsert == false)
            let required = columns.filter { $0.isRequiredOnInsert }.map { $0.name }
            #expect(required == ["req"])
        }
        let mysqlExpression = MySQLViewRowEditing.baseColumn(row: Fixture.mysqlTableRows[7], quotesDefaults: false)
        let mariaDBExpression = MySQLViewRowEditing.baseColumn(row: Fixture.mariaDBTableRows[7], quotesDefaults: true)
        #expect(mysqlExpression?.defaultValue == "(uuid())")
        #expect(mariaDBExpression?.defaultValue == "uuid()")
    }

    @Test("The catalog statements escape names and fall back to the current database")
    func statements() {
        let escape: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        let view = MySQLViewRowEditing.viewQuery(database: nil, name: "o'v", escape: escape)
        #expect(view.contains("TABLE_SCHEMA = DATABASE()"))
        #expect(view.contains("TABLE_NAME = 'o''v'"))
        let relation = MySQLViewRowEditing.Relation(database: "sh'op", name: "t")
        #expect(MySQLViewRowEditing.viewQuery(database: "sh'op", name: "t", escape: escape).contains("'sh''op'"))
        #expect(MySQLViewRowEditing.primaryKeyQuery(relation, escape: escape).contains("INDEX_NAME = 'PRIMARY'"))
        #expect(MySQLViewRowEditing.columnsQuery(relation, escape: escape).hasSuffix("ORDER BY ORDINAL_POSITION"))
    }
}
