//
//  KeyboardInteractivePrompt.swift
//  TablePro
//

import Foundation

public struct KeyboardInteractivePrompt: Sendable, Equatable {
    public let text: String
    public let echo: Bool

    public init(text: String, echo: Bool) {
        self.text = text
        self.echo = echo
    }

    public init(utf8Bytes: [UInt8], echo: Bool) {
        let decoded = utf8Bytes.isEmpty
            ? ""
            : String(decoding: utf8Bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        self.init(text: decoded, echo: echo)
    }

    public var isSecure: Bool { !echo }
}

public struct KeyboardInteractiveChallenge: Sendable, Equatable {
    public let name: String
    public let instruction: String
    public let prompts: [KeyboardInteractivePrompt]

    public init(name: String, instruction: String, prompts: [KeyboardInteractivePrompt]) {
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
    }
}
