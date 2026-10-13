import Foundation
@testable import TableProFirebaseCore
import Testing

@Suite("Firebase connection settings")
struct FirebaseSettingsTests {
    @Test("Firestore takes the project from the credential when the field is empty")
    func projectFromCredential() throws {
        let settings = try FirebaseConnectionSettings.parse(fields: ["fbAuthMethod": "serviceAccount"], credentialProject: "my-app")
        #expect(settings.variant == .firestore)
        #expect(settings.projectId == "my-app")
        #expect(settings.firestoreDatabase == "(default)")
        #expect(settings.firestoreBaseURL?.absoluteString == "https://firestore.googleapis.com/v1/")
    }

    @Test("The field wins over the credential, and a project is required for Firestore")
    func projectRequired() throws {
        let explicit = try FirebaseConnectionSettings.parse(fields: ["fbProjectId": "other-app"], credentialProject: "my-app")
        #expect(explicit.projectId == "other-app")
        #expect(throws: FirebaseError.self) { try FirebaseConnectionSettings.parse(fields: [:]) }
        #expect(throws: FirebaseError.self) { try FirebaseConnectionSettings.parse(fields: ["fbProjectId": "Bad Project"]) }
    }

    @Test("The Realtime Database variant needs a URL or a project")
    func realtimeDatabase() throws {
        let fields = ["driverVariant": "realtimeDatabase", "fbDatabaseURL": "https://chat-1.europe-west1.firebasedatabase.app/x"]
        let settings = try FirebaseConnectionSettings.parse(fields: fields)
        #expect(settings.variant == .realtimeDatabase)
        #expect(settings.defaultDatabaseURL?.absoluteString == "https://chat-1.europe-west1.firebasedatabase.app/")
        let fromProject = try FirebaseConnectionSettings.parse(fields: ["driverVariant": "realtimeDatabase", "fbProjectId": "my-app"])
        #expect(fromProject.defaultDatabaseURL?.absoluteString == "https://my-app-default-rtdb.firebaseio.com/")
        #expect(throws: FirebaseError.self) { try FirebaseConnectionSettings.parse(fields: ["driverVariant": "realtimeDatabase"]) }
    }

    @Test("A token is never sent to a host that is not Firebase's")
    func untrustedURL() {
        for url in ["http://chat.firebaseio.com", "https://evil.example.com", "https://firebaseio.com.evil.io/", "nonsense"] {
            #expect(throws: FirebaseError.self) {
                try FirebaseConnectionSettings.parse(fields: ["driverVariant": "realtimeDatabase", "fbDatabaseURL": url])
            }
        }
    }

    @Test("The emulator takes host:port and plain HTTP")
    func emulator() throws {
        let firestore = try FirebaseConnectionSettings.parse(fields: [
            "fbAuthMethod": "emulator", "fbProjectId": "demo-app", "fbEmulatorHost": "http://127.0.0.1:8080/"
        ])
        #expect(firestore.firestoreBaseURL?.absoluteString == "http://127.0.0.1:8080/v1/")
        let database = try FirebaseConnectionSettings.parse(fields: [
            "driverVariant": "realtimeDatabase", "fbAuthMethod": "emulator", "fbProjectId": "demo-app", "fbEmulatorHost": "localhost:9000"
        ])
        #expect(database.defaultDatabaseURL?.absoluteString == "http://localhost:9000/?ns=demo-app-default-rtdb")
        #expect(throws: FirebaseError.self) {
            try FirebaseConnectionSettings.parse(fields: ["fbAuthMethod": "emulator", "fbProjectId": "demo-app", "fbEmulatorHost": "localhost"])
        }
    }
}

@Suite("Firebase statements")
struct FirebaseStatementTests {
    @Test("A browse spec survives the statement text")
    func browse() throws {
        let spec = FirebaseBrowseSpec(table: "users", filters: [FirebaseFilterSpec(column: "a", op: "=", value: "1")], limit: 10, offset: 20)
        #expect(try FirebaseStatement.parse(FirebaseStatement.encode(spec)) == .browse(spec))
        #expect(throws: FirebaseError.self) { try FirebaseStatement.parse("FIREBASE_BROWSE:not-base64!") }
    }

    @Test("Request lines read verb, path, query and body")
    func requests() throws {
        let patch = try FirebaseRequest.parse(#"patch /users/alice?updateMask=age,name {"age": 31}"#)
        #expect(patch.method == .patch)
        #expect(patch.path == "users/alice")
        #expect(patch.queryValue("updateMask") == "age,name")
        #expect(patch.body == #"{"age": 31}"#)
        let multiline = try FirebaseRequest.parse("PUT /config/maintenance\nfalse")
        #expect(multiline.body == "false")
        let query = try FirebaseRequest.parse(#"QUERY {"structuredQuery": {}}"#)
        #expect(query.path.isEmpty && query.body == #"{"structuredQuery": {}}"#)
        let scoped = try FirebaseRequest.parse(#"QUERY users/alice {"structuredQuery": {}}"#)
        #expect(scoped.path == "users/alice")
        #expect(try FirebaseRequest.parse("GET /").path.isEmpty)
    }

    @Test("Malformed requests explain the syntax")
    func malformed() {
        #expect(throws: FirebaseError.self) { try FirebaseRequest.parse("SELECT * FROM users") }
        #expect(throws: FirebaseError.self) { try FirebaseRequest.parse("PATCH users/alice") }
        #expect(throws: FirebaseError.self) { try FirebaseRequest.parse("QUERY users") }
    }

    @Test("The request text reads back as the same request")
    func text() throws {
        let request = FirebaseRequest(method: .patch, path: "users/alice", query: [URLQueryItem(name: "updateMask", value: "age")], body: #"{"age":31}"#)
        #expect(request.text == #"PATCH users/alice?updateMask=age {"age":31}"#)
        #expect(try FirebaseRequest.parse(request.text) == request)
    }

    @Test("An ID with a space, & or = reads back whole, and the rest of the line stays readable")
    func escapedText() throws {
        let delete = FirebaseRequest(method: .delete, path: "chats/John Smith")
        #expect(delete.text == "DELETE chats/John%20Smith")
        #expect(try FirebaseRequest.parse(delete.text) == delete)

        let post = FirebaseRequest(method: .post, path: "users",
                                   query: [URLQueryItem(name: "documentId", value: "a&b=c #1 50%")], body: #"{"n":1}"#)
        #expect(post.text == #"POST users?documentId=a%26b%3Dc%20%231%2050%25 {"n":1}"#)
        #expect(try FirebaseRequest.parse(post.text) == post)

        let unicode = FirebaseRequest(method: .get, path: "người/uid:1")
        #expect(unicode.text == "GET người/uid:1")
        #expect(try FirebaseRequest.parse(unicode.text) == unicode)
    }

    @Test("An update mask quotes a field name that holds a comma or a backtick")
    func mask() {
        let text = FirestoreQueryBuilder.maskText(["age", "a,b", "x`y", "first name"])
        #expect(text == #"age,`a,b`,`x\`y`,`first name`"#)
        #expect(FirestoreQueryBuilder.maskFields(text) == ["age", "a,b", "x`y", "first name"])
        #expect(FirestoreQueryBuilder.maskFields(" age , name ") == ["age", "name"])
    }
}
