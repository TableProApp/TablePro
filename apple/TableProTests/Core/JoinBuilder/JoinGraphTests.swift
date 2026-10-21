import Foundation
import Testing

@testable import TablePro

struct JoinGraphTests {
    static let columns: [String: [String]] = [
        "customers": ["id", "name"],
        "orders": ["id", "customer_id", "status"],
        "products": ["id", "title"],
        "order_items": ["order_id", "product_id", "quantity"],
        "notes": ["id", "body"]
    ]

    static let foreignKeys: [String: [ForeignKeyInfo]] = [
        "orders": [
            ForeignKeyInfo(name: "orders_customer_fk", column: "customer_id", referencedTable: "customers", referencedColumn: "id")
        ],
        "order_items": [
            ForeignKeyInfo(name: "items_order_fk", column: "order_id", referencedTable: "orders", referencedColumn: "id"),
            ForeignKeyInfo(name: "items_product_fk", column: "product_id", referencedTable: "products", referencedColumn: "id")
        ]
    ]

    static func graph(
        columns: [String: [String]] = columns,
        foreignKeys: [String: [ForeignKeyInfo]] = foreignKeys,
        isLocal: (ForeignKeyInfo) -> Bool = { _ in true }
    ) -> JoinGraph {
        JoinGraph(columns: columns, foreignKeys: foreignKeys, isLocal: isLocal)
    }

    @Test("A key between two picked tables is found from either side")
    func directKeyEitherDirection() throws {
        let graph = Self.graph()

        let fromOrders = try #require(graph.path(to: "customers", from: ["orders"]))
        let fromCustomers = try #require(graph.path(to: "orders", from: ["customers"]))

        #expect(fromOrders.map { $0.table } == ["customers"])
        #expect(fromOrders.first?.relationship.childTable == "orders")
        #expect(fromOrders.first?.relationship.columnPairs == [.init(child: "customer_id", parent: "id")])
        #expect(fromCustomers.map { $0.table } == ["orders"])
        #expect(fromCustomers.first?.relationship == fromOrders.first?.relationship)
    }

    @Test("A many-to-many pair is linked through its junction table, the junction first")
    func junctionPath() throws {
        let steps = try #require(Self.graph().path(to: "products", from: ["orders"]))

        #expect(steps.map { $0.table } == ["order_items", "products"])
        #expect(steps.map { $0.relationship.name } == ["items_order_fk", "items_product_fk"])
    }

    @Test("A junction wins over a parent the two tables only share, whatever the tables are named")
    func junctionBeatsSharedParent() throws {
        let columns = [
            "orders": ["id", "created_by"],
            "products": ["id", "created_by"],
            "users": ["id"],
            "zz_lines": ["order_id", "product_id"]
        ]
        let keys = [
            "orders": [ForeignKeyInfo(name: "orders_user_fk", column: "created_by", referencedTable: "users", referencedColumn: "id")],
            "products": [ForeignKeyInfo(name: "products_user_fk", column: "created_by", referencedTable: "users", referencedColumn: "id")],
            "zz_lines": [
                ForeignKeyInfo(name: "lines_order_fk", column: "order_id", referencedTable: "orders", referencedColumn: "id"),
                ForeignKeyInfo(name: "lines_product_fk", column: "product_id", referencedTable: "products", referencedColumn: "id")
            ]
        ]

        let steps = try #require(Self.graph(columns: columns, foreignKeys: keys).path(to: "products", from: ["orders"]))

        #expect(steps.map { $0.table } == ["zz_lines", "products"])
    }

    @Test("A shared parent still links two tables when nothing else does")
    func sharedParentWhenAlone() throws {
        let columns = ["orders": ["id", "created_by"], "products": ["id", "created_by"], "users": ["id"]]
        let keys = [
            "orders": [ForeignKeyInfo(name: "orders_user_fk", column: "created_by", referencedTable: "users", referencedColumn: "id")],
            "products": [ForeignKeyInfo(name: "products_user_fk", column: "created_by", referencedTable: "users", referencedColumn: "id")]
        ]

        let steps = try #require(Self.graph(columns: columns, foreignKeys: keys).path(to: "products", from: ["orders"]))

        #expect(steps.map { $0.table } == ["users", "products"])
    }

    @Test("A chain through a parent reaches its grandparent")
    func chainThroughParent() throws {
        let columns = ["track": ["id", "album_id"], "album": ["id", "artist_id"], "artist": ["id"]]
        let keys = [
            "track": [ForeignKeyInfo(name: "track_album_fk", column: "album_id", referencedTable: "album", referencedColumn: "id")],
            "album": [ForeignKeyInfo(name: "album_artist_fk", column: "artist_id", referencedTable: "artist", referencedColumn: "id")]
        ]

        let steps = try #require(Self.graph(columns: columns, foreignKeys: keys).path(to: "artist", from: ["track"]))

        #expect(steps.map { $0.table } == ["album", "artist"])
    }

