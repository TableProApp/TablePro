import Foundation

struct PairingRequest: Sendable, Equatable {
    let clientName: String
    let challenge: String
    let redirectURL: URL
    let requestedScopes: String?
    let requestedConnectionIds: Set<UUID>?

    var redirectTarget: PairingRedirectTarget? {
        try? PairingRedirectValidator.validate(redirectURL)
    }

    var redirectDisplayValue: String {
        redirectTarget?.displayValue ?? redirectURL.scheme.map { "\($0)://" } ?? redirectURL.absoluteString
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

/// A pairing code is a bearer credential for the whole grant, so the address it is delivered to
/// decides who ends up holding it. Only two shapes can reach the machine the user is sitting at: a
/// loopback HTTP listener (RFC 8252's native-app redirect) and a private-use scheme registered by an
/// installed app. Any other origin is a web page, and handing it the code hands it the token.
enum PairingRedirectValidator {
    static let loopbackHosts: Set<String> = [
        "127.0.0.1",
        "localhost",
        "::1",
        "0:0:0:0:0:0:0:1"
    ]

    static let deniedSchemes: Set<String> = [
        "about",
        "blob",
        "data",
        "file",
        "ftp",
        "javascript",
        "vbscript"
    ]

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

        guard !deniedSchemes.contains(scheme), isWellFormedScheme(scheme) else {
            throw PairingValidationError.redirectSchemeNotAllowed(scheme)
        }
        let host = url.host.map { "\($0)" } ?? ""
        return PairingRedirectTarget(
            url: url,
            kind: .privateUseScheme,
            displayValue: "\(scheme)://\(host)\(url.path)"
        )
    }

    private static func isWellFormedScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isLetter else { return false }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "+-."))
        return scheme.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// RFC 7636 fixes both halves of PKCE: the verifier is 43 to 128 characters of the unreserved set,
/// and the challenge is its base64url SHA-256, which is always 43 characters. Anything else is not a
/// PKCE exchange and is rejected before it can reach a comparison.
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
