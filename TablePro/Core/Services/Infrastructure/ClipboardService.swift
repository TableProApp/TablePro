//
//  ClipboardService.swift
//  TablePro
//
//  Abstraction over clipboard operations for testability.
//  Provides protocol-based access to pasteboard data.
//

import AppKit
import UniformTypeIdentifiers

protocol ClipboardProvider {
    func readText() -> String?
    func writeText(_ text: String)
    func writeRows(tsv: String, html: String?)
    var hasText: Bool { get }
    var hasGridRows: Bool { get }
}

struct NSPasteboardClipboardProvider: ClipboardProvider {
    private static let tsvType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
    private static let gridRowsType = NSPasteboard.PasteboardType("com.TablePro.gridRows")

    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func writeText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString(text, forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier))
    }

    func writeRows(tsv: String, html: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .string)
        pb.setString(tsv, forType: Self.tsvType)
        if let html {
            pb.setString(html, forType: .html)
        }
        pb.setString("1", forType: Self.gridRowsType)
    }

    var hasText: Bool {
        NSPasteboard.general.string(forType: .string) != nil
    }

    var hasGridRows: Bool {
        NSPasteboard.general.types?.contains(Self.gridRowsType) == true
    }
}

@MainActor
enum ClipboardService {
    static var shared: ClipboardProvider = NSPasteboardClipboardProvider()
}
