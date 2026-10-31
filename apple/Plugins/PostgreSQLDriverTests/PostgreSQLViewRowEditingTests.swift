//
//  PostgreSQLViewRowEditingTests.swift
//  TableProTests
//
//  The node trees below are what PostgreSQL 17 stores in pg_rewrite.ev_action, trimmed of the
//  fields the parser never reads.
//

import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLViewRowEditingTests {
    /// `CREATE VIEW v AS SELECT id AS key_id, name FROM t WHERE id IN (SELECT tid FROM u) OR true`:
    /// the sub-select's target list comes first in the text and names another table.
    private let viewWithSubselect = """
    ({QUERY :commandType 1 :querySource 0 :rtable ({RANGETBLENTRY :alias <> :eref {ALIAS :aliasname t \
    :colnames ("id" "name" "qty")} :rtekind 0 :relid 16388}) :jointree {FROMEXPR :fromlist ({RANGETBLREF \
    :rtindex 1}) :quals {BOOLEXPR :boolop or :args ({SUBLINK :subLinkType 2 :subselect {QUERY :commandType 1 \
    :rtable ({RANGETBLENTRY :relid 16395}) :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1} \
    :resno 1 :resname tid :ressortgroupref 0 :resorigtbl 16395 :resorigcol 1 :resjunk false}) :override 0} \
    :location -1} {CONST :consttype 16 :constvalue 1 [ 1 0 0 0 0 0 0 0 ]}) :location -1}} :targetList \
    ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23} :resno 1 :resname key_id :ressortgroupref 0 \
    :resorigtbl 16388 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 25} \
    :resno 2 :resname name :ressortgroupref 0 :resorigtbl 16388 :resorigcol 2 :resjunk false}) :override 0})
    """

    @Test("Only the outermost target list counts, not a sub-select's")
    func readsOuterTargetList() {
        let origins = PostgreSQLViewRowEditing.targetOrigins(nodeTree: viewWithSubselect)
        #expect(origins == [
            .init(viewAttributeNumber: 1, tableOID: "16388", columnNumber: 1),
            .init(viewAttributeNumber: 2, tableOID: "16388", columnNumber: 2),
        ])
    }

    @Test("A computed column has no origin")
    func computedColumnHasNoOrigin() {
        let tree = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {OPEXPR :opno 551 :args ({VAR :varno 1 \
        :varattno 3} {CONST :consttype 23 :constvalue 4 [ 1 0 0 0 0 0 0 0 ]})} :resno 1 :resname q2 \
        :ressortgroupref 0 :resorigtbl 0 :resorigcol 0 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 1} :resno 2 :resname id :ressortgroupref 0 :resorigtbl 16388 :resorigcol 1 :resjunk false}) \
        :override 0})
        """
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: tree) == [
            .init(viewAttributeNumber: 2, tableOID: "16388", columnNumber: 1),
        ])
    }

    @Test("An escaped bracket inside a column name does not end the entry")
    func escapedBracketInName() {
        let tree = """
        ({QUERY :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1} :resno 1 :resname odd\\)\\}\\ name \
        :ressortgroupref 0 :resorigtbl 77 :resorigcol 1 :resjunk false}) :override 0})
        """
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: tree) == [
            .init(viewAttributeNumber: 1, tableOID: "77", columnNumber: 1),
        ])
    }

    @Test("Text that is not a query tree yields no origins")
    func malformedTreeYieldsNothing() {
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: "").isEmpty)
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: "({QUERY :targetList <>})").isEmpty)
    }

    @Test("The key is mapped through attribute numbers, so a renamed key column still keys the edit")
    func resolvesRenamedKey() {
        let origins = PostgreSQLViewRowEditing.targetOrigins(nodeTree: viewWithSubselect)
        let editing = PostgreSQLViewRowEditing.resolve(
            isUpdatable: true,
            origins: origins,
            viewColumnNames: [1: "key_id", 2: "name"],
            baseKeyColumnNumbers: [1]
        )
        #expect(editing == .editable(keyColumns: ["key_id"]))
    }

    @Test("A view that hides the key column stays read-only")
    func hiddenKeyStaysReadOnly() {
        let origins = [PostgreSQLViewRowEditing.TargetOrigin(viewAttributeNumber: 1, tableOID: "16388", columnNumber: 2)]
        let editing = PostgreSQLViewRowEditing.resolve(
            isUpdatable: true, origins: origins, viewColumnNames: [1: "name"], baseKeyColumnNumbers: [1]
        )
        #expect(editing == .readOnly(.keyNotExposed))
    }

    @Test("The catalog queries quote the names they are given")
    func queriesQuoteNames() {
        let query = PostgreSQLViewRowEditing.viewQuery(name: "o'v", schema: "s")
        #expect(query.contains("c.relname = 'o''v'"))
        #expect(query.contains("pg_relation_is_updatable(c.oid, false) & 20) = 20"))
        let detail = PostgreSQLViewRowEditing.columnsAndKeyQuery(viewOID: "10", baseTableOID: "20")
        #expect(detail.contains("a.attrelid = '10'::oid"))
        #expect(detail.contains("i.indrelid = '20'::oid"))
    }
}
