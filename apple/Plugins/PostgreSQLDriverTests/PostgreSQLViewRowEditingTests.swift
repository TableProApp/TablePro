import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLViewRowEditingTests {
    @Test("Only the outermost target list counts, not a WHERE sub-select's")
    func readsOuterTargetList() {
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: Tree.whereSubselect) == [
            1: .init(relationOID: OID.t, attributeNumber: 1),
            2: .init(relationOID: OID.t, attributeNumber: 2),
        ])
    }

    @Test("A junk entry is skipped even when it carries an origin")
    func skipsJunkEntries() {
        let expected: [Int: PostgreSQLViewRowEditing.ColumnOrigin] = [
            1: .init(relationOID: OID.t, attributeNumber: 2),
            2: .init(relationOID: OID.t, attributeNumber: 1),
        ]
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: Tree.sorted) == expected)
        // The server writes no origin on a junk entry; this one gets one so only :resjunk keeps it out.
        let junkWithOrigin = Tree.sorted.replacingOccurrences(
            of: ":resorigtbl 0 :resorigcol 0 :resjunk true",
            with: ":resorigtbl \(OID.t) :resorigcol 3 :resjunk true"
        )
        #expect(junkWithOrigin != Tree.sorted)
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: junkWithOrigin) == expected)
    }

    @Test("A computed column has no origin")
    func computedColumnHasNoOrigin() {
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: Tree.innerCalc) == [
            1: .init(relationOID: OID.t, attributeNumber: 1),
            3: .init(relationOID: OID.t, attributeNumber: 2),
        ])
    }

    @Test("Escaped brackets and spaces in a column name do not end the entry")
    func escapedNames() {
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: Tree.overOdd) == [
            1: .init(relationOID: OID.vOdd, attributeNumber: 1),
            2: .init(relationOID: OID.vOdd, attributeNumber: 2),
        ])
    }

    @Test("Text that is not a query tree yields no origins")
    func malformedTreeYieldsNothing() {
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: "").isEmpty)
        #expect(PostgreSQLViewRowEditing.targetOrigins(nodeTree: "({QUERY :targetList <>})").isEmpty)
    }

    @Test("A table, or a name with no relation, is not a view")
    func notAView() {
        #expect(walk(Rows.t).step == .notAView)
        #expect(walk(nil).step == .notAView)
    }

    @Test(
        "A rule or an INSTEAD OF trigger makes the view read-only",
        arguments: [Rows.ruleSimple, Rows.ruleAggregate, Rows.ruleConditional, Rows.insteadOfTrigger]
    )
    func rulesAndTriggers(row: [String?]) {
        #expect(walk(row, through: [Rows.t]).step == .readOnly(.writesRunTriggers))
    }

    @Test("A trigger on a view one level down makes the outer view read-only")
    func triggerOnInnerView() {
        let walked = walk(Rows.overTrigger, through: [Rows.insteadOfTrigger, Rows.t])
        #expect(walked.step == .readOnly(.writesRunTriggers))
        #expect(walked.chain.map(\.oid) == [OID.vOverTrig, OID.vTrigSimple])
    }

    @Test("A view reading two tables is read-only for that reason")
    func join() {
        #expect(walk(Rows.join, through: [Rows.t]).step == .readOnly(.readsSeveralTables))
    }

    @Test("An aggregate reads one table but the server refuses writes")
    func aggregate() {
        #expect(walk(Rows.aggregate, through: [Rows.t]).step == .readOnly(.notUpdatable))
    }

    @Test("A view with no column from a relation is not updatable")
    func noBaseRelation() {
        #expect(walk(Rows.union, through: [Rows.t]).step == .readOnly(.notUpdatable))
    }

    @Test("Eight views over a table are walked, a ninth view is not")
    func depthLimit() {
        func chain(views: Int) -> [[String?]] {
            (1...views).map { level in
                let next = level == views ? OID.t : "9000\(level + 1)"
                return Rows.relation("9000\(level)", "v", "v\(level)", tree: Tree.passThrough(to: next))
            }
        }
        let eight = chain(views: 8)
        #expect(walk(eight[0], through: eight + [Rows.t]).step == .readColumns(
            viewOID: "90001",
            baseOID: OID.t,
            baseSchema: "public"
        ))
        let nine = chain(views: 9)
        #expect(walk(nine[0], through: nine + [Rows.t]).step == .readOnly(.notUpdatable))
    }

    @Test("A relation that is gone by the next read leaves the view read-only")
    func relationGoneMidWalk() {
        #expect(walk(Rows.v, through: []).step == .readOnly(.notUpdatable))
    }

    @Test("Operations come from the update, insert and delete bits")
    func operationBits() {
        #expect(PostgreSQLViewRowEditing.operations(events: 28) == .all)
        #expect(PostgreSQLViewRowEditing.operations(events: 20) == [.update, .delete])
        #expect(PostgreSQLViewRowEditing.operations(events: 4) == .update)
        #expect(PostgreSQLViewRowEditing.operations(events: 0).isEmpty)
    }

    @Test("Computed, generated and always-identity columns are read-only; the rest edit through the key")
    func simpleView() throws {
        let walked = walk(Rows.v, through: [Rows.t])
        #expect(walked.step == .readColumns(viewOID: OID.v, baseOID: OID.t, baseSchema: "public"))
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walked.chain,
            viewColumns: Rows.vColumns,
            baseColumns: Rows.tColumns
        )
        let target = try #require(editing.writeTarget)
        #expect(target.baseTable == PluginViewBaseTable(schema: "public", name: "t"))
        #expect(target.keyColumns == ["id"])
        #expect(target.readOnlyColumns == ["q2", "gen", "ident"])
        #expect(target.operations == .all)
        #expect(target.baseColumnNames["q2"] == nil)
    }

    @Test("Base defaults, identity and generated columns reach the target as the catalog says")
    func baseColumnFacts() throws {
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walk(Rows.v, through: [Rows.t]).chain,
            viewColumns: Rows.vColumns,
            baseColumns: Rows.tColumns
        )
        let columns = try #require(editing.writeTarget).baseColumns
        #expect(columns["ser"]?.defaultValue == "nextval('t_ser_seq'::regclass)")
        #expect(columns["ser"]?.isRequiredOnInsert == false)
        #expect(columns["gen"]?.defaultValue == nil)
        #expect(columns["gen"]?.acceptsWrites == false)
        #expect(columns["ident"]?.assignsValue == true)
        #expect(columns["ident"]?.acceptsWrites == false)
        #expect(columns["byd"]?.assignsValue == true)
        #expect(columns["byd"]?.acceptsWrites == true)
        #expect(columns["req"]?.isRequiredOnInsert == true)
    }

    @Test("Hiding a NOT NULL column with no default drops Add Row")
    func hiddenRequiredColumnDropsInsert() throws {
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walk(Rows.hideRequired, through: [Rows.t]).chain,
            viewColumns: Rows.hideRequiredColumns,
            baseColumns: Rows.tColumns
        )
        let target = try #require(editing.writeTarget)
        #expect(target.operations == [.update, .delete])
        #expect(target.keyColumns == ["id"])
    }

    @Test("A renamed key column keys the edit by its view name")
    func renamedKey() throws {
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walk(Rows.rename, through: [Rows.t]).chain,
            viewColumns: Rows.renameColumns,
            baseColumns: Rows.tColumns
        )
        let target = try #require(editing.writeTarget)
        #expect(target.keyColumns == ["key_id"])
        #expect(target.baseKeyColumns == ["id"])
        #expect(target.baseColumnNames == ["label": "name", "key_id": "id", "amount": "qty", "req": "req"])
    }

    @Test("Column numbers compose through each view down to the base table")
    func composedMap() throws {
        let nested = walk(Rows.nested, through: [Rows.rename, Rows.t])
        #expect(PostgreSQLViewRowEditing.baseAttributeNumbers(nested.chain) == [1: 1, 2: 2])

        let walked = walk(Rows.nested2, through: [Rows.nested, Rows.rename, Rows.t])
        #expect(walked.chain.map(\.oid) == [OID.vNested2, OID.vNested, OID.vRename, OID.t])
        #expect(walked.step == .readColumns(viewOID: OID.vNested2, baseOID: OID.t, baseSchema: "public"))
        #expect(PostgreSQLViewRowEditing.baseAttributeNumbers(walked.chain) == [1: 2, 2: 1])

        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walked.chain,
            viewColumns: Rows.nested2Columns,
            baseColumns: Rows.tColumns
        )
        let target = try #require(editing.writeTarget)
        #expect(target.baseTable == PluginViewBaseTable(schema: "public", name: "t"))
        #expect(target.keyColumns == ["k"])
        #expect(target.baseColumnNames == ["heading": "name", "k": "id"])
        #expect(target.operations == [.update, .delete])
    }

    @Test("A view that hides the key stays read-only")
    func hiddenKey() {
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walk(Rows.noKey, through: [Rows.t]).chain,
            viewColumns: Rows.noKeyColumns,
            baseColumns: Rows.tColumns
        )
        #expect(editing == .readOnly(.keyNotExposed))
    }

    @Test("A base table with no primary key stays read-only")
    func baseWithoutPrimaryKey() {
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walk(Rows.noPrimaryKey, through: [Rows.noPrimaryKeyTable]).chain,
            viewColumns: Rows.noPrimaryKeyColumns,
            baseColumns: Rows.noPrimaryKeyTableColumns
        )
        #expect(editing == .readOnly(.baseTableHasNoKey))
    }

    @Test("A composite key keeps the primary key's own order")
    func compositeKeyOrder() throws {
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walk(Rows.compositeKey, through: [Rows.compositeKeyTable]).chain,
            viewColumns: Rows.compositeKeyColumns,
            baseColumns: Rows.compositeKeyTableColumns
        )
        #expect(try #require(editing.writeTarget).keyColumns == ["b", "a"])
    }

    @Test("A target entry with no view attribute leaves the view read-only")
    func misreadTreeIsRefused() {
        let editing = PostgreSQLViewRowEditing.resolve(
            chain: walk(Rows.v, through: [Rows.t]).chain,
            viewColumns: Array(Rows.vColumns.dropLast()),
            baseColumns: Rows.tColumns
        )
        #expect(editing == .readOnly(.notUpdatable))
    }

    @Test("The catalog queries quote what they are given")
    func queriesQuote() {
        let byName = PostgreSQLViewRowEditing.relationQuery(name: "o'v", schema: "s")
        #expect(byName.contains("n.nspname = 's' AND c.relname = 'o''v'"))
        #expect(PostgreSQLViewRowEditing.relationQuery(oid: "16733").contains("c.oid = '16733'::oid"))
        #expect(PostgreSQLViewRowEditing.viewColumnsQuery(viewOID: "16761").contains("a.attrelid = '16761'::oid"))
        let modern = PostgreSQLViewRowEditing.baseColumnsQuery(
            baseOID: "16733",
            capabilities: PostgreSQLCapabilities(serverVersion: 170_000)
        )
        #expect(modern.contains("i.indrelid = '16733'::oid"))
        #expect(modern.contains("a.attidentity") && modern.contains("a.attgenerated"))
        #expect(modern.contains("key.ord <= i.indnkeyatts"))
    }

    @Test("Servers without identity or generated columns read neither")
    func legacyBaseColumns() {
        let query = PostgreSQLViewRowEditing.baseColumnsQuery(
            baseOID: "16733",
            capabilities: PostgreSQLCapabilities(serverVersion: 90_600)
        )
        #expect(!query.contains("attidentity"))
        #expect(!query.contains("attgenerated"))
        #expect(query.contains("key.ord <= i.indnatts"))
    }
}

