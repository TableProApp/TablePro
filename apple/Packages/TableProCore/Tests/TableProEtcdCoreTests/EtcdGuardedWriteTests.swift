import Foundation
import Testing

@testable import TableProEtcdCore

struct EtcdGuardedWriteTests {
    private func json(_ request: EtcdTxnRequest) throws -> NSDictionary {
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private func outcome(_ body: String) throws -> EtcdTxnResponse.Outcome {
        try JSONDecoder().decode(EtcdTxnResponse.self, from: Data(body.utf8)).outcome
    }

    @Test("A new key is put only where no key exists")
    func createRequest() throws {
        let request = EtcdTxnRequest.create(key: Data("/app/b".utf8), value: Data("v".utf8), lease: 42)
        let expected: NSDictionary = [
            "compare": [
                ["key": base64("/app/b"), "target": "CREATE", "result": "EQUAL", "create_revision": "0"]
            ],
            "success": [["request_put": ["key": base64("/app/b"), "value": base64("v"), "lease": "42"]]],
            "failure": [["request_range": ["key": base64("/app/b"), "count_only": true]]]
        ]
        #expect(try json(request) == expected)
    }

    @Test("A rename puts the new key and deletes the old one in one transaction, guarded on both")
    func moveRequest() throws {
        let request = EtcdTxnRequest.move(
            from: Data("/app/a".utf8), to: Data("/app/b".utf8), value: Data("v".utf8), lease: nil, modRevision: 17
        )
        let expected: NSDictionary = [
            "compare": [
                ["key": base64("/app/b"), "target": "CREATE", "result": "EQUAL", "create_revision": "0"],
                ["key": base64("/app/a"), "target": "MOD", "result": "EQUAL", "mod_revision": "17"]
            ],
            "success": [
                ["request_put": ["key": base64("/app/b"), "value": base64("v")]],
                ["request_delete_range": ["key": base64("/app/a")]]
            ],
            "failure": [["request_range": ["key": base64("/app/b"), "count_only": true]]]
        ]
        #expect(try json(request) == expected)
    }

    @Test("A rename with no revision to compare still requires the source to exist")
    func moveWithoutRevision() throws {
        let request = EtcdTxnRequest.move(
            from: Data("a".utf8), to: Data("b".utf8), value: Data(), lease: nil, modRevision: nil
        )
        #expect(request.compare.last == EtcdTxnRequest.Compare(
            key: Data("a".utf8), target: "VERSION", result: "GREATER", version: "0"
        ))
    }

    @Test("A transaction that ran reports applied")
    func appliedOutcome() throws {
        #expect(try outcome(#"{"header":{"revision":"9"},"succeeded":true,"responses":[{"response_put":{}}]}"#) == .applied)
    }

    @Test("A failed transaction whose target key exists reports the taken name")
    func targetExistsOutcome() throws {
        #expect(try outcome(#"{"header":{"revision":"9"},"responses":[{"response_range":{"count":"1"}}]}"#) == .targetExists)
    }

    @Test("A failed transaction whose target key is free reports the changed source")
    func sourceChangedOutcome() throws {
        #expect(try outcome(#"{"header":{"revision":"9"},"responses":[{"response_range":{"header":{}}}]}"#) == .sourceChanged)
        #expect(try outcome(#"{"header":{"revision":"9"}}"#) == .sourceChanged)
    }
}
