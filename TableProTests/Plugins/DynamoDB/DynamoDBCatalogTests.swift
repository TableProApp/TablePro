import Foundation
import TableProPluginKit
import Testing

struct DynamoDBCatalogTests {
    private static let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let local = DynamoDBCatalog.Scope(endpoint: "http://localhost:8000", region: "us-east-1", identity: "local")
    private static let remote = DynamoDBCatalog.Scope(
        endpoint: "https://dynamodb.eu-west-1.amazonaws.com/", region: "eu-west-1", identity: "key:AKIDEXAMPLE"
    )

    private static func schema(_ name: String) throws -> DynamoDBTableSchema {
        let json = try DynamoDBJSON.parse(
            #"{"Table":{"TableName":"\#(name)","KeySchema":[{"AttributeName":"pk","KeyType":"HASH"}],"AttributeDefinitions":[{"AttributeName":"pk","AttributeType":"S"}]}}"#
        )
        return try DynamoDBTableSchema(describeTableResponse: json)
    }

    private static func point(_ requestIndex: Int, key: String? = nil, skip: Int = 0) -> DynamoDBResumePoint {
        DynamoDBResumePoint(requestIndex: requestIndex, startKey: key.map { ["pk": .string($0)] }, skip: skip)
    }

    private static func nearest(
        _ catalog: DynamoDBCatalog,
        table: String = "Orders",
        fingerprint: String = "scan",
        offset: Int,
        scope: DynamoDBCatalog.Scope = local
    ) -> DynamoDBResumePoint? {
        catalog.nearestResumePoint(table: table, fingerprint: fingerprint, atOrBefore: offset, in: scope)?.point
    }

