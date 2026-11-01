//
//  MaskedValue.swift
//  TablePro
//

import CryptoKit
import Foundation
import TableProPluginKit

enum MaskedValue {
    static let bullets = "••••"

    // Keyed per launch, so equal values hash alike everywhere in this run but a hash cannot be looked up in a table.
    private static let hashKey = SymmetricKey(size: .bits256)

    static func mask(_ value: PluginCellValue, style: MaskingStyle) -> PluginCellValue {
        if style == .null { return .null }
        switch value {
        case .null:
            return .null
        case .text(let text):
            return .text(mask(text: text, style: style))
        case .bytes(let data):
            return .text(style == .hash ? hash(data) : bullets)
        }
    }

    private static func mask(text: String, style: MaskingStyle) -> String {
        switch style {
        case .full, .null:
            return bullets
        case .lastFour:
            guard text.count > 4 else { return bullets }
            return bullets + String(text.suffix(4))
        case .email:
            guard let at = text.lastIndex(of: "@"), at != text.startIndex else { return bullets }
            let domain = text[text.index(after: at)...]
            guard !domain.isEmpty else { return bullets }
            return String(text[text.startIndex]) + "•••@" + domain
        case .hash:
            return hash(Data(text.utf8))
        }
    }

    private static func hash(_ data: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: data, using: hashKey)
        return code.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