private func walk(
    _ first: [String?]?,
    through relations: [[String?]] = []
) -> (chain: [PostgreSQLViewRowEditing.Relation], step: PostgreSQLViewRowEditing.Step) {
    var chain: [PostgreSQLViewRowEditing.Relation] = []
    var step = PostgreSQLViewRowEditing.step(&chain, row: first)
    while case .readRelation(let oid) = step {
        step = PostgreSQLViewRowEditing.step(&chain, row: relations.first { $0.first == oid })
    }
    return (chain, step)
}

private enum OID {
    static let t = "16733"
    static let ck = "16754"
    static let nopk = "16749"
    static let v = "16761"
    static let vRename = "16765"
    static let vNested = "16835"
    static let vNested2 = "16839"
    static let vTrigSimple = "16820"
    static let vOverTrig = "16851"
    static let vOdd = "16875"
}

// PostgreSQL 17.11 output for t(id int PRIMARY KEY, name text NOT NULL, qty int,
// gen int GENERATED ALWAYS AS (qty * 2) STORED, ident int GENERATED ALWAYS AS IDENTITY,
// byd int GENERATED BY DEFAULT AS IDENTITY, ser serial, req text NOT NULL), ck(a, b, c, PRIMARY KEY (b, a)),
// nopk(a, b) and the views named on each tree.
private enum Rows {
    static func relation(
        _ oid: String,
        _ kind: String,
        _ name: String,
        events: String = "28",
        rules: Bool = false,
        trigger: Bool = false,
        tree: String? = nil
    ) -> [String?] {
        [oid, kind, "public", name, events, rules ? "true" : "false", trigger ? "true" : "false", tree]
    }

