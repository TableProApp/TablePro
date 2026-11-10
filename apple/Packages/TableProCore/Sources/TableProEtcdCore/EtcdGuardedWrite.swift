import Foundation

// A put replaces whatever the key holds, and a put followed by a delete is two requests. A
// transaction checks the keys and writes in one step: a new key only where none exists, and a
// rename only onto a free name and only while the source is still what was read.
public struct EtcdTxnRequest: Encodable, Equatable, Sendable {
    public struct Compare: Encodable, Equatable, Sendable {
        public let key: Data
        public let target: String
        public let result: String
        public var createRevision: String?
        public var modRevision: String?
        public var version: String?

        private enum CodingKeys: String, CodingKey {
            case key
            case target
            case result
            case createRevision = "create_revision"
            case modRevision = "mod_revision"
            case version
        }
    }

    public struct Put: Encodable, Equatable, Sendable {
        public let key: Data
        public let value: Data
        public var lease: String?
    }

    public struct DeleteRange: Encodable, Equatable, Sendable {
        public let key: Data
    }

    public struct Range: Encodable, Equatable, Sendable {
        public let key: Data
        public let countOnly: Bool

        private enum CodingKeys: String, CodingKey {
            case key
            case countOnly = "count_only"
        }
    }

    public struct Operation: Encodable, Equatable, Sendable {
        public var requestPut: Put?
        public var requestDeleteRange: DeleteRange?
        public var requestRange: Range?

        private enum CodingKeys: String, CodingKey {
            case requestPut = "request_put"
            case requestDeleteRange = "request_delete_range"
            case requestRange = "request_range"
        }
    }

    public let compare: [Compare]
    public let success: [Operation]
    public let failure: [Operation]

    public static func create(key: Data, value: Data, lease: Int64?) -> EtcdTxnRequest {
        EtcdTxnRequest(
            compare: [absent(key)],
            success: [Operation(requestPut: Put(key: key, value: value, lease: lease.map { String($0) }))],
            failure: [countOf(key)]
        )
    }

    // Without a revision to hold the source to, it only has to still exist.
    public static func move(
        from source: Data,
        to target: Data,
        value: Data,
        lease: Int64?,
        modRevision: Int64?
    ) -> EtcdTxnRequest {
        let sourceUnchanged = modRevision.map {
            Compare(key: source, target: "MOD", result: "EQUAL", modRevision: String($0))
        } ?? Compare(key: source, target: "VERSION", result: "GREATER", version: "0")
        return EtcdTxnRequest(
            compare: [absent(target), sourceUnchanged],
            success: [
                Operation(requestPut: Put(key: target, value: value, lease: lease.map { String($0) })),
                Operation(requestDeleteRange: DeleteRange(key: source))
            ],
            failure: [countOf(target)]
        )
    }

    private static func absent(_ key: Data) -> Compare {
        Compare(key: key, target: "CREATE", result: "EQUAL", createRevision: "0")
    }

    private static func countOf(_ key: Data) -> Operation {
        Operation(requestRange: Range(key: key, countOnly: true))
    }
}

public struct EtcdTxnResponse: Decodable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case applied
        case targetExists
        case sourceChanged
    }

    struct Header: Decodable, Sendable {
        let revision: String?
    }

    struct Response: Decodable, Sendable {
        struct RangeResult: Decodable, Sendable {
            let count: String?
        }

        let responseRange: RangeResult?

        private enum CodingKeys: String, CodingKey {
            case responseRange = "response_range"
        }
    }

    let header: Header?
    let succeeded: Bool?
    let responses: [Response]?

    public var revision: String? { header?.revision }

    // The failure branch counts the target key, which tells a taken name from a changed source.
    public var outcome: Outcome {
        if succeeded == true { return .applied }
        let targetCount = responses?.first?.responseRange?.count.flatMap { Int64($0) } ?? 0
        return targetCount > 0 ? .targetExists : .sourceChanged
    }
}
