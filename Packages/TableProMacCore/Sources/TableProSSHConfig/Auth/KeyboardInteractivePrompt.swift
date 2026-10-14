//
//  KeyboardInteractivePrompt.swift
//  TablePro
//

import Foundation

internal struct KeyboardInteractivePrompt: Sendable, Equatable {
    let text: String
    let echo: Bool

    init(text: String, echo: Bool) {
        self.text = text
        self.echo = echo
    }

    init(utf8Bytes: [UInt8], echo: Bool) {
        let decoded = utf8Bytes.isEmpty
            ? ""
            : String(decoding: utf8Bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        self.init(text: decoded, echo: echo)
    }

    var isSecure: Bool { !echo }
}

internal struct KeyboardInteractiveChallenge: Sendable, Equatable {
    let name: String
    let instruction: String
    let prompts: [KeyboardInteractivePrompt]
}
