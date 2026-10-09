//
//  DataLinkPolicy.swift
//  TablePro
//

import AppKit
import Foundation

/// Which database values may open outside the app. The value is untrusted, so this is an
/// allow-list, and the URL that opens is the text of the value, character for character.
internal enum DataLinkPolicy {
    static let maxLength = 2_048

    /// Settable so a test never launches a browser. A test that replaces it restores it in a `defer`.
    @MainActor static var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    static func openableURL(from raw: String) -> URL? {
        guard raw.utf8.count(isAtMost: maxLength),
              let scheme = Scheme.leading(raw.unicodeScalars),
              scheme.admits(raw.unicodeScalars.dropFirst(scheme.prefix.unicodeScalars.count)),
              let components = URLComponents(string: raw),
              scheme.admits(components),
              let url = components.url
        else { return nil }
        /// The backstop for what the checks above do not model. From macOS 14 `URLComponents`
        /// rewrites what it cannot keep, and the row would show one address while another opened.
        return url.absoluteString == raw ? url : nil
    }

    /// Vetted again, because a caller can hand over a URL the policy never produced.
    @MainActor static func open(_ url: URL) {
        guard let vetted = openableURL(from: url.absoluteString) else { return }
        opener(vetted)
    }

    /// What RFC 3986 allows after `http://`: its characters, whole percent escapes, one fragment,
    /// brackets only around an IPv6 host. From macOS 14 `URLComponents` escapes anything else
    /// instead of failing, so the check is made here and does not depend on the OS.
    static func isWellFormedLocation(_ scalars: some Sequence<Unicode.Scalar>) -> Bool {
        var escapeDigitsDue = 0
        var isPastAuthority = false
        var hasFragment = false
        for scalar in scalars {
            if escapeDigitsDue > 0 {
                guard scalar.properties.isASCIIHexDigit else { return false }
                escapeDigitsDue -= 1
                continue
            }
            switch scalar {
            case "%":
                /// An escaped host reads as one name and resolves as another.
                guard isPastAuthority else { return false }
                escapeDigitsDue = 2
            case "/", "?":
                isPastAuthority = true
            case "#":
                guard !hasFragment else { return false }
                hasFragment = true
                isPastAuthority = true
            case "[", "]":
                guard !isPastAuthority else { return false }
            case "a"..."z", "A"..."Z", "0"..."9", "-", ".", "_", "~", ":", "@", "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "=":
                continue
            default:
                return false
            }
        }
        return escapeDigitsDue == 0
    }
}

private extension DataLinkPolicy {
    enum Scheme: CaseIterable {
        case http
        case https
        case mailto

        var prefix: String {
            switch self {
            case .http: "http://"
            case .https: "https://"
            case .mailto: "mailto:"
            }
        }

        static func leading(_ scalars: String.UnicodeScalarView) -> Scheme? {
            allCases.first { scheme in
                let expected = scheme.prefix.unicodeScalars
                return scalars.prefix(expected.count).elementsEqual(expected) { $0.asciiLowercased == $1 }
            }
        }

        func admits(_ remainder: Substring.UnicodeScalarView) -> Bool {
            switch self {
            case .http, .https: DataLinkPolicy.isWellFormedLocation(remainder)
            case .mailto: DataLinkPolicy.isBareAddress(remainder)
            }
        }

        func admits(_ components: URLComponents) -> Bool {
            switch self {
            case .http, .https:
                components.host?.isEmpty == false && components.user == nil && components.password == nil
            case .mailto:
                true
            }
        }
    }

    /// One address and nothing else. A `mailto:` query can add recipients, a body or an
    /// attachment, and a percent escape can hide any of them.
    static func isBareAddress(_ scalars: Substring.UnicodeScalarView) -> Bool {
        let parts = scalars.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let localPart = parts.first, let domain = parts.last else { return false }
        return !localPart.isEmpty && localPart.allSatisfy(isLocalPartCharacter)
            && !domain.isEmpty && domain.allSatisfy(isDomainCharacter)
    }

    static func isLocalPartCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isDomainCharacter(scalar) || scalar == "_" || scalar == "+" || scalar == "'"
    }

    static func isDomainCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "-": true
        default: false
        }
    }
}
