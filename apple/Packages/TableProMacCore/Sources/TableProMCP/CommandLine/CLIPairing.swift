import CryptoKit
import Foundation

// The loopback pairing flow in developers/pairing.mdx.
public struct CLIPairingRequest: Sendable, Equatable {
    public static let callbackPath = "/tablepro-pairing"

    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.base64Url(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.state = state
    }

    public static func random() -> CLIPairingRequest {
        CLIPairingRequest(verifier: base64Url(randomBytes(32)), state: base64Url(randomBytes(16)))
    }

    public func link(callbackPort: UInt16) -> URL? {
        var redirect = URLComponents()
        redirect.scheme = "http"
        redirect.host = "127.0.0.1"
        redirect.port = Int(callbackPort)
        redirect.path = Self.callbackPath
        guard let redirectUrl = redirect.url else { return nil }

        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "integrations"
        components.path = "/pair"
        components.queryItems = [
            URLQueryItem(name: "client", value: CLIClientIdentity.pairingName),
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "redirect", value: redirectUrl.absoluteString),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scopes", value: "readOnly")
        ]
        return components.url
    }

    static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public enum CLIPairingCallback: Sendable, Equatable {
    case approved(code: String)
    case denied
    // Another path, or a `state` from some other request.
    case ignored

    public static func parse(requestTarget: String, state: String) -> CLIPairingCallback {
        guard let components = URLComponents(string: requestTarget),
              components.path == CLIPairingRequest.callbackPath else {
            return .ignored
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("state") == state else { return .ignored }
        if let code = value("code"), !code.isEmpty {
            return .approved(code: code)
        }
        return value("error") == nil ? .ignored : .denied
    }
}