    static let t = relation(OID.t, "r", "t")
    static let compositeKeyTable = relation(OID.ck, "r", "ck")
    static let noPrimaryKeyTable = relation(OID.nopk, "r", "nopk")
    static let v = relation(OID.v, "v", "v", tree: Tree.v)
    static let rename = relation(OID.vRename, "v", "v_rename", tree: Tree.rename)
    static let nested = relation(OID.vNested, "v", "v_nested", tree: Tree.nested)
    static let nested2 = relation(OID.vNested2, "v", "v_nested2", tree: Tree.nested2)
    static let ruleSimple = relation("16797", "v", "v_rule_simple", rules: true, tree: Tree.idName)
    static let ruleAggregate = relation("16802", "v", "v_rule_agg", events: "20", rules: true, tree: Tree.agg)
    static let ruleConditional = relation("16808", "v", "v_rule_cond", rules: true, tree: Tree.idName)
    static let insteadOfTrigger = relation(OID.vTrigSimple, "v", "v_trig_simple", trigger: true, tree: Tree.idName)
    static let overTrigger = relation(OID.vOverTrig, "v", "v_over_trig", tree: Tree.overTrig)
    static let aggregate = relation("16781", "v", "v_agg", events: "0", tree: Tree.agg)
    static let join = relation("16777", "v", "v_join", events: "0", tree: Tree.join)
    static let union = relation("16896", "v", "v_union", events: "0", tree: Tree.union)
    static let noKey = relation("16769", "v", "v_nokey", tree: Tree.noKey)
    static let hideRequired = relation("16773", "v", "v_hide_req", tree: Tree.hideReq)
    static let compositeKey = relation("16789", "v", "v_ck", tree: Tree.compositeKey)
    static let noPrimaryKey = relation("16793", "v", "v_nopk", tree: Tree.noPrimaryKey)

