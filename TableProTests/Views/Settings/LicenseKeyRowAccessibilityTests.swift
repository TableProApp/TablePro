//
//  LicenseKeyRowAccessibilityTests.swift
//  TableProTests
//
//  Settings > License crashed any accessibility client that was already reading the pane when a
//  license appeared, VoiceOver or an XCTest snapshot alike: the key text's label looped through
//  SwiftUI until the stack overflowed. The loop needs exactly that order, a read of the pane, then
//  the key row inserted, then a read of the row, so the row is read here the same way, through the
//  Accessibility API, from an offscreen window. That read needs Accessibility access, so a source
//  check refuses the same shape everywhere else.
//

import AppKit
import ApplicationServices
import Combine
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct LicenseKeyRowAccessibilityTests {
    private final class Reveal: ObservableObject {
        @Published var isShown = false
    }

    private struct Pane: View {
        @ObservedObject var reveal: Reveal

        var body: some View {
            Form {
                Section {
                    if reveal.isShown {
                        LicenseKeyRow(key: "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY")
                    } else {
                        Text(verbatim: "No license")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private static let windowTitle = "LicenseKeyRowAccessibilityTests"

    @Test(
        "The license key row reads as hidden when it appears while the pane is being read",
        .enabled(if: AXIsProcessTrusted(), "Reading this process's accessibility tree needs Accessibility access")
    )
    func keyRowIsReadAfterAppearing() async throws {
        let reveal = Reveal()
        let host = NSHostingController(rootView: Pane(reveal: reveal))
        let window = NSWindow(contentViewController: host)
        window.title = Self.windowTitle
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 640, height: 240), display: false)
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        try await Task.sleep(for: .milliseconds(300))
        let before = try #require(Self.window(titled: Self.windowTitle))
        #expect(Self.texts(in: before).contains("No license"))

        reveal.isShown = true
        try await Task.sleep(for: .milliseconds(300))

        let after = try #require(Self.window(titled: Self.windowTitle))
        let texts = Self.texts(in: after)
        #expect(texts.contains(String(localized: "License key")))
        #expect(texts.contains(String(localized: "License key, hidden")))
        #expect(!texts.contains { $0.hasPrefix("ABCDE") })
    }

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    /// The test above needs Accessibility access, which a test host does not have on CI, so the
    /// shape that looped is also refused in source: an `.accessibilityLabel` later in the chain of
    /// a `.lineLimit` inside a `LabeledContent`. Measured on macOS 27, the loop needed all three.
    @Test("No line-limited view in a LabeledContent names itself with accessibilityLabel")
    func lineLimitedLabelledContentIsNotRelabelled() throws {
        var blocks = 0
        var offenders: [String] = []
        for root in ["TablePro/Views", "Plugins"] {
            let directory = Self.repositoryRoot.appendingPathComponent(root)
            let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                let result = Self.scan(lines)
                blocks += result.blocks
                offenders += result.offenders.map { "\(url.lastPathComponent):\($0)" }
            }
        }

        /// Guards the scanner itself: the app has dozens of `LabeledContent` rows.
        #expect(blocks > 20, "Expected to find LabeledContent rows to check, found \(blocks)")
        #expect(
            offenders.isEmpty,
            """
            A line-limited view in a LabeledContent is relabelled with .accessibilityLabel, which loops \
            in SwiftUI's accessibility until the stack overflows. Use .accessibilityRepresentation: \
            \(offenders.sorted())
            """
        )
    }

    /// Line numbers of an `.accessibilityLabel` in the same modifier chain as a `.lineLimit`, inside
    /// a `LabeledContent` block found by brace depth.
    private static func scan(_ lines: [String]) -> (blocks: Int, offenders: [Int]) {
        var blocks = 0
        var offenders: [Int] = []
        for (start, line) in lines.enumerated() where line.contains("LabeledContent(") {
            blocks += 1
            var depth = 0
            var opened = false
            var end = start
            for index in start ..< lines.count {
                let opening = lines[index].filter { $0 == "{" }.count
                depth += opening - lines[index].filter { $0 == "}" }.count
                opened = opened || opening > 0
                end = index
                if !opened || depth <= 0 {
                    break
                }
            }
            for index in start ... end where lines[index].contains(".lineLimit(") {
                var next = index + 1
                while next <= end {
                    let modifier = lines[next].trimmingCharacters(in: .whitespaces)
                    guard modifier.hasPrefix(".") || modifier.hasPrefix("//") else { break }
                    if modifier.hasPrefix(".accessibilityLabel(") {
                        offenders.append(next + 1)
                    }
                    next += 1
                }
            }
        }
        return (blocks, Array(Set(offenders)).sorted())
    }

    private static func window(titled title: String) -> AXUIElement? {
        let application = AXUIElementCreateApplication(getpid())
        let windows = value(of: application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { value(of: $0, kAXTitleAttribute) as? String == title }
    }

    /// Every name and value in the subtree, read attribute by attribute as VoiceOver does.
    private static func texts(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 40 else { return [] }
        var texts: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let text = value(of: element, attribute) as? String, !text.isEmpty {
                texts.append(text)
            }
        }
        for child in value(of: element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            texts += Self.texts(in: child, depth: depth + 1)
        }
        return texts
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
