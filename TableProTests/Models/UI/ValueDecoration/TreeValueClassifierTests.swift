//
//  TreeValueClassifierTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct TreeValueClassifierTests {
    @Test("A link value classifies as a link that carries the value itself")
    func linkExamples() {
        for input in ["https://example.com/a?b=c#d", "http://localhost:8080/x", "mailto:someone@example.com"] {
            guard case .link(let url) = TreeValueClassifier.classify(input) else {
                Issue.record("Expected a link for \(input)")
                continue
            }
            #expect(url.absoluteString == input)
        }
    }

    @Test("A value that only resembles a link classifies as nothing")
    func notLinkExamples() {
        let inputs = [
            "example.com", "www.example.com", "see https://example.com for more", "file:///etc/passwd",
            "tablepro://connect?host=evil", "postgres://user:pw@host/db", "javascript:alert(1)",
            "https://apple.com@evil.example/login", "https://\u{0430}pple.com/login",
            "mailto:a@b.com?bcc=evil@x.example", "\thttps://example.com", "https://example.com "
        ]
        for input in inputs {
            #expect(TreeValueClassifier.classify(input) == .none, "\(input.debugDescription)")
        }
    }

    @Test("A color value classifies as a color")
    func colorExamples() {
        let inputs = [
            "#f80", "#FF8800", "#ff880080", "rgb(255, 136, 0)", "rgba(255,136,0,.5)", "rgb(255 136 0 / 50%)",
            "hsl(32, 100%, 50%)", "hsla(120, 100%, 25%, 0.25)"
        ]
        for input in inputs {
            guard case .color = TreeValueClassifier.classify(input) else {
                Issue.record("Expected a color for \(input)")
                continue
            }
        }
        #expect(TreeValueClassifier.classify("#FF8800") == .color(RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 1)))
        #expect(TreeValueClassifier.classify("#ff880080") == .color(RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 128.0 / 255)))
    }

    @Test("A value that only resembles a color classifies as nothing")
    func notColorExamples() {
        let inputs = [
            "#12345", "ff8800", "red", "see #ff8800", "rgb(255, 136)", "rgb(nan, 0, 0)", "rgb(1,2,3,)",
            "#1234", " #f80", "#f80 ", "rgb(1,2,3) "
        ]
        for input in inputs {
            #expect(TreeValueClassifier.classify(input) == .none, "\(input.debugDescription)")
        }
    }

    @Test("Ordinary values classify as nothing")
    func ordinaryValues() {
        for input in ["", " ", "hello", "42", "true", "null", "2026-10-09", "#", "http", "a@b.com", "user@example.com"] {
            #expect(TreeValueClassifier.classify(input) == .none, "\(input.debugDescription)")
        }
    }

    @Test("A 1 MB value classifies as nothing, whatever it starts with")
    func megabyteValues() {
        let padding = String(repeating: "a", count: 1_048_576)
        #expect(TreeValueClassifier.classify("https://example.com/" + padding) == .none)
        #expect(TreeValueClassifier.classify("mailto:" + padding + "@example.com") == .none)
        #expect(TreeValueClassifier.classify("#ff8800" + padding) == .none)
        #expect(TreeValueClassifier.classify(String(repeating: "https://example.com/ ", count: 50_000)) == .none)
    }

    @Test("A decoration crosses a detached task")
    func classifiesOffTheMainActor() async throws {
        let inputs = ["https://example.com/", "#f80", "plain"]
        let classification = Task.detached {
            inputs.map { TreeValueClassifier.classify($0) }
        }
        let decorations = await classification.value

        let url = try #require(URL(string: "https://example.com/"))
        let orange = RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 1)
        #expect(decorations == [.link(url), .color(orange), .none])
    }

    // MARK: - Shared helpers

    /// `\u{1EC7}` is one UTF-16 unit and three UTF-8 bytes, so a gate that counted units would
    /// let 2,049 bytes through. `NSString(string:) as String` stays UTF-16 backed, which is the
    /// storage the gate walks instead of reading a stored count.
    @Test("The length gate counts UTF-8 bytes, on a native and on a bridged string")
    func lengthGateCountsBytes() {
        let native = String(repeating: "\u{1EC7}", count: 683)
        let bridged = NSString(string: native) as String

        for text in [native, bridged] {
            #expect(text.utf8.count == 2_049)
            #expect(!text.utf8.count(isAtMost: 2_048))
            #expect(text.utf8.count(isAtMost: 2_049))
            #expect(text.utf8.count(isAtMost: 5_000))
        }
        #expect("".utf8.count(isAtMost: 0))
        #expect(!"a".utf8.count(isAtMost: 0))
    }

    @Test("ASCII lowercasing leaves every non-ASCII letter alone")
    func asciiLowercasing() {
        let pairs: [(input: Unicode.Scalar, expected: Unicode.Scalar)] = [
            ("A", "a"), ("Z", "z"), ("a", "a"), ("0", "0"), ("@", "@"), ("[", "["),
            ("\u{212A}", "\u{212A}"), ("\u{0130}", "\u{0130}"), ("\u{FF21}", "\u{FF21}")
        ]
        for pair in pairs {
            #expect(pair.input.asciiLowercased == pair.expected, "U+\(String(pair.input.value, radix: 16))")
        }
    }
}
