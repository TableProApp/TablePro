//
//  EmptyTitleControlLabelTests.swift
//  TableProTests
//
//  A control built with an empty title, its visible label a separate `Text` beside it, has no name
//  for VoiceOver: nothing links the two. Measured through the Accessibility API on macOS 27, the AI
//  pane's provider pop-up, the plugin category filter and the CSV import's NULL text field all
//  exposed an empty title and description with no title element. A titled control in a grouped
//  `Form`, a `LabeledContent` row, or a title kept for accessibility behind `.labelsHidden()` names
//  it, with one exception: outside a `Form`, a `TextField` does not expose its title at all, so it
//  needs an `.accessibilityLabel()`.
//

import Foundation
import Testing

struct EmptyTitleControlLabelTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static let emptyTitle = try? NSRegularExpression(
        pattern: #"\b(Picker|TextField|SecureField|Toggle|Stepper|DatePicker)\(""\s*,"#
    )

    /// A `LabeledContent` row hands its label to the control as its title element, which VoiceOver
    /// reads. It sits on one of the two lines above the control.
    private static let linesSearchedForLabeledContent = 2

    /// The modifier chain that follows the control, where an `accessibilityLabel` would name it.
    private static let linesSearchedForLabel = 10

    @Test("Every view and plugin control with an empty title is named another way")
    func emptyTitleControlsAreNamed() throws {
        let roots = ["TablePro/Views", "Plugins"]
        var inspected = 0
        var offenders: [String] = []
        for root in roots {
            let directory = Self.repositoryRoot.appendingPathComponent(root)
            let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" && !url.path.contains("/Tests/") {
                let result = try Self.scan(url)
                inspected += result.inspected
                offenders += result.offenders
            }
        }

        /// Guards the scanner itself: the MCP server fields and the plugin enable switch are
        /// empty-title controls named another way, so a scan that finds none is broken.
        #expect(inspected >= 5, "Expected to find empty-title controls to check, found \(inspected)")
        #expect(
            offenders.isEmpty,
            """
            These controls have an empty title and no other name, so VoiceOver reads only their role. \
            Give them a title (with .labelsHidden() when the label is drawn elsewhere), a LabeledContent \
            row, or an .accessibilityLabel(), which a text field outside a Form needs: \(offenders.sorted())
            """
        )
    }

    /// Text fields outside a `Form` whose title or prompt was their only name. Measured on macOS 27:
    /// there, neither reaches the Accessibility API, so each one names itself.
    private static let selfNamedTextFields: [(path: String, label: String)] = [
        ("TablePro/Views/ObjectCopy/CopyObjectsConfigureView.swift", #".accessibilityLabel(String(localized: "New database"))"#),
        ("TablePro/Views/Structure/CreateTableView.swift", #".accessibilityLabel(String(localized: "Table Name"))"#),
        ("TablePro/Views/Import/RowImportSheet.swift", #".accessibilityLabel(String(localized: "New table"))"#),
        ("TablePro/Views/Import/RowImportSheet.swift", #".accessibilityLabel(String(localized: "Column name"))"#),
        ("TablePro/Views/Editor/QueryParameterPanelView.swift", #".accessibilityLabel(Text(verbatim: ":\(parameter.name)"))"#),
        ("TablePro/Views/Results/DateTimePickerContentView.swift", ".accessibilityLabel(name)")
    ]

    @Test("Text fields outside a Form carry their own accessibility label")
    func textFieldsOutsideAFormAreNamed() throws {
        for field in Self.selfNamedTextFields {
            let url = Self.repositoryRoot.appendingPathComponent(field.path)
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(source.contains(field.label), "\(field.path) lost \(field.label)")
        }
    }

    private static func scan(_ url: URL) throws -> (inspected: Int, offenders: [String]) {
        let pattern = try #require(emptyTitle)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var inspected = 0
        var offenders: [String] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard pattern.firstMatch(in: line, range: range) != nil else { continue }
            inspected += 1

            let before = lines[max(0, index - linesSearchedForLabeledContent) ..< index].joined(separator: "\n")
            let after = lines[index ..< min(lines.count, index + linesSearchedForLabel)].joined(separator: "\n")
            if before.contains("LabeledContent(") || after.contains("accessibilityLabel") {
                continue
            }
            offenders.append("\(url.lastPathComponent):\(index + 1)")
        }
        return (inspected, offenders)
    }
}
