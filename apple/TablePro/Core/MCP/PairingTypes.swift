import Foundation
import TableProMCP

struct PairingRequest: Sendable, Equatable {
    static let maximumStateBytes = 1_024

    let clientName: String
    let challenge: String
    let redirectURL: URL
    let requestedScopes: String?
    let requestedConnectionIds: Set<UUID>?
    let state: String?
    let responseMode: PairingResponseMode

    init(
        clientName: String,
        challenge: String,
        redirectURL: URL,
        requestedScopes: String?,
        requestedConnectionIds: Set<UUID>?,
        state: String? = nil,
        responseMode: PairingResponseMode = .legacy
    ) {
        self.clientName = clientName
        self.challenge = challenge
        self.redirectURL = redirectURL
        self.requestedScopes = requestedScopes
        self.requestedConnectionIds = requestedConnectionIds
        self.state = state
        self.responseMode = responseMode
    }

    var redirectTarget: PairingRedirectTarget? {
        try? PairingRedirectValidator.validate(redirectURL)
    }

    var redirectDisplayValue: String {
        redirectTarget?.displayValue ?? redirectURL.scheme.map { "\($0)://" } ?? redirectURL.absoluteString
    }

    var scopeRequest: PairingScopeRequest {
        PairingScopeRequest.parse(requestedScopes)
    }
}

// One permission level plus optional grants; unknown entries are skipped (RFC 6749 3.3) and the lowest level wins.
struct PairingScopeRequest: Sendable, Equatable {
    let permissions: TokenPermissions
    let optionalGrants: Set<MCPScope>

    static func parse(_ raw: String?) -> PairingScopeRequest {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        let entries = (raw ?? "").lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
        let levels = Set(entries.compactMap(permissions(named:)))
        return PairingScopeRequest(
            permissions: TokenPermissions.allCases.first(where: levels.contains) ?? .readOnly,
            optionalGrants: Set(entries.compactMap(MCPScope.init(rawValue:))).intersection(MCPScope.optionalGrants)
        )
    }

    // Granted only when the client asked, the user ticked it on the sheet, and the setting allows it.
    func grantedOptionalScopes(approved: Set<MCPScope>, allowsHiddenConnectionListing: Bool) -> Set<MCPScope> {
        guard allowsHiddenConnectionListing else { return [] }
        return optionalGrants.intersection(approved)
    }

    private static func permissions(named entry: String) -> TokenPermissions? {
        switch entry {
        case "readonly", "read_only", "read-only":
            return .readOnly
        case "readwrite", "read_write", "read-write":
            return .readWrite
        case "fullaccess", "full_access", "full-access", "full":
            return .fullAccess
        default:
            return nil
        }
    }
}

// legacy is a link without response_mode, kept byte for byte for clients that shipped before it.
enum PairingResponseMode: Sendable, Equatable {
    case legacy
    case query
    case context

    init?(parameter: String) {
        switch parameter {
        case "query":
            self = .query
        case "context":
            self = .context
        default:
            return nil
        }
    }
}

struct PairingExchange: Sendable, Equatable {
    let code: String
    let verifier: String
}

enum PairingRedirectKind: Sendable, Equatable {
    case loopbackHttp
    case privateUseScheme
}

struct PairingRedirectTarget: Sendable, Equatable {
    let url: URL
    let kind: PairingRedirectKind
    let displayValue: String
}

enum PairingValidationError: Error, Sendable, Equatable {
    case redirectSchemeMissing
    case redirectSchemeNotAllowed(String)
    case redirectHostNotLoopback(String)
    case redirectCarriesCredentials
    case challengeMalformed
    case verifierMalformed

    var reason: String {
        switch self {
        case .redirectSchemeMissing:
            return "redirect_scheme_missing"
        case .redirectSchemeNotAllowed(let scheme):
            return "redirect_scheme_not_allowed:\(scheme)"
        case .redirectHostNotLoopback(let host):
            return "redirect_host_not_loopback:\(host)"
        case .redirectCarriesCredentials:
            return "redirect_carries_credentials"
        case .challengeMalformed:
            return "challenge_malformed"
        case .verifierMalformed:
            return "verifier_malformed"
        }
    }

    var localizedMessage: String {
        switch self {
        case .redirectSchemeMissing, .redirectSchemeNotAllowed, .redirectHostNotLoopback,
             .redirectCarriesCredentials:
            return String(
                localized: "The redirect address is not a local callback, so pairing was refused."
            )
        case .challengeMalformed:
            return String(localized: "The pairing challenge is malformed.")
        case .verifierMalformed:
            return String(localized: "The pairing verifier is malformed.")
        }
    }
}

// Whoever receives the code holds the grant, so only a loopback listener (RFC 8252) or an installed
// app's private-use scheme may: any other origin is a web page.
enum PairingRedirectValidator {
    static let loopbackHosts: Set<String> = [
        "127.0.0.1",
        "localhost",
        "::1",
        "0:0:0:0:0:0:0:1"
    ]

    // tablepro would reopen a pairing sheet; the rest run something locally or fetch from the named host.
    static let deniedSchemes: Set<String> = [
        "about", "afp", "blob", "cifs", "data", "dav", "davs", "feed", "feeds", "file", "ftp", "ftps",
        "git", "gopher", "irc", "ircs", "itpc", "javascript", "ldap", "ldaps", "news", "nfs", "nntp",
        "pcast", "pcasts", "podcast", "podcasts", "rdp", "rtmp", "rtsp", "rtsps", "sftp", "sip", "sips",
        "smb", "ssh", "svn", "tablepro", "telnet", "tftp", "vbscript", "vnc", "webcal", "webcals", "ws",
        "wss", "xmpp"
    ]