    static let tColumns: [[String?]] = [
        ["1", "id", "true", nil, "", "", "1"],
        ["2", "name", "true", nil, "", "", nil],
        ["3", "qty", "false", nil, "", "", nil],
        ["4", "gen", "false", "(qty * 2)", "", "s", nil],
        ["5", "ident", "true", nil, "a", "", nil],
        ["6", "byd", "true", nil, "d", "", nil],
        ["7", "ser", "true", "nextval('t_ser_seq'::regclass)", "", "", nil],
        ["8", "req", "true", nil, "", "", nil],
    ]
    static let compositeKeyTableColumns: [[String?]] = [
        ["1", "a", "true", nil, "", "", "2"],
        ["2", "b", "true", nil, "", "", "1"],
        ["3", "c", "false", nil, "", "", nil],
    ]
    static let noPrimaryKeyTableColumns: [[String?]] = [
        ["1", "a", "false", nil, "", "", nil],
        ["2", "b", "false", nil, "", "", nil],
    ]

    static let vColumns: [[String?]] = [
        ["1", "id", "true"],
        ["2", "name", "true"],
        ["3", "qty", "true"],
        ["4", "q2", "false"],
        ["5", "gen", "true"],
        ["6", "ident", "true"],
        ["7", "byd", "true"],
        ["8", "ser", "true"],
        ["9", "req", "true"],
    ]
    static let renameColumns: [[String?]] = [
        ["1", "label", "true"], ["2", "key_id", "true"], ["3", "amount", "true"], ["4", "req", "true"],
    ]
    static let nested2Columns: [[String?]] = [["1", "heading", "true"], ["2", "k", "true"]]
    static let noKeyColumns: [[String?]] = [["1", "name", "true"], ["2", "qty", "true"], ["3", "req", "true"]]
    static let hideRequiredColumns: [[String?]] = [["1", "id", "true"], ["2", "name", "true"], ["3", "qty", "true"]]
    static let compositeKeyColumns: [[String?]] = [["1", "c", "true"], ["2", "a", "true"], ["3", "b", "true"]]
    static let noPrimaryKeyColumns: [[String?]] = [["1", "a", "true"], ["2", "b", "true"]]
}