    @Test("A stored schema is served until it is a minute old")
    func schemaLifetime() throws {
        let catalog = DynamoDBCatalog()
        let orders = try Self.schema("Orders")
        catalog.store(orders, in: Self.local, now: Self.fetchedAt)

        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt) == orders)
        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt.addingTimeInterval(59.9)) == orders)
        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt.addingTimeInterval(60)) == nil)
        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt.addingTimeInterval(3_600)) == nil)
    }

    @Test("Storing a schema again restarts its lifetime")
    func restoringRestartsLifetime() throws {
        let catalog = DynamoDBCatalog()
        let orders = try Self.schema("Orders")
        catalog.store(orders, in: Self.local, now: Self.fetchedAt)
        catalog.store(orders, in: Self.local, now: Self.fetchedAt.addingTimeInterval(50))

        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt.addingTimeInterval(100)) == orders)
    }

    @Test("A schema belongs to its own scope and table")
    func schemaIsolation() throws {
        let catalog = DynamoDBCatalog()
        catalog.store(try Self.schema("Orders"), in: Self.local, now: Self.fetchedAt)

        #expect(catalog.schema(for: "Orders", in: Self.remote, now: Self.fetchedAt) == nil)
        #expect(catalog.schema(for: "Customers", in: Self.local, now: Self.fetchedAt) == nil)
    }

    @Test("Cached schemas are listed by name for their scope only")
    func cachedSchemasByScope() throws {
        let catalog = DynamoDBCatalog()
        catalog.store(try Self.schema("Orders"), in: Self.local)
        catalog.store(try Self.schema("Customers"), in: Self.local)
        catalog.store(try Self.schema("Invoices"), in: Self.remote)

        #expect(catalog.cachedSchemas(in: Self.local).map(\.name) == ["Customers", "Orders"])
        #expect(catalog.cachedSchemas(in: Self.remote).map(\.name) == ["Invoices"])
    }

    @Test("Invalidating a table drops its schema and every resume point of it, and nothing else")
    func invalidateTable() throws {
        let catalog = DynamoDBCatalog()
        catalog.store(try Self.schema("Orders"), in: Self.local, now: Self.fetchedAt)
        catalog.store(try Self.schema("Customers"), in: Self.local, now: Self.fetchedAt)
        catalog.store(try Self.schema("Orders"), in: Self.remote, now: Self.fetchedAt)
        catalog.storeResumePoint(Self.point(0, key: "a"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "b"), table: "Orders", fingerprint: "query", offset: 100, in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "c"), table: "Customers", fingerprint: "scan", offset: 100, in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "d"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.remote)

        catalog.invalidate(table: "Orders", in: Self.local)

        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt) == nil)
        #expect(Self.nearest(catalog, fingerprint: "scan", offset: 100) == nil)
        #expect(Self.nearest(catalog, fingerprint: "query", offset: 100) == nil)
        #expect(catalog.schema(for: "Customers", in: Self.local, now: Self.fetchedAt)?.name == "Customers")
        #expect(catalog.schema(for: "Orders", in: Self.remote, now: Self.fetchedAt)?.name == "Orders")
        #expect(Self.nearest(catalog, table: "Customers", offset: 100) == Self.point(0, key: "c"))
        #expect(Self.nearest(catalog, offset: 100, scope: Self.remote) == Self.point(0, key: "d"))
    }

    @Test("Invalidating a table forgets the types seen in its items, and a write forgets only its read positions")
    func invalidateForgetsTypesButWritesKeepThem() throws {
        let catalog = DynamoDBCatalog()
        catalog.store(try Self.schema("Orders"), in: Self.local, now: Self.fetchedAt)
        catalog.mergeColumnTypes(["age": .number], for: "Orders", in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "a"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.local)

        catalog.forgetReadPositions(table: "Orders", in: Self.local)

        #expect(Self.nearest(catalog, fingerprint: "scan", offset: 100) == nil)
        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt) != nil)
        #expect(catalog.columnTypes(for: "Orders", in: Self.local) == ["age": .number])

        catalog.invalidate(table: "Orders", in: Self.local)

        #expect(catalog.columnTypes(for: "Orders", in: Self.local).isEmpty)
    }

    @Test("An invalidated table's fingerprints no longer count toward eviction")
    func invalidateTableFreesEvictionSlots() {
        let catalog = DynamoDBCatalog()
        let kept = DynamoDBCatalog.maximumFingerprints / 2
        for index in 0..<kept {
            catalog.storeResumePoint(Self.point(index), table: "Orders", fingerprint: "keep-\(index)", offset: 0, in: Self.local)
        }
        for index in 0..<(DynamoDBCatalog.maximumFingerprints - kept) {
            catalog.storeResumePoint(Self.point(index), table: "Scratch", fingerprint: "drop-\(index)", offset: 0, in: Self.local)
        }

        catalog.invalidate(table: "Scratch", in: Self.local)
        for index in 0..<(DynamoDBCatalog.maximumFingerprints - kept) {
            catalog.storeResumePoint(Self.point(index), table: "Other", fingerprint: "new-\(index)", offset: 0, in: Self.local)
        }

        #expect(Self.nearest(catalog, fingerprint: "keep-0", offset: 0) == Self.point(0))
    }

    @Test("The nearest resume point is the last one at or before the offset")
    func nearestAtOrBefore() throws {
        let catalog = DynamoDBCatalog()
        catalog.storeResumePoint(.start, table: "Orders", fingerprint: "scan", offset: 0, in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "k100"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.local)
        catalog.storeResumePoint(Self.point(1, key: "k200", skip: 3), table: "Orders", fingerprint: "scan", offset: 200, in: Self.local)

        let exact = try #require(catalog.nearestResumePoint(table: "Orders", fingerprint: "scan", atOrBefore: 200, in: Self.local))
        #expect(exact.offset == 200)
        #expect(exact.point == Self.point(1, key: "k200", skip: 3))

        let between = try #require(catalog.nearestResumePoint(table: "Orders", fingerprint: "scan", atOrBefore: 150, in: Self.local))
        #expect(between.offset == 100)
        #expect(between.point == Self.point(0, key: "k100"))

        let beyond = try #require(catalog.nearestResumePoint(table: "Orders", fingerprint: "scan", atOrBefore: 10_000, in: Self.local))
        #expect(beyond.offset == 200)

        let early = try #require(catalog.nearestResumePoint(table: "Orders", fingerprint: "scan", atOrBefore: 99, in: Self.local))
        #expect(early.offset == 0)
        #expect(early.point == .start)
    }

    @Test("No resume point is found before the first one stored")
    func nothingBeforeFirstPoint() {
        let catalog = DynamoDBCatalog()
        catalog.storeResumePoint(Self.point(0, key: "k100"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.local)

        #expect(Self.nearest(catalog, offset: 50) == nil)
        #expect(Self.nearest(catalog, fingerprint: "unknown", offset: 500) == nil)
    }

    @Test("Storing at an offset already stored replaces the point")
    func storingReplacesPoint() {
        let catalog = DynamoDBCatalog()
        catalog.storeResumePoint(Self.point(0, key: "old"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "new"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.local)

        #expect(Self.nearest(catalog, offset: 100) == Self.point(0, key: "new"))
    }

    @Test("Resume points are kept apart by table, fingerprint and scope")
    func resumePointIsolation() {
        let catalog = DynamoDBCatalog()
        catalog.storeResumePoint(Self.point(0, key: "scan"), table: "Orders", fingerprint: "scan", offset: 100, in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "query"), table: "Orders", fingerprint: "query", offset: 100, in: Self.local)
        catalog.storeResumePoint(Self.point(0, key: "customers"), table: "Customers", fingerprint: "scan", offset: 100, in: Self.local)

        #expect(Self.nearest(catalog, fingerprint: "scan", offset: 100) == Self.point(0, key: "scan"))
        #expect(Self.nearest(catalog, fingerprint: "query", offset: 100) == Self.point(0, key: "query"))
        #expect(Self.nearest(catalog, table: "Customers", offset: 100) == Self.point(0, key: "customers"))
        #expect(Self.nearest(catalog, table: "Customers", fingerprint: "query", offset: 100) == nil)
        #expect(Self.nearest(catalog, offset: 100, scope: Self.remote) == nil)
    }

    @Test("The oldest fingerprint is evicted once more than the maximum are stored")
    func fingerprintEviction() {
        let catalog = DynamoDBCatalog()
        let maximum = DynamoDBCatalog.maximumFingerprints
        for index in 0..<maximum {
            catalog.storeResumePoint(Self.point(index), table: "Orders", fingerprint: "f\(index)", offset: 0, in: Self.local)
        }
        #expect(Self.nearest(catalog, fingerprint: "f0", offset: 0) == Self.point(0))

        catalog.storeResumePoint(Self.point(maximum), table: "Orders", fingerprint: "f\(maximum)", offset: 0, in: Self.local)

        #expect(Self.nearest(catalog, fingerprint: "f0", offset: 0) == nil)
        #expect(Self.nearest(catalog, fingerprint: "f1", offset: 0) == Self.point(1))
        #expect(Self.nearest(catalog, fingerprint: "f\(maximum)", offset: 0) == Self.point(maximum))
    }

    @Test("Adding a point to a stored fingerprint does not evict anything")
    func existingFingerprintDoesNotEvict() {
        let catalog = DynamoDBCatalog()
        let maximum = DynamoDBCatalog.maximumFingerprints
        for index in 0..<maximum {
            catalog.storeResumePoint(Self.point(index), table: "Orders", fingerprint: "f\(index)", offset: 0, in: Self.local)
        }

        catalog.storeResumePoint(Self.point(0, key: "later"), table: "Orders", fingerprint: "f5", offset: 100, in: Self.local)

        #expect(Self.nearest(catalog, fingerprint: "f0", offset: 0) == Self.point(0))
        #expect(Self.nearest(catalog, fingerprint: "f5", offset: 100) == Self.point(0, key: "later"))
    }

    @Test("A fingerprint holds at most the maximum number of offsets, and a full one still updates its own")
    func resumePointLimitPerFingerprint() {
        let catalog = DynamoDBCatalog()
        let maximum = DynamoDBCatalog.maximumResumePoints
        for offset in 0..<maximum {
            catalog.storeResumePoint(Self.point(offset), table: "Orders", fingerprint: "scan", offset: offset, in: Self.local)
        }

        catalog.storeResumePoint(Self.point(-1), table: "Orders", fingerprint: "scan", offset: maximum + 10, in: Self.local)
        catalog.storeResumePoint(Self.point(-2), table: "Orders", fingerprint: "scan", offset: 7, in: Self.local)

        #expect(Self.nearest(catalog, offset: maximum + 10) == Self.point(maximum - 1))
        #expect(Self.nearest(catalog, offset: 7) == Self.point(-2))
    }

    @Test("Invalidating a scope clears only that scope")
    func invalidateAllIsScoped() throws {
        let catalog = DynamoDBCatalog()
        for scope in [Self.local, Self.remote] {
            catalog.store(try Self.schema("Orders"), in: scope, now: Self.fetchedAt)
            catalog.mergeColumnTypes(["status": .string], for: "Orders", in: scope)
            catalog.storeResumePoint(Self.point(0, key: "a"), table: "Orders", fingerprint: "scan", offset: 100, in: scope)
        }

        catalog.invalidateAll(in: Self.local)

        #expect(catalog.schema(for: "Orders", in: Self.local, now: Self.fetchedAt) == nil)
        #expect(catalog.cachedSchemas(in: Self.local).isEmpty)
        #expect(catalog.columnTypes(for: "Orders", in: Self.local).isEmpty)
        #expect(Self.nearest(catalog, offset: 100) == nil)
        #expect(catalog.schema(for: "Orders", in: Self.remote, now: Self.fetchedAt)?.name == "Orders")
        #expect(catalog.columnTypes(for: "Orders", in: Self.remote) == ["status": .string])
        #expect(Self.nearest(catalog, offset: 100, scope: Self.remote) == Self.point(0, key: "a"))
    }

    @Test("An invalidated scope's fingerprints no longer count toward eviction")
    func invalidateAllFreesEvictionSlots() {
        let catalog = DynamoDBCatalog()
        let maximum = DynamoDBCatalog.maximumFingerprints
        catalog.storeResumePoint(Self.point(0), table: "Orders", fingerprint: "kept", offset: 0, in: Self.remote)
        for index in 0..<(maximum - 1) {
            catalog.storeResumePoint(Self.point(index), table: "Orders", fingerprint: "old-\(index)", offset: 0, in: Self.local)
        }

        catalog.invalidateAll(in: Self.local)
        for index in 0..<(maximum - 1) {
            catalog.storeResumePoint(Self.point(index), table: "Orders", fingerprint: "new-\(index)", offset: 0, in: Self.local)
        }

        #expect(Self.nearest(catalog, fingerprint: "kept", offset: 0, scope: Self.remote) == Self.point(0))
    }

    @Test("Merged column types keep old attributes and take the newest type for each")
    func mergeColumnTypes() {
        let catalog = DynamoDBCatalog()
        catalog.mergeColumnTypes(["status": .string, "total": .number], for: "Orders", in: Self.local)
        catalog.mergeColumnTypes(["total": .string, "tags": .stringSet], for: "Orders", in: Self.local)

        #expect(catalog.columnTypes(for: "Orders", in: Self.local) == [
            "status": .string, "total": .string, "tags": .stringSet
        ])
    }

    @Test("Column types are kept apart by table and scope, and an empty merge stores nothing")
    func columnTypeIsolation() {
        let catalog = DynamoDBCatalog()
        catalog.mergeColumnTypes(["status": .string], for: "Orders", in: Self.local)
        catalog.mergeColumnTypes([:], for: "Customers", in: Self.local)

        #expect(catalog.columnTypes(for: "Customers", in: Self.local).isEmpty)
        #expect(catalog.columnTypes(for: "Orders", in: Self.remote).isEmpty)
        #expect(catalog.columnTypes(for: "Orders", in: Self.local) == ["status": .string])
    }
}