    // Opening one of these with the code appended would connect to whatever host the redirect names.
    static let appRegisteredSchemes: Set<String> = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return Set(schemes.map { $0.lowercased() })
    }()

    static func validate(_ url: URL) throws -> PairingRedirectTarget {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw PairingValidationError.redirectSchemeMissing
        }
        guard url.user == nil, url.password == nil else {
            throw PairingValidationError.redirectCarriesCredentials
        }

        if scheme == "http" || scheme == "https" {
            let host = url.host?.lowercased() ?? ""
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard loopbackHosts.contains(bare) else {
                throw PairingValidationError.redirectHostNotLoopback(host.isEmpty ? "-" : host)
            }
            let port = url.port.map { ":\($0)" } ?? ""
            return PairingRedirectTarget(
                url: url,
                kind: .loopbackHttp,
                displayValue: "\(scheme)://\(host)\(port)\(url.path)"
            )
        }

        guard !deniedSchemes.contains(scheme), !appRegisteredSchemes.contains(scheme),
              isWellFormedScheme(scheme) else {
            throw PairingValidationError.redirectSchemeNotAllowed(scheme)
        }
        // An opaque URL such as myapp:https://example.com/ keeps its whole address in the path.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let authority = components?.host.map { "//\($0)" } ?? ""
        let port = components?.port.map { ":\($0)" } ?? ""
        return PairingRedirectTarget(
            url: url,
            kind: .privateUseScheme,
            displayValue: "\(scheme):\(authority)\(port)\(components?.path ?? url.path)"
        )
    }

    // A browser that owns a custom scheme unwraps it into a web page (google-chrome:https://, x-safari-https://).
    static func validateHandler(
        of target: PairingRedirectTarget,
        handlerBundleIdentifier: String?,
        browserBundleIdentifiers: Set<String>
    ) throws {
        guard target.kind == .privateUseScheme,
              let handlerBundleIdentifier,
              browserBundleIdentifiers.contains(handlerBundleIdentifier) else {
            return
        }
        throw PairingValidationError.redirectSchemeNotAllowed(target.url.scheme?.lowercased() ?? "-")
    }

    private static func isWellFormedScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isLetter else { return false }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "+-."))
        return scheme.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

enum PairingRedirectBuilder {
    // Form decoders split on & and =, read + as a space, and some still split on ;.
    private static let valueCharacters = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "&=+;"))

    static func success(base: URL, code: String, state: String?, mode: PairingResponseMode) -> URL? {
        redirect(base: base, parameters: [("code", code)], state: state, mode: mode)
    }

    static func denied(base: URL, state: String?, mode: PairingResponseMode) -> URL? {
        let error = mode == .legacy ? "denied" : "access_denied"
        return redirect(
            base: base,
            parameters: [("error", error), ("error_description", "user_denied")],
            state: state,
            mode: mode
        )
    }

    // The user approved, then TablePro could not issue the token (RFC 6749 4.1.2.1 server_error).
    static func failed(base: URL, state: String?, mode: PairingResponseMode) -> URL? {
        redirect(
            base: base,
            parameters: [("error", "server_error"), ("error_description", "token_not_issued")],
            state: state,
            mode: mode
        )
    }

    private static func redirect(
        base: URL,
        parameters: [(name: String, value: String)],
        state: String?,
        mode: PairingResponseMode
    ) -> URL? {
        var parameters = parameters
        if let state {
            parameters.append(("state", state))
        }
        guard wrapsInContext(base: base, mode: mode) else {
            return appending(parameters, to: base)
        }
        let payload = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.value) })
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return appending([("context", json)], to: base)
    }

    private static func wrapsInContext(base: URL, mode: PairingResponseMode) -> Bool {
        switch mode {
        case .legacy:
            return base.scheme == "raycast"
        case .query:
            return false
        case .context:
            return true
        }
    }

    private static func appending(_ parameters: [(name: String, value: String)], to base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // Decoding and re-encoding the client's own items would turn its %2B into +.
        var items = components.percentEncodedQueryItems ?? []
        for parameter in parameters {
            guard let value = parameter.value.addingPercentEncoding(withAllowedCharacters: valueCharacters) else {
                return nil
            }
            items.append(URLQueryItem(name: parameter.name, value: value))
        }
        components.percentEncodedQueryItems = items
        return components.url
    }
}

// RFC 7636: a verifier of 43 to 128 unreserved characters, a challenge of 43; anything else never reaches a comparison.
enum PairingPkceValidator {
    static let minimumVerifierLength = 43
    static let maximumVerifierLength = 128
    static let challengeLength = 43

    static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static let base64UrlCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func validateVerifier(_ verifier: String) throws {
        let length = verifier.unicodeScalars.count
        guard length >= minimumVerifierLength, length <= maximumVerifierLength else {
            throw PairingValidationError.verifierMalformed
        }
        guard verifier.unicodeScalars.allSatisfy({ unreservedCharacters.contains($0) }) else {
            throw PairingValidationError.verifierMalformed
        }
    }

    static func validateChallenge(_ challenge: String) throws {
        guard challenge.unicodeScalars.count == challengeLength else {
            throw PairingValidationError.challengeMalformed
        }
        guard challenge.unicodeScalars.allSatisfy({ base64UrlCharacters.contains($0) }) else {
            throw PairingValidationError.challengeMalformed
        }
    }
}
