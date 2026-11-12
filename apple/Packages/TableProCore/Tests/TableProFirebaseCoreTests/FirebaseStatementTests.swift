import Foundation
@testable import TableProFirebaseClient
@testable import TableProFirebaseCore
import TableProGoogleCloud
import Testing

private func scalars(_ text: String?) -> [UInt32] {
    (text ?? "").unicodeScalars.map(\.value)
}

private func scalars(_ items: [URLQueryItem]) -> [[UInt32]] {
    items.flatMap { [scalars($0.name), scalars($0.value)] }
}

private struct UnusedTransport: GoogleRESTTransport {
    func send(_ request: GoogleRESTRequest) async throws -> GoogleRESTResponse {
        GoogleRESTResponse(statusCode: 500, body: Data())
    }

    func cancelAll() {}
}

// A mark that starts a name joins the separator before it into one Character.
private let leadingNames = [
    "\u{FE0F}general",
    "\u{E0100}general",
    "\u{0301}users",
    "\u{034F}general",
    "\u{0903}general",
    "\u{1F3FB}general",
    "\u{200D}general",
    "\u{FEFF}general",
    "\u{0600}general",
    "general\u{0600}",
    "\u{0301}"
]

struct FirebaseStatementTests {
    @Test("A request line reads back as the request it was written from", arguments: [
        FirebaseRequest(method: .delete, path: "users/alice"),
        FirebaseRequest(method: .delete, path: "a b/c&d=e?f#g%h"),
        FirebaseRequest(method: .delete, path: ""),
        FirebaseRequest(method: .patch, path: "\u{FE0F}general", body: #"{"m1":null}"#),
        FirebaseRequest(method: .put, path: "\u{FE0F}general", body: "1"),
        FirebaseRequest(method: .put, path: "\u{0301}", body: "null"),
        FirebaseRequest(method: .post, path: "users", query: [URLQueryItem(name: "documentId", value: "\u{0301}x")], body: "{}"),
        FirebaseRequest(method: .get, path: "users", query: [
            URLQueryItem(name: "\u{FE0F}a", value: "\u{0301}1"),
            URLQueryItem(name: "b", value: "\u{FEFF}2")
        ]),
        FirebaseRequest(method: .query, path: "", body: #"{"structuredQuery": {}}"#),
        FirebaseRequest(method: .query, path: "{rooms", body: #"{"structuredQuery": {}}"#),
        FirebaseRequest(method: .query, path: "{\u{0301}rooms/alice", body: #"{"structuredQuery": {}}"#)
    ])
    func roundTrip(request: FirebaseRequest) throws {
        let parsed = try FirebaseRequest.parse(request.text)
        #expect(parsed == request)
        #expect(scalars(parsed.path) == scalars(request.path))
        #expect(scalars(parsed.query) == scalars(request.query))
    }

    @Test("A name that starts with a mark or a prepend character keeps it through the request line", arguments: leadingNames)
    func leadingMarksRoundTrip(name: String) throws {
        for path in [name, "rooms/" + name, name + "/m1", "users/" + name + "/orders/" + name] {
            for method in [FirebaseRequest.Method.delete, .get] {
                let request = FirebaseRequest(method: method, path: path)
                let parsed = try FirebaseRequest.parse(request.text)
                #expect(scalars(parsed.path) == scalars(request.path), "\(request.text)")
                #expect(parsed.method == method)
            }
            let edit = FirebaseRequest(method: .patch, path: path, query: [URLQueryItem(name: "updateMask", value: name)], body: "{}")
            let parsedEdit = try FirebaseRequest.parse(edit.text)
            #expect(scalars(parsedEdit.path) == scalars(edit.path))
            #expect(scalars(parsedEdit.queryValue("updateMask")) == scalars(name))
            #expect(parsedEdit.body == "{}")
        }
    }

    @Test("A typed line keeps a mark that follows the space after the verb")
    func typedLineKeepsTheMark() throws {
        #expect(scalars(try FirebaseRequest.parse("DELETE \u{FE0F}general").path) == scalars("\u{FE0F}general"))
        #expect(scalars(try FirebaseRequest.parse("PUT \u{FE0F} null").path) == scalars("\u{FE0F}"))
        #expect(try FirebaseRequest.parse("PUT \u{FE0F} null").body == "null")
        #expect(scalars(try FirebaseRequest.parse("PUT users\u{0600} null").path) == scalars("users\u{0600}"))
        #expect(try FirebaseRequest.parse("PUT users\r\nnull").body == "null")
    }

    @Test("Text that is not a valid escape is kept as typed")
    func malformedEscapesStay() throws {
        #expect(try FirebaseRequest.parse("DELETE 100%off").path == "100%off")
        #expect(try FirebaseRequest.parse("DELETE a%FFb").path == "a%FFb")
        #expect(try FirebaseRequest.parse("DELETE a%2").path == "a%2")
        #expect(try FirebaseRequest.parse("DELETE a%2fb").path == "a/b")
    }

    @Test("Paths split at every slash, whatever follows it", arguments: leadingNames)
    func pathsSplitPerScalar(name: String) throws {
        #expect(scalars(RealtimeDatabasePath.normalized("/rooms/" + name + "/")) == scalars("rooms/" + name))
        #expect(scalars(RealtimeDatabasePath.join("rooms", name)) == scalars("rooms/" + name))
        #expect(FirestorePath.isDocument("users/" + name))
        #expect(!FirestorePath.isDocument(name + "/a/" + name))
        #expect(scalars(FirestorePath.lastSegment("users/" + name)) == scalars(name))
        let split = FirestorePath.split(collectionPath: "users/" + name + "/" + name)
        #expect(scalars(split.parent) == scalars("users/" + name))
        #expect(scalars(split.collectionId) == scalars(name))
        let root = "projects/p/databases/(default)/documents"
        #expect(scalars(FirestorePath.relative(root + "/" + name + "/a", documentRoot: root)) == scalars(name + "/a"))
        #expect(scalars(FirestorePath.absolute(name + "/a", documentRoot: root)) == scalars(root + "/" + name + "/a"))
        #expect(throws: FirebaseError.self) { try RealtimeDatabasePath.validateKey("a/" + name) }
    }

    @Test("A collection whose ID starts with a mark opens as its own target", arguments: leadingNames)
    func collectionTargets(name: String) throws {
        let group = try FirestoreCollectionTarget(table: FirestoreCollectionTarget.groupName(name))
        #expect(group.isGroup)
        #expect(scalars(group.collectionId) == scalars(name))
        let nested = try FirestoreCollectionTarget(table: "users/a/" + name)
        #expect(!nested.isGroup)
        #expect(scalars(nested.parentPath) == scalars("users/a"))
        #expect(scalars(nested.documentPath(forRowName: name)) == scalars("users/a/" + name + "/" + name))
        #expect(scalars(nested.documentPath(forRowName: "users/" + name)) == scalars("users/" + name))
        #expect(scalars(FirebaseFilterSpec(column: "c", op: "BETWEEN", value: "a," + name).betweenBounds?.upper) == scalars(name))
    }

    @Test("An IN list splits at every comma, whatever follows it")
    func listItemsSplitPerScalar() {
        #expect(FirestoreQueryBuilder.listItems("alice,\u{0301}bob, \u{FE0F}carol").map { scalars($0) }
            == ["alice", "\u{0301}bob", "\u{FE0F}carol"].map { scalars($0) })
    }

    @Test("An update mask reads back as the fields it was written from")
    func maskRoundTrip() {
        let fields = leadingNames + ["age", "a,b", "`x`", "\\"]
        let parsed = FirestoreQueryBuilder.maskFields(FirestoreQueryBuilder.maskText(fields))
        #expect(parsed.map { scalars($0) } == fields.map { scalars($0) })
    }

    @Test("The URL a request goes to keeps a leading mark in its own segment")
    func requestURLs() throws {
        let database = RealtimeDatabaseClient(
            instanceURL: try #require(URL(string: "https://demo.firebaseio.com/")),
            transport: UnusedTransport(), credential: .firebaseEmulator, timeout: { 1 }
        )
        #expect(try database.url("\u{FE0F}general").path(percentEncoded: true) == "/%EF%B8%8Fgeneral.json")
        #expect(try database.url("rooms/\u{FE0F}general").path(percentEncoded: true) == "/rooms/%EF%B8%8Fgeneral.json")
        let firestore = FirestoreClient(
            projectId: "p", database: "(default)", baseURL: try #require(URL(string: "https://firestore.googleapis.com/v1/")),
            transport: UnusedTransport(), credential: .firebaseEmulator, timeout: { 1 }
        )
        #expect(firestore.documentName("users/\u{0301}alice").hasSuffix("/documents/users/%CC%81alice"))
    }
}
