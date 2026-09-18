import Foundation
import Testing

@testable import TableProSpannerCore

@Suite("SpannerAPIError")
struct SpannerAPIErrorTests {
    private static let emulatorSessionNotFound = """
    {"code":5,"message":"Session not found: projects/proj/instances/inst/databases/gdb/sessions/nope",\
    "details":[{"@type":"type.googleapis.com/google.rpc.ResourceInfo",\
    "resourceType":"type.googleapis.com/google.spanner.v1.Session",\
    "resourceName":"projects/proj/instances/inst/databases/gdb/sessions/nope","description":"Session does not exist."}]}
    """

    private static let emulatorDatabaseNotFound = """
    {"code":5,"message":"Database not found: projects/proj/instances/inst/databases/nodb",\
    "details":[{"@type":"type.googleapis.com/google.rpc.ResourceInfo",\
    "resourceType":"type.googleapis.com/google.spanner.admin.database.v1.Database",\
    "resourceName":"projects/proj/instances/inst/databases/nodb","description":"Database does not exist."}]}
    """

    private static let productionSessionNotFound = """
    {"error":{"code":404,"message":"Session not found: projects/p/instances/i/databases/d/sessions/abc",\
    "status":"NOT_FOUND","details":[{"@type":"type.googleapis.com/google.rpc.ResourceInfo",\
    "resourceType":"type.googleapis.com/google.spanner.v1.Session","resourceName":"projects/p/instances/i/databases/d/sessions/abc"}]}}
    """

    private func decode(_ body: String, status: Int) -> SpannerAPIError {
        SpannerAPIError.decode(httpStatus: status, body: Data(body.utf8))
    }

    @Test("The emulator's top-level Status decodes with its gRPC code and resource type")
    func emulatorShape() {
        let error = decode(Self.emulatorSessionNotFound, status: 404)
        #expect(error.httpStatus == 404)
        #expect(error.code == 5)
        #expect(error.status == nil)
        #expect(error.message.hasPrefix("Session not found: projects/proj"))
        #expect(error.resourceTypes == ["type.googleapis.com/google.spanner.v1.Session"])
        #expect(error.isNotFound)
        #expect(error.isSessionNotFound)
    }

    @Test("A missing database is not a lost session")
    func databaseNotFound() {
        let error = decode(Self.emulatorDatabaseNotFound, status: 404)
        #expect(error.isNotFound)
        #expect(!error.isSessionNotFound)
        #expect(error.resourceTypes == ["type.googleapis.com/google.spanner.admin.database.v1.Database"])
    }

    @Test("The production error wrapper decodes status name and HTTP code")
    func productionShape() {
        let error = decode(Self.productionSessionNotFound, status: 404)
        #expect(error.code == 404)
        #expect(error.status == "NOT_FOUND")
        #expect(error.isNotFound)
        #expect(error.isSessionNotFound)
    }

    @Test("Session loss without details falls back to the message prefix")
    func sessionNotFoundByMessage() {
        let error = decode(#"{"error":{"code":404,"message":"Session not found: x","status":"NOT_FOUND"}}"#, status: 404)
        #expect(error.isSessionNotFound)
        let other = decode(#"{"code":5,"message":"Table not found: Singers"}"#, status: 404)
        #expect(!other.isSessionNotFound)
    }

    @Test("A streaming error array takes its first Status")
    func arrayShape() {
        let error = decode(#"[{"error":{"code":400,"message":"Syntax error","status":"INVALID_ARGUMENT"}}]"#, status: 400)
        #expect(error.isInvalidArgument)
        #expect(error.message == "Syntax error")
    }

    @Test("An in-stream error without a status name still classifies by gRPC code")
    func emulatorStreamError() {
        let error = decode(#"{"error":{"code":11,"message":"division by zero: 1 / 0"}}"#, status: 400)
        #expect(error.code == 11)
        #expect(error.message == "division by zero: 1 / 0")
        #expect(!error.isInvalidArgument)
    }

    @Test("A body that is not a Status keeps only the HTTP status", arguments: ["", "<html>oops</html>", "[]", #"{"foo":1}"#])
    func unparsableBody(body: String) {
        let error = decode(body, status: 502)
        #expect(error.message == "HTTP 502")
        #expect(error.code == nil)
        #expect(error.status == nil)
        #expect(error.resourceTypes.isEmpty)
    }

    @Test("An empty message falls back to the HTTP status")
    func emptyMessage() {
        let error = decode(#"{"code":13,"message":""}"#, status: 500)
        #expect(error.message == "HTTP 500")
        #expect(error.code == 13)
    }

    @Test("Classification by gRPC code, status name and HTTP status")
    func classification() {
        #expect(decode(#"{"code":10,"message":"Transaction aborted"}"#, status: 409).isAborted)
        #expect(decode(#"{"error":{"code":409,"message":"x","status":"ABORTED"}}"#, status: 409).isAborted)
        #expect(decode(#"{"code":14,"message":"x"}"#, status: 500).isUnavailable)
        #expect(decode("", status: 503).isUnavailable)
        #expect(decode(#"{"code":16,"message":"x"}"#, status: 500).isUnauthenticated)
        #expect(decode("", status: 401).isUnauthenticated)
        #expect(decode(#"{"error":{"code":403,"message":"x","status":"PERMISSION_DENIED"}}"#, status: 403).isPermissionDenied)
        #expect(decode("", status: 403).isPermissionDenied)
        #expect(decode(#"{"code":3,"message":"x"}"#, status: 400).isInvalidArgument)
        let exhausted = decode(#"{"error":{"code":429,"message":"x","status":"RESOURCE_EXHAUSTED"}}"#, status: 429)
        #expect(!exhausted.isUnavailable)
        #expect(!exhausted.isAborted)
    }
}