// pg_rewrite.ev_action of each view's _RETURN rule, without the fields the parser never reads.
private enum Tree {
    static func passThrough(to oid: String) -> String {
        """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 \
        :varnullingrels (b)} :resno 1 :resname id :resorigtbl \(oid) :resorigcol 1 :resjunk false}) :override 0})
        """
    }

    // CREATE VIEW v_where_sub AS SELECT id AS key_id, name FROM t WHERE id IN (SELECT t_id FROM t2) OR true
    static let whereSubselect = """
        ({QUERY :commandType 1 :rtable ({RANGETBLENTRY :alias <> :eref {ALIAS :aliasname t :colnames ("id" "name" \
        "qty" "gen" "ident" "byd" "ser" "req")} :rtekind 0 :relid 16733}) :jointree {FROMEXPR :fromlist \
        ({RANGETBLREF :rtindex 1}) :quals {BOOLEXPR :boolop or :args ({SUBLINK :subLinkType 2 :subLinkId 0 :testexpr \
        {OPEXPR :opno 96 :opfuncid 65 :opresulttype 16 :opretset false :opcollid 0 :inputcollid 0 :args ({VAR :varno \
        1 :varattno 1 :vartype 23 :varnullingrels (b)} {PARAM :paramkind 2 :paramid 1 :paramtype 23 :paramtypmod -1 \
        :paramcollid 0 :location -1}) :location -1} :operName ("=") :subselect {QUERY :commandType 1 :rtable \
        ({RANGETBLENTRY :alias <> :eref {ALIAS :aliasname t2 :colnames ("id" "t_id" "x")} :rtekind 0 :relid 16742}) \
        :jointree {FROMEXPR :fromlist ({RANGETBLREF :rtindex 1}) :quals <>} :targetList ({TARGETENTRY :expr {VAR \
        :varno 1 :varattno 2 :vartype 23 :varnullingrels (b)} :resno 1 :resname t_id :resorigtbl 16742 :resorigcol 2 \
        :resjunk false}) :override 0 :sortClause <>} :location -1} {CONST :consttype 16 :consttypmod -1 :constcollid \
        0 :constlen 1 :constbyval true :constisnull false :location -1 :constvalue 1 [ 1 0 0 0 0 0 0 0 ]}) :location \
        -1}} :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels (b)} :resno 1 \
        :resname key_id :resorigtbl 16733 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 2 \
        :vartype 25 :varnullingrels (b)} :resno 2 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk false}) \
        :override 0 :sortClause <>})
        """

