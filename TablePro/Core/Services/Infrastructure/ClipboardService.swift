//
//  ClipboardService.swift
//  TablePro
//
//  Abstraction over clipboard operations for testability.
//  Provides protocol-based access to pasteboard data.
//

import AppKit
import UniformTypeIdentifiers

/// Protocol for clipboard operations
/// Abstraction allows for mocking in tests
protocol ClipboardProvider {
    /// Read text content from clipboard
    /// - Returns: Text string if available, nil otherwise
    func readText() -> String?

    /// Write text content to clipboard
    /// - Parameter text: Text to write
    func writeText(_ text: String)

    /// Check if clipboard contains text data
    var hasText: Bool { get }
}

/// Concrete implementation using NSPasteboard
struct NSPasteboardClipboardProvider: ClipboardProvider {
    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func writeText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString(text, forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier))
    }

    var hasText: Bool {
        NSPasteboard.general.string(forType: .string) != nil
    }
}

/// Shared clipboard service instance
@MainActor
enum ClipboardService {
    static var shared: ClipboardProvider = NSPasteboardClipboardProvider()
}
