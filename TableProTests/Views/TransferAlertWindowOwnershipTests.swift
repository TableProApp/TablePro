//
//  TransferAlertWindowOwnershipTests.swift
//  TableProTests
//

import Foundation
import Testing

/// A transfer dialog presents its alerts on the window it is hosted in, never on whichever window
/// happens to be key.
///
/// A SwiftUI `.sheet` is a real AppKit sheet. When an import or export finishes, the dialog
/// dismisses its nested progress sheet and presents the result in the same transaction, and at
/// that instant `NSApp.keyWindow` is the progress sheet AppKit is tearing down. An alert begun on
/// it is a child of a dying parent, so AppKit ends it a few milliseconds later with
/// `ModalResponse.stop` and it never renders. Measured: passing `nil` fails the same way, because
/// `AlertHelper.resolveWindow` falls back to the same key window and a sheet window clears
/// `isContentWindow` (it is not an `NSPanel` and it is `.titled`). Nothing at runtime can tell a
/// dying sheet from a healthy one, so the rule has to hold at the call site (#2314).
@Suite("Transfer alert window ownership")
struct TransferAlertWindowOwnershipTests {
    private static let directories = [
        "TablePro/Views/Import",
        "TablePro/Views/Export",
    ]

    private static let alertPresenters = [
        "TransferResultAlert.",
        "AlertHelper.",
    ]

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
        }
        throw TransferAlertWindowOwnershipError.repositoryRootNotFound
    }

    private func swiftFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func sources(in directory: String, under root: URL) -> [(name: String, text: String)] {
        swiftFiles(in: root.appendingPathComponent(directory)).compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return (file.lastPathComponent, text)
        }
    }

    /// A presenter call can wrap over several lines, so the scan reads to the closing parenthesis
    /// of the call rather than a fixed number of characters, which would truncate a long call and
    /// silently pass it.
    private func presenterCalls(in source: String) -> [String] {
        var calls: [String] = []
        for presenter in Self.alertPresenters {
            var searchRange = source.startIndex ..< source.endIndex
            while let found = source.range(of: presenter, range: searchRange) {
                calls.append(String(source[found.upperBound...].prefix(while: { $0 != ")" })))
                searchRange = found.upperBound ..< source.endIndex
            }
        }
        return calls
    }

    @Test("No transfer dialog hands an alert the key window or no window at all")
    func transferDialogsOwnTheirAlertWindow() throws {
        let root = try repositoryRoot()
        var offenders: [String] = []

        for directory in Self.directories {
            for source in sources(in: directory, under: root) {
                for call in presenterCalls(in: source.text) where call.contains("window:") {
                    if call.contains("window: NSApp.") || call.contains("window: nil") {
                        offenders.append("\(source.name): \(call.prefix(90))")
                    }
                }
            }
        }

        #expect(offenders.isEmpty, "Alerts must be presented on the dialog's own window: \(offenders)")
    }

    /// Spelling `window: hostWindow` proves nothing on its own. Drop the capture and `hostWindow`
    /// stays nil forever, every call site still reads the same, and `resolveWindow(nil)` reproduces
    /// the bug in full. The capture is the half that has to be there.
    @Test("Every transfer dialog captures the window it presents on")
    func everyDialogCapturesItsWindow() throws {
        let root = try repositoryRoot()
        var missing: [String] = []

        for directory in Self.directories {
            for source in sources(in: directory, under: root) where source.text.contains("window: hostWindow") {
                let captures = source.text.contains("WindowAccessor") && source.text.contains("hostWindow = ")
                if !captures {
                    missing.append(source.name)
                }
            }
        }

        #expect(missing.isEmpty, "A dialog presenting on hostWindow must capture it: \(missing)")
    }

    /// Both checks above pass trivially if they scan nothing, so pin what they are meant to reach.
    @Test("The scan reaches all three transfer dialogs")
    func theScanReachesAllThreeDialogs() throws {
        let root = try repositoryRoot()
        var presenting: Set<String> = []

        for directory in Self.directories {
            for source in sources(in: directory, under: root) where source.text.contains("window: hostWindow") {
                presenting.insert(source.name)
            }
        }

        #expect(presenting.contains("ImportDialog.swift"))
        #expect(presenting.contains("RowImportSheet.swift"))
        #expect(presenting.contains("ExportDialog.swift"))
    }
}

private enum TransferAlertWindowOwnershipError: Error {
    case repositoryRootNotFound
}
