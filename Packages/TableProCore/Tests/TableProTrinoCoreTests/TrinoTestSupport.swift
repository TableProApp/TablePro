import Foundation
@testable import TableProTrinoCore

final class StubTransport: TrinoTransport, @unchecked Sendable {
    struct Canned {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var queue: [Canned]
    private var recorded: [TrinoHTTPRequest] = []
    private var cancelAllCalls = 0
    var onSend: ((TrinoHTTPRequest, Int) -> Void)?

    init(_ responses: [Canned]) {
        self.queue = responses
    }

    var requests: [TrinoHTTPRequest] {
        lock.withLock { recorded }
    }

    var cancelAllCount: Int {
        lock.withLock { cancelAllCalls }
    }

    func cancelAll() {
        lock.withLock { cancelAllCalls += 1 }
    }

    func send(_ request: TrinoHTTPRequest) async throws -> TrinoHTTPResponse {
        let index = lock.withLock { () -> Int in
            recorded.append(request)
            return recorded.count - 1
        }
        onSend?(request, index)
        let canned = lock.withLock { () -> Canned in
            guard !queue.isEmpty else {
                return Canned(statusCode: 200, headers: [:], body: Data(#"{"id":"empty"}"#.utf8))
            }
            return queue.removeFirst()
        }
        return TrinoHTTPResponse(
            statusCode: canned.statusCode,
            headers: TrinoHeaderFields(canned.headers),
            body: canned.body
        )
    }
}

func canned(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> StubTransport.Canned {
    StubTransport.Canned(statusCode: status, headers: headers, body: Data(json.utf8))
}

/// Hands the client to an `onSend` hook that runs on whatever thread the transport was resumed on.
///
/// The store has to be locked. Without one, the write on the test's thread and the read inside
/// `send` are an unsynchronized race, and a read that comes back nil skips the `cancel()` the test
/// exists to make: `testCancelStopsPolling` then failed with "Expected cancellation" on CI alone.
final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TrinoStatementClient?

    var client: TrinoStatementClient? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
