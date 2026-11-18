//
//  PluginHexTextTests.swift
//  FormatPluginTests
//

import Foundation
import Testing

struct PluginHexTextTests {
    @Test("Every byte spells the two uppercase digits String(format:) gives it")
    func everyByteMatchesTheFormatSpelling() {
        let everyByte = Data((0 ... 255).map { UInt8($0) })
        let expected = everyByte.map { String(format: "%02X", $0) }.joined()

        #expect(PluginHexText.uppercase(everyByte) == expected)
    }

    @Test("No bytes make no text")
    func emptyDataIsEmptyText() {
        #expect(PluginHexText.uppercase(Data()).isEmpty)
    }

    @Test("A slice reads from its own start index")
    func sliceReadsItsOwnBytes() {
        let data = Data([0x00, 0x11, 0xAB, 0xFF])

        #expect(PluginHexText.uppercase(data[2...]) == "ABFF")
    }

    @Test("Appending a byte adds its two digits to what is already there")
    func appendKeepsTheExistingText() {
        var text = Array("x".utf8)

        PluginHexText.appendUppercase(0x0F, to: &text)
        PluginHexText.appendUppercase(0xA0, to: &text)

        #expect(String(decoding: text, as: UTF8.self) == "x0FA0")
    }
}
