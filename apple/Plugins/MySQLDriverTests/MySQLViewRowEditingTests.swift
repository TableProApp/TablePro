//
//  MySQLViewRowEditingTests.swift
//  TableProTests
//
//  The definitions below are what MySQL 8.4 and MariaDB 11 store in
//  information_schema.VIEWS.VIEW_DEFINITION for the views named.
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLViewRowEditingTests {
    private func parse(_ text: String) throws -> MySQLViewRowEditing.Definition {
        try #require(MySQLViewRowEditing.parse(definition: text))
    }

    @Test("Every column of a SELECT * view maps to its base column")
    func simpleView() throws {
        let definition = try parse(
            "select `vt`.`t`.`id` AS `id`,`vt`.`t`.`name` AS `name`,`vt`.`t`.`qty` AS `qty` from `vt`.`t`"
        )
        #expect(definition.baseTable == .init(database: "vt", name: "t"))
        #expect(definition.origins == [
            PluginViewColumnOrigin(viewColumn: "id", baseColumn: "id"),
            PluginViewColumnOrigin(viewColumn: "name", baseColumn: "name"),
            PluginViewColumnOrigin(viewColumn: "qty", baseColumn: "qty"),
        ])
        #expect(MySQLViewRowEditing.resolve(isUpdatable: true, definition: definition, baseKeyColumns: ["id"])
            == .editable(keyColumns: ["id"]))
    }

    @Test("Swapped column names map by what each column shows, not by its name")
    func swappedNames() throws {
        let definition = try parse("select `vt`.`t`.`name` AS `id`,`vt`.`t`.`id` AS `name` from `vt`.`t`")
        #expect(MySQLViewRowEditing.resolve(isUpdatable: true, definition: definition, baseKeyColumns: ["id"])
            == .editable(keyColumns: ["name"]))
    }

    @Test("An aliased table, a computed column, a quoted name and a sub-select in WHERE (MySQL spelling)")
    func aliasedTableMySQL() throws {
        let definition = try parse("""
        select `x`.`id` AS `id`,(`x`.`qty` + 1) AS `q2`,`x`.`name` AS `we``ird, name` from `vt`.`t` `x` \
        where `x`.`id` in (select `vt`.`u`.`tid` from `vt`.`u`) order by `x`.`name`
        """)
        #expect(definition.baseTable == .init(database: "vt", name: "t"))
        #expect(definition.origins == [
            PluginViewColumnOrigin(viewColumn: "id", baseColumn: "id"),
            PluginViewColumnOrigin(viewColumn: "we`ird, name", baseColumn: "name"),
        ])
    }

    @Test("The same view in MariaDB's spelling, without brackets around the expression")
    func aliasedTableMariaDB() throws {
        let definition = try parse("""
        select `x`.`id` AS `id`,`x`.`qty` + 1 AS `q2`,`x`.`name` AS `we``ird, name` from `vt`.`t` `x` \
        where `x`.`id` in (select `vt`.`u`.`tid` from `vt`.`u`) order by `x`.`name`
        """)
        #expect(definition.origins.map { $0.viewColumn } == ["id", "we`ird, name"])
    }

    @Test("A join is not one table, even when every column comes from one side")
    func joinIsSeveralTables() throws {
        let definition = try parse("""
        select `vt`.`t`.`id` AS `id`,`vt`.`t`.`name` AS `name`,`vt`.`t`.`qty` AS `qty` \
        from (`vt`.`t` join `vt`.`u` on((`vt`.`u`.`tid` = `vt`.`t`.`id`)))
        """)
        #expect(definition.baseTable == nil)
        #expect(MySQLViewRowEditing.resolve(isUpdatable: true, definition: definition, baseKeyColumns: [])
            == .readOnly(.readsSeveralTables))
    }

    @Test("A string literal holding a comma or FROM does not split the select list")
    func literalIsOpaque() throws {
        let definition = try parse(
            "select 'a, from b' AS `label`,`vt`.`t`.`id` AS `id` from `vt`.`t` where (`vt`.`t`.`name` <> 'x''y')"
        )
        #expect(definition.origins == [PluginViewColumnOrigin(viewColumn: "id", baseColumn: "id")])
        #expect(definition.baseTable == .init(database: "vt", name: "t"))
    }

    @Test("A view the server reports as not updatable, or whose definition is withheld, stays read-only")
    func notUpdatable() throws {
        let definition = try parse("select distinct `vt`.`t`.`id` AS `id` from `vt`.`t`")
        #expect(MySQLViewRowEditing.resolve(isUpdatable: false, definition: definition, baseKeyColumns: ["id"])
            == .readOnly(.notUpdatable))
        #expect(MySQLViewRowEditing.parse(definition: "") == nil)
        #expect(MySQLViewRowEditing.resolve(isUpdatable: true, definition: nil, baseKeyColumns: ["id"])
            == .readOnly(.notUpdatable))
    }

    @Test("A view that leaves out the key stays read-only")
    func keyNotExposed() throws {
        let definition = try parse("select `vt`.`t`.`name` AS `name`,`vt`.`t`.`qty` AS `qty` from `vt`.`t`")
        #expect(MySQLViewRowEditing.resolve(isUpdatable: true, definition: definition, baseKeyColumns: ["id"])
            == .readOnly(.keyNotExposed))
    }

    @Test("The catalog queries escape names and fall back to the current database")
    func queries() {
        let escape: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        let view = MySQLViewRowEditing.viewQuery(name: "o'v", database: nil, escape: escape)
        #expect(view.contains("TABLE_SCHEMA = DATABASE()"))
        #expect(view.contains("TABLE_NAME = 'o''v'"))
        let key = MySQLViewRowEditing.primaryKeyQuery(
            table: .init(database: nil, name: "t"), viewDatabase: "shop", escape: escape
        )
        #expect(key.contains("TABLE_SCHEMA = 'shop'"))
        #expect(key.contains("CONSTRAINT_NAME = 'PRIMARY'"))
    }
}
