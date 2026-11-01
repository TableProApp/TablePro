import Foundation
@testable import TablePro
import Testing

struct ExternalStatementGatePrivateRequestTests {
    private func statement(
        _ sql: String,
        databaseType: DatabaseType,
        externalAccess: ExternalAccessLevel = .readWrite
    ) -> ExternalStatementGate.Statement {
        ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: externalAccess,
            loadsExtensions: false,
            allowsDestructive: false,
            destructiveAlternative: "Use confirm_destructive_operation for it."
        )
    }

    private func refusal(_ statement: ExternalStatementGate.Statement) -> ExternalStatementGateError? {
        do {
            _ = try ExternalStatementGate.classify(statement)
            return nil
        } catch let error as ExternalStatementGateError {
            return error
        } catch {
            return nil
        }
    }

    private func expectRefusedAsPrivate(_ sql: String, on databaseType: DatabaseType, access: ExternalAccessLevel = .readWrite) {
        guard let message = ExternalStatementGate.privateRequestRefusal(sql: sql) else {
            Issue.record("Not refused: \(sql)")
            return
        }
        let error = refusal(statement(sql, databaseType: databaseType, externalAccess: access))
        #expect(error == ExternalStatementGateError.denied(message))
    }

    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private static let bigQueryPage = #"{"table":"orders","dataset":"shop","limit":1,"offset":0,"#
        + #""filters":[{"column":"__RAW__","op":"=","value":"TRUE)); DROP TABLE shop.orders; SELECT ((1"}]}"#

    // BigQuery renders this page as `WHERE ((TRUE)); DROP TABLE shop.orders; SELECT ((1))` and posts it as one job.
    @Test("A BigQuery page with a raw filter is refused, whole, behind a semicolon or behind EXPLAIN", arguments: [
        "BIGQUERY_BROWSE:", "BIGQUERY_FILTER:", "BIGQUERY_SEARCH:", "BIGQUERY_COMBINED:",
    ], ["", " \n", ";", "EXPLAIN "])
    func bigQueryPageRefused(tag: String, lead: String) {
        expectRefusedAsPrivate(lead + tag + Self.base64(Self.bigQueryPage), on: .bigQuery)
    }

    @Test("An Elasticsearch or Typesense write envelope is refused", arguments: [
        (DatabaseType.elasticsearch, "ELASTICSEARCH_WRITE:REVMRVRF:L29yZGVycw==:"),
        (.elasticsearch, "ELASTICSEARCH_WRITE:UFVU:L19zY3JpcHRzL3plcm8=:"
            + base64(#"{"script":{"lang":"painless","source":"ctx._source.total = 0"}}"#)),
        (.typesense, "TYPESENSE_WRITE:REVMRVRF:L2NvbGxlY3Rpb25zL2Jvb2tz:"),
        (.typesense, "TYPESENSE_WRITE:UE9TVA==:L2tleXM=:"
            + base64(#"{"actions": ["*"], "collections": ["*"], "value": "chosen-by-the-client"}"#)),
    ])
    func writeEnvelopeRefused(databaseType: DatabaseType, envelope: String) {
        expectRefusedAsPrivate(envelope, on: databaseType)
    }

    @Test("Every driver's private request is refused on its engine", arguments: [
        (DatabaseType.spanner, "SPANNER_BROWSE:"),
        (.elasticsearch, "ELASTICSEARCH_SEARCH:"),
        (.elasticsearch, "ELASTICSEARCH_EXPORT:"),
        (.typesense, "TYPESENSE_SEARCH:"),
        (.typesense, "TYPESENSE_EXPORT:"),
        (.weaviate, "WEAVIATE_SEARCH:"),
        (.weaviate, "WEAVIATE_WRITE:"),
        (.weaviate, "WEAVIATE_EXPORT:"),
        (.memcached, "MEMCACHED_BROWSE:"),
        (.memcached, "MEMCACHED_REFUSAL:"),
        (.etcd, "ETCD_RANGE:"),
        (.etcd, "ETCD_COUNT:"),
        (.etcd, "ETCD_REFUSAL:"),
        (.firestore, "FIREBASE_BROWSE:"),
        (.firebaseRealtimeDatabase, "FIREBASE_BROWSE:"),
        (.bigtable, "BIGTABLE_BROWSE:"),
    ])
    func privateRequestRefused(databaseType: DatabaseType, tag: String) {
        expectRefusedAsPrivate(tag + Self.base64(#"{"collection":"orders"}"#), on: databaseType)
    }

    // The driver ends the header at the second `*/` and runs the DROP after it; the gates read a SELECT.
    @Test("A forged Cassandra browse header is refused on a read-only connection", arguments: [
        DatabaseType.cassandra, .scylladb,
    ], [
        "/* TablePro browse {\"offset\":0,\"limit\":1,\"values\":[],\"note\":\"*/\u{FE0F} SELECT key FROM system.local -- \"} */ DROP TABLE shop.orders",
        "/* TablePro browse {\"offset\":0,\"limit\":10,\"values\":[]} */ SELECT key FROM system.local",
    ])
    func cassandraBrowseHeaderRefused(databaseType: DatabaseType, sql: String) {
        expectRefusedAsPrivate(sql, on: databaseType, access: .readOnly)
    }

    // Spanner's EXPLAIN option parser ends the quote where the gate does not, then decodes the tag after it.
    @Test("A tag a quote hides from the gate is refused all the same", arguments: [
        (DatabaseType.spanner, "EXPLAIN (') SPANNER_BROWSE:"),
        (.bigQuery, "SELECT 'BIGQUERY_FILTER:"),
        (.cassandra, "SELECT '/* TablePro browse "),
    ])
    func quotedTagRefused(databaseType: DatabaseType, lead: String) {
        expectRefusedAsPrivate(lead + Self.base64(#"{"table":"orders"}"#), on: databaseType)
    }

    @Test("A statement that only resembles a private request passes", arguments: [
        (DatabaseType.bigQuery, "SELECT 'bigquery_filter:e30=' AS tag"),
        (.spanner, "SELECT 1 AS SPANNER_BROWSE"),
        (.cassandra, "/* TablePro */ SELECT key FROM system.local"),
        (.cassandra, "/* TablePro browsing */ SELECT key FROM system.local"),
        (.elasticsearch, "GET /orders/_search"),
    ])
    func lookalikePasses(databaseType: DatabaseType, sql: String) throws {
        #expect(ExternalStatementGate.privateRequestRefusal(sql: sql) == nil)
        #expect(try ExternalStatementGate.classify(statement(sql, databaseType: databaseType)).tier == .safe)
    }
}