    @Test("The shortest chain wins over a longer one, from any table already picked")
    func shortestFromAnyPickedTable() throws {
        let steps = try #require(Self.graph().path(to: "products", from: ["customers", "order_items"]))

        #expect(steps.map { $0.table } == ["products"])
    }

    @Test("A table no key reaches has no path, and a picked one an empty path")
    func unreachableAndAlreadyJoined() {
        let graph = Self.graph()

        #expect(graph.path(to: "notes", from: ["orders"]) == nil)
        #expect(graph.path(to: "orders", from: ["orders"]) == [])
        #expect(graph.path(to: "missing", from: ["orders"]) == nil)
    }

    @Test("A composite key is one relationship holding every column pair in order")
    func compositeKeyIsOneRelationship() throws {
        let columns = ["shipments": ["order_id", "line", "id"], "lines": ["order_id", "line"]]
        let keys = ["shipments": [
            ForeignKeyInfo(name: "ship_line_fk", column: "order_id", referencedTable: "lines", referencedColumn: "order_id"),
            ForeignKeyInfo(name: "ship_line_fk", column: "line", referencedTable: "lines", referencedColumn: "line")
        ]]

        let graph = Self.graph(columns: columns, foreignKeys: keys)

        #expect(graph.relationships.count == 1)
        let relationship = try #require(graph.relationships.first)
        #expect(relationship.columnPairs == [
            .init(child: "order_id", parent: "order_id"),
            .init(child: "line", parent: "line")
        ])
    }

    @Test("Two keys to the same table stay two relationships")
    func twoKeysToOneTable() {
        let columns = ["orders": ["billing_id", "shipping_id"], "addresses": ["id"]]
        let keys = ["orders": [
            ForeignKeyInfo(name: "billing_fk", column: "billing_id", referencedTable: "addresses", referencedColumn: "id"),
            ForeignKeyInfo(name: "shipping_fk", column: "shipping_id", referencedTable: "addresses", referencedColumn: "id")
        ]]

        let graph = Self.graph(columns: columns, foreignKeys: keys)

        #expect(graph.relationships(between: "orders", and: "addresses").map { $0.name } == ["billing_fk", "shipping_fk"])
    }

    @Test("A key into another schema never joins a same-named table of this one")
    func foreignScopeKeyIsDropped() {
        let keys = ["orders": [
            ForeignKeyInfo(
                name: "orders_customer_fk", column: "customer_id",
                referencedTable: "customers", referencedColumn: "id", referencedSchema: "billing"
            )
        ]]

        let graph = Self.graph(foreignKeys: keys, isLocal: { $0.referencedSchema == nil })

        #expect(graph.relationships.isEmpty)
        #expect(graph.path(to: "customers", from: ["orders"]) == nil)
    }

    @Test("A key spelled in another case than the catalog, as SQLite reports one, still links the tables")
    func referenceSpellingFollowsTheCatalog() throws {
        let columns = ["Parent": ["ID", "name"], "child": ["id", "Parent_Id"]]
        let keys = ["child": [
            ForeignKeyInfo(name: "fk_child_0", column: "parent_id", referencedTable: "parent", referencedColumn: "id")
        ]]

        let relationship = try #require(Self.graph(columns: columns, foreignKeys: keys).relationships.first)

        #expect(relationship.parentTable == "Parent")
        #expect(relationship.columnPairs == [.init(child: "Parent_Id", parent: "ID")])
    }

    @Test("An exact spelling wins over another table that differs only in case")
    func exactSpellingWins() throws {
        let columns = ["Parent": ["id"], "parent": ["id"], "child": ["parent_id"]]
        let keys = ["child": [
            ForeignKeyInfo(name: "fk", column: "parent_id", referencedTable: "parent", referencedColumn: "id")
        ]]

        let relationship = try #require(Self.graph(columns: columns, foreignKeys: keys).relationships.first)

        #expect(relationship.parentTable == "parent")
    }

    @Test("A self-referencing key is never offered as a join between two tables")
    func selfReferenceIsNotAJoin() {
        let columns = ["employees": ["id", "manager_id"], "teams": ["id"]]
        let keys = ["employees": [
            ForeignKeyInfo(name: "manager_fk", column: "manager_id", referencedTable: "employees", referencedColumn: "id")
        ]]

        let graph = Self.graph(columns: columns, foreignKeys: keys)

        #expect(graph.relationships(between: "employees", and: "employees").isEmpty)
        #expect(graph.path(to: "teams", from: ["employees"]) == nil)
    }
}