    // CREATE VIEW v_sorted AS SELECT name, id FROM t ORDER BY qty
    static let sorted = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 25 :varnullingrels \
        (b)} :resno 1 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 1 :vartype 23 :varnullingrels (b)} :resno 2 :resname id :resorigtbl 16733 :resorigcol 1 :resjunk \
        false} {TARGETENTRY :expr {VAR :varno 1 :varattno 3 :vartype 23 :varnullingrels (b)} :resno 3 :resname <> \
        :ressortgroupref 1 :resorigtbl 0 :resorigcol 0 :resjunk true}) :override 0})
        """

    // CREATE VIEW v_inner_calc AS SELECT id, qty + 1 AS q2, name FROM t
    static let innerCalc = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels \
        (b)} :resno 1 :resname id :resorigtbl 16733 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {OPEXPR :opno \
        551 :opfuncid 177 :opresulttype 23 :opretset false :opcollid 0 :inputcollid 0 :args ({VAR :varno 1 :varattno \
        3 :vartype 23 :varnullingrels (b)} {CONST :consttype 23 :consttypmod -1 :constcollid 0 :constlen 4 \
        :constbyval true :constisnull false :location -1 :constvalue 4 [ 1 0 0 0 0 0 0 0 ]}) :location -1} :resno 2 \
        :resname q2 :resorigtbl 0 :resorigcol 0 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 2 \
        :vartype 25 :varnullingrels (b)} :resno 3 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk false}) \
        :override 0})
        """

    // CREATE VIEW v_over_odd AS SELECT "odd) }{name" AS "a""b(c", "two words" FROM v_odd
    static let overOdd = #"""
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 \#
        :varnullingrels (b)} :resno 1 :resname a"b\(c :resorigtbl 16875 :resorigcol 1 :resjunk false} {TARGETENTRY \#
        :expr {VAR :varno 1 :varattno 2 :vartype 25 :varnullingrels (b)} :resno 2 :resname two\ words :resorigtbl \#
        16875 :resorigcol 2 :resjunk false}) :override 0})
        """#

    // CREATE VIEW v AS SELECT id, name, qty, qty + 1 AS q2, gen, ident, byd, ser, req FROM t
    static let v = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels \
        (b)} :resno 1 :resname id :resorigtbl 16733 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 2 :vartype 25 :varnullingrels (b)} :resno 2 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk \
        false} {TARGETENTRY :expr {VAR :varno 1 :varattno 3 :vartype 23 :varnullingrels (b)} :resno 3 :resname qty \
        :resorigtbl 16733 :resorigcol 3 :resjunk false} {TARGETENTRY :expr {OPEXPR :opno 551 :opfuncid 177 \
        :opresulttype 23 :opretset false :opcollid 0 :inputcollid 0 :args ({VAR :varno 1 :varattno 3 :vartype 23 \
        :varnullingrels (b)} {CONST :consttype 23 :consttypmod -1 :constcollid 0 :constlen 4 :constbyval true \
        :constisnull false :location -1 :constvalue 4 [ 1 0 0 0 0 0 0 0 ]}) :location -1} :resno 4 :resname q2 \
        :resorigtbl 0 :resorigcol 0 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 4 :vartype 23 \
        :varnullingrels (b)} :resno 5 :resname gen :resorigtbl 16733 :resorigcol 4 :resjunk false} {TARGETENTRY \
        :expr {VAR :varno 1 :varattno 5 :vartype 23 :varnullingrels (b)} :resno 6 :resname ident :resorigtbl 16733 \
        :resorigcol 5 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 6 :vartype 23 :varnullingrels (b)} \
        :resno 7 :resname byd :resorigtbl 16733 :resorigcol 6 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 7 :vartype 23 :varnullingrels (b)} :resno 8 :resname ser :resorigtbl 16733 :resorigcol 7 :resjunk \
        false} {TARGETENTRY :expr {VAR :varno 1 :varattno 8 :vartype 25 :varnullingrels (b)} :resno 9 :resname req \
        :resorigtbl 16733 :resorigcol 8 :resjunk false}) :override 0})
        """

    // CREATE VIEW v_rename AS SELECT name AS label, id AS key_id, qty AS amount, req FROM t
    static let rename = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 25 :varnullingrels \
        (b)} :resno 1 :resname label :resorigtbl 16733 :resorigcol 2 :resjunk false} {TARGETENTRY :expr {VAR :varno \
        1 :varattno 1 :vartype 23 :varnullingrels (b)} :resno 2 :resname key_id :resorigtbl 16733 :resorigcol 1 \
        :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 3 :vartype 23 :varnullingrels (b)} :resno 3 \
        :resname amount :resorigtbl 16733 :resorigcol 3 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 8 \
        :vartype 25 :varnullingrels (b)} :resno 4 :resname req :resorigtbl 16733 :resorigcol 8 :resjunk false}) \
        :override 0})
        """

    // CREATE VIEW v_nested AS SELECT key_id, label AS title FROM v_rename
    static let nested = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 23 :varnullingrels \
        (b)} :resno 1 :resname key_id :resorigtbl 16765 :resorigcol 2 :resjunk false} {TARGETENTRY :expr {VAR :varno \
        1 :varattno 1 :vartype 25 :varnullingrels (b)} :resno 2 :resname title :resorigtbl 16765 :resorigcol 1 \
        :resjunk false}) :override 0})
        """

    // CREATE VIEW v_nested2 AS SELECT title AS heading, key_id AS k FROM v_nested
    static let nested2 = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 25 :varnullingrels \
        (b)} :resno 1 :resname heading :resorigtbl 16835 :resorigcol 2 :resjunk false} {TARGETENTRY :expr {VAR \
        :varno 1 :varattno 1 :vartype 23 :varnullingrels (b)} :resno 2 :resname k :resorigtbl 16835 :resorigcol 1 \
        :resjunk false}) :override 0})
        """

    // v_rule_simple, v_rule_cond and v_trig_simple: SELECT id, name FROM t
    static let idName = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels \
        (b)} :resno 1 :resname id :resorigtbl 16733 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 2 :vartype 25 :varnullingrels (b)} :resno 2 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk \
        false}) :override 0})
        """

    // CREATE VIEW v_over_trig AS SELECT id, name FROM v_trig_simple
    static let overTrig = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels \
        (b)} :resno 1 :resname id :resorigtbl 16820 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 2 :vartype 25 :varnullingrels (b)} :resno 2 :resname name :resorigtbl 16820 :resorigcol 2 :resjunk \
        false}) :override 0})
        """

    // v_agg and v_rule_agg: SELECT name, count(*) AS n FROM t GROUP BY name
    static let agg = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 25 :varnullingrels \
        (b)} :resno 1 :resname name :ressortgroupref 1 :resorigtbl 16733 :resorigcol 2 :resjunk false} {TARGETENTRY \
        :expr {AGGREF :aggfnoid 2803 :aggtype 20 :aggcollid 0 :inputcollid 0 :aggtranstype 0 :aggargtypes <> \
        :aggdirectargs <> :args <> :aggorder <> :aggdistinct <> :aggfilter <> :aggstar true :aggvariadic false \
        :aggkind n :aggpresorted false :agglevelsup 0 :aggsplit 0 :aggno -1 :aggtransno -1 :location -1} :resno 2 \
        :resname n :resorigtbl 0 :resorigcol 0 :resjunk false}) :override 0 :groupClause ({SORTGROUPCLAUSE \
        :tleSortGroupRef 1 :eqop 98 :sortop 664 :nulls_first false :hashable true})})
        """

    // CREATE VIEW v_join AS SELECT t.id, t.name, t2.x FROM t JOIN t2 ON t2.t_id = t.id
    static let join = """
        ({QUERY :commandType 1 :rteperminfos ({RTEPERMISSIONINFO :relid 16733 :inh true :requiredPerms 2 \
        :checkAsUser 0 :selectedCols (b 8 9) :insertedCols (b) :updatedCols (b)} {RTEPERMISSIONINFO :relid 16742 \
        :inh true :requiredPerms 2 :checkAsUser 0 :selectedCols (b 9 10) :insertedCols (b) :updatedCols (b)}) \
        :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels (b)} :resno 1 :resname \
        id :resorigtbl 16733 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 25 \
        :varnullingrels (b)} :resno 2 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk false} {TARGETENTRY \
        :expr {VAR :varno 2 :varattno 3 :vartype 25 :varnullingrels (b)} :resno 3 :resname x :resorigtbl 16742 \
        :resorigcol 3 :resjunk false}) :override 0})
        """

    // CREATE VIEW v_union AS SELECT id FROM t UNION SELECT id FROM t2
    static let union = """
        ({QUERY :commandType 1 :rteperminfos <> :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype \
        23 :varnullingrels (b)} :resno 1 :resname id :resorigtbl 0 :resorigcol 0 :resjunk false}) :override 0})
        """

    // CREATE VIEW v_nokey AS SELECT name, qty, req FROM t
    static let noKey = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 25 :varnullingrels \
        (b)} :resno 1 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 3 :vartype 23 :varnullingrels (b)} :resno 2 :resname qty :resorigtbl 16733 :resorigcol 3 :resjunk \
        false} {TARGETENTRY :expr {VAR :varno 1 :varattno 8 :vartype 25 :varnullingrels (b)} :resno 3 :resname req \
        :resorigtbl 16733 :resorigcol 8 :resjunk false}) :override 0})
        """

    // CREATE VIEW v_hide_req AS SELECT id, name, qty FROM t
    static let hideReq = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels \
        (b)} :resno 1 :resname id :resorigtbl 16733 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 2 :vartype 25 :varnullingrels (b)} :resno 2 :resname name :resorigtbl 16733 :resorigcol 2 :resjunk \
        false} {TARGETENTRY :expr {VAR :varno 1 :varattno 3 :vartype 23 :varnullingrels (b)} :resno 3 :resname qty \
        :resorigtbl 16733 :resorigcol 3 :resjunk false}) :override 0})
        """

    // CREATE VIEW v_ck AS SELECT c, a, b FROM ck
    static let compositeKey = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 3 :vartype 25 :varnullingrels \
        (b)} :resno 1 :resname c :resorigtbl 16754 :resorigcol 3 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 1 :vartype 23 :varnullingrels (b)} :resno 2 :resname a :resorigtbl 16754 :resorigcol 1 :resjunk \
        false} {TARGETENTRY :expr {VAR :varno 1 :varattno 2 :vartype 23 :varnullingrels (b)} :resno 3 :resname b \
        :resorigtbl 16754 :resorigcol 2 :resjunk false}) :override 0})
        """

    // CREATE VIEW v_nopk AS SELECT a, b FROM nopk
    static let noPrimaryKey = """
        ({QUERY :commandType 1 :targetList ({TARGETENTRY :expr {VAR :varno 1 :varattno 1 :vartype 23 :varnullingrels \
        (b)} :resno 1 :resname a :resorigtbl 16749 :resorigcol 1 :resjunk false} {TARGETENTRY :expr {VAR :varno 1 \
        :varattno 2 :vartype 25 :varnullingrels (b)} :resno 2 :resname b :resorigtbl 16749 :resorigcol 2 :resjunk \
        false}) :override 0})
        """
}
