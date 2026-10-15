import Foundation
import TableProGoogleCloud

public extension GoogleRESTResponse {
    func json() throws -> FirebaseJSON {
        guard !body.isEmpty else { return .null }
        return try FirebaseJSON.parse(body)
    }
}

extension GoogleRESTResponse {
    func requireSuccess(_ operation: String) throws {
        guard !isSuccess else { return }
        throw FirebaseError.from(status: statusCode, body: body, operation: operation)
    }
}

public extension GoogleRESTCredential {
    /// The emulators take the fixed token `owner`, which bypasses the security rules there.
    static let firebaseEmulator = GoogleRESTCredential(token: { "owner" })
}

public extension URLSessionGoogleRESTTransport {
    static func firebase(resourceTimeout: TimeInterval) -> URLSessionGoogleRESTTransport {
        URLSessionGoogleRESTTransport(resourceTimeout: resourceTimeout) { FirebaseError.transport($0) }
    }
}

enum FirebaseQueryString {
    static func encode(_ items: [URLQueryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func encoded(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }
        return items.map { encoded($0.name) + "=" + encoded($0.value ?? "") }.joined(separator: "&")
    }
}
