import Foundation
import Security
@testable import TableProGoogleCloud

struct GoogleAuthStubError: Error {}

final class StubGoogleHTTPClient: GoogleHTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(status: Int = 200, json: String) {
        self.init { request in
            try StubGoogleHTTPClient.reply(to: request, status: status, json: json)
        }
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        return try await handler(request)
    }

    static func reply(to request: URLRequest, status: Int, json: String) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            throw GoogleAuthStubError()
        }
        return (Data(json.utf8), response)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: GoogleClock {
        { [self] in lock.withLock { current } }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}

enum FormBody {
    static func fields(_ request: URLRequest) -> [String: String] {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = String(parts[0]).removingPercentEncoding,
                  let value = String(parts[1]).removingPercentEncoding
            else { continue }
            result[name] = value
        }
        return result
    }
}

enum QueryItems {
    static func value(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

struct TestRSAKey: @unchecked Sendable {
    let privateKey: SecKey
    let publicKey: SecKey
    let pkcs1DER: [UInt8]

    static let shared: TestRSAKey? = TestRSAKey()

    private init?() {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let external = SecKeyCopyExternalRepresentation(privateKey, nil) as Data?
        else {
            return nil
        }
        self.privateKey = privateKey
        self.publicKey = publicKey
        pkcs1DER = Array(external)
    }

    var pkcs8DER: [UInt8] {
        DERBuilder.pkcs8(wrapping: pkcs1DER)
    }

    var pkcs1PEM: String {
        DERBuilder.pem(pkcs1DER, label: "RSA PRIVATE KEY")
    }

    var pkcs8PEM: String {
        DERBuilder.pem(pkcs8DER, label: "PRIVATE KEY")
    }

    func verifies(_ signature: Data, for message: Data) -> Bool {
        SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            signature as CFData,
            nil
        )
    }

    func serviceAccountJSON(
        email: String = "robot@proj.iam.gserviceaccount.com",
        projectId: String? = "proj",
        tokenURI: String? = nil
    ) -> String {
        var object: [String: Any] = [
            "type": "service_account",
            "client_email": email,
            "private_key": pkcs8PEM
        ]
        object["project_id"] = projectId
        object["token_uri"] = tokenURI
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(bytes: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}

enum DERBuilder {
    static let rsaEncryptionOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]

    static func length(_ count: Int) -> [UInt8] {
        guard count >= 0x80 else { return [UInt8(count)] }
        var octets: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            octets.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(octets.count)] + octets
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func pkcs8(wrapping pkcs1: [UInt8], oid: [UInt8] = rsaEncryptionOID) -> [UInt8] {
        let version = tlv(0x02, [0x00])
        let algorithm = tlv(0x30, tlv(0x06, oid) + [0x05, 0x00])
        return tlv(0x30, version + algorithm + tlv(0x04, pkcs1))
    }

    static func pem(_ der: [UInt8], label: String) -> String {
        let base64 = Data(der).base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return (["-----BEGIN \(label)-----"] + lines + ["-----END \(label)-----"]).joined(separator: "\n") + "\n"
    }
}
