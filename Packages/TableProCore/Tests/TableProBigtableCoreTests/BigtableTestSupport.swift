import Foundation
import TableProGoogleCloud

func b64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

func json(_ text: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [String: Any]()
}

func jsonText(_ object: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
}

final class RecordingTransport: GoogleRESTTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [GoogleRESTRequest] = []
    private let reply: @Sendable (GoogleRESTRequest) -> GoogleRESTResponse

    init(reply: @escaping @Sendable (GoogleRESTRequest) -> GoogleRESTResponse) {
        self.reply = reply
    }

    var requests: [GoogleRESTRequest] {
        lock.withLock { sent }
    }

    func send(_ request: GoogleRESTRequest) async throws -> GoogleRESTResponse {
        lock.withLock { sent.append(request) }
        return reply(request)
    }

    func cancelAll() {}
}

extension GoogleRESTRequest {
    var path: String {
        url.path
    }

    var jsonBody: [String: Any] {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}
