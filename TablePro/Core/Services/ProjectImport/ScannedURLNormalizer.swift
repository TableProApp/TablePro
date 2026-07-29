//
//  ScannedURLNormalizer.swift
//  TablePro
//

import Foundation

enum ScannedURLNormalizer {
    private static let userInfoAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~%")
        return allowed
    }()

    static func normalize(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else {
            return trimmed
        }
        let scheme = String(trimmed[trimmed.startIndex..<schemeRange.upperBound])
        let remainder = String(trimmed[schemeRange.upperBound...])
        guard !remainder.hasPrefix("/") else {
            return trimmed
        }
        guard let separator = lastUserInfoSeparator(in: remainder) else {
            return trimmed
        }
        let userInfo = String(remainder[remainder.startIndex..<separator])
        let rest = String(remainder[remainder.index(after: separator)...])
        return scheme + encode(userInfo: userInfo) + "@" + rest
    }

    private static func lastUserInfoSeparator(in remainder: String) -> String.Index? {
        let boundary = remainder.firstIndex { $0 == "?" || $0 == "#" } ?? remainder.endIndex
        let searchable = remainder[remainder.startIndex..<boundary]
        return searchable.lastIndex(of: "@")
    }

    private static func encode(userInfo: String) -> String {
        guard let colon = userInfo.firstIndex(of: ":") else {
            return percentEncoded(userInfo)
        }
        let username = String(userInfo[userInfo.startIndex..<colon])
        let password = String(userInfo[userInfo.index(after: colon)...])
        return percentEncoded(username) + ":" + percentEncoded(password)
    }

    private static func percentEncoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: userInfoAllowed) ?? component
    }
}
