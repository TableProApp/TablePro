//
//  HostedAccessibility.swift
//  TableProTests
//

import AppKit
import ApplicationServices
import SwiftUI
import TableProTestSupport

// A SwiftUI view hosted in a window and read through the AX API, as VoiceOver reads it: in process, a hosting view
// lists no SwiftUI children.
@MainActor
enum HostedAccessibility {
    static func host(_ view: some View, showing identifier: String, size: NSSize = NSSize(width: 640, height: 480)) async throws -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "HostedAccessibility-\(UUID().uuidString)"
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        do {
            try await waitUntil { element(identifier, in: window) != nil }
        } catch {
            window.orderOut(nil)
            throw error
        }
        return window
    }

    static func element(_ identifier: String, in window: NSWindow) -> AXUIElement? {
        let root = children(kAXWindowsAttribute, of: AXUIElementCreateApplication(getpid()))
            .first { string(kAXTitleAttribute, of: $0) == window.title }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 20 else { return nil }
            if string(kAXIdentifierAttribute, of: element) == identifier {
                return element
            }
            for child in children(kAXChildrenAttribute, of: element) {
                if let found = find(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        return root.flatMap { find($0, depth: 0) }
    }

    static func label(of element: AXUIElement) -> String? {
        let title = string(kAXTitleAttribute, of: element) ?? ""
        return title.isEmpty ? string(kAXDescriptionAttribute, of: element) : title
    }

    static func value(of element: AXUIElement) -> String? {
        string(kAXValueAttribute, of: element)
    }

    static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private static func children(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
