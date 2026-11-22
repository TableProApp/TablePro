import AppKit
import ApplicationServices
@testable import TablePro
import SwiftUI
import TableProTestSupport
import Testing

@MainActor
struct SettingsFullPageListTests {
    private enum BarShape {
        case none
        case addMenu(canAdd: Bool)
        case status
    }

    private struct Page: View {
        static let rowCount = 40

        let shape: BarShape
        @State private var selection: Int?

        var body: some View {
            switch shape {
            case .none:
                SettingsFullPageList { list }
            case .addMenu(let canAdd):
                SettingsFullPageList {
                    list
                } bar: {
                    SettingsListBar(
                        addLabel: "Add Row",
                        removeLabel: "Remove Row",
                        canAdd: canAdd,
                        addIdentifier: "list-bar-test-add",
                        removeIdentifier: "list-bar-test-remove",
                        addMenu: { Button(action: {}) { Text(verbatim: "Import") } },
                        onRemove: {},
                        actionsLabel: "Row Actions",
                        actionsIdentifier: "list-bar-test-actions"
                    ) {
                        Button(action: {}) { Text(verbatim: "Duplicate") }
                    }
                }
            case .status:
                SettingsFullPageList {
                    list
                } bar: {
                    SettingsListBar {
                        Text(verbatim: "3 customized")
                    } trailing: {
                        Button(action: {}) { Text(verbatim: "Restore Defaults") }
                            .accessibilityIdentifier("list-bar-test-restore")
                    }
                }
            }
        }

        private var list: some View {
            List(selection: $selection) {
                ForEach(0..<Self.rowCount, id: \.self) { row in
                    Text(verbatim: "Row \(row)").tag(row)
                }
            }
        }
    }

    @MainActor
    private struct Hosted {
        let window: NSWindow
        let table: NSTableView
        let scrollView: NSScrollView

        var tolerance: CGFloat { 1 / window.backingScaleFactor }

        var scrollViewFrame: NSRect {
            window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
        }

        func scrollToEnd() {
            let clipView = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let end = documentHeight - clipView.bounds.height + scrollView.contentInsets.bottom
            clipView.scroll(to: NSPoint(x: 0, y: end))
            scrollView.reflectScrolledClipView(clipView)
        }

        func lastRowFrame() -> NSRect {
            let row = table.rect(ofRow: table.numberOfRows - 1)
            return window.convertToScreen(table.convert(row, to: nil))
        }
    }

    private static func host(_ shape: BarShape) async throws -> Hosted {
        let size = NSSize(width: 480, height: 360)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // A title of its own, so the accessibility lookup never reaches an earlier case's window.
        window.title = "SettingsFullPageListTests \(UUID().uuidString)"
        let hosting = NSHostingController(rootView: Page(shape: shape))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.orderFront(nil)

        let content = try #require(window.contentView)
        // The table fills its rows before its scroll view is laid out.
        try await waitUntil { (listTable(in: content)?.enclosingScrollView?.frame.height ?? 0) > 0 }
        let table = try #require(listTable(in: content))
        let scrollView = try #require(table.enclosingScrollView)
        return Hosted(window: window, table: table, scrollView: scrollView)
    }

    private static func listTable(in view: NSView) -> NSTableView? {
        var pending = [view]
        while let next = pending.popLast() {
            if let table = next as? NSTableView, table.numberOfRows == Page.rowCount {
                return table
            }
            pending.append(contentsOf: next.subviews)
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ identifier: String, under element: AXUIElement) -> AXUIElement? {
        if attribute("AXIdentifier", of: element) as? String == identifier {
            return element
        }
        for child in attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [] {
            if let match = Self.element(identifier, under: child) {
                return match
            }
        }
        return nil
    }

    private static func element(_ identifier: String, inWindowTitled title: String) -> AXUIElement? {
        let windows = attribute(kAXWindowsAttribute, of: AXUIElementCreateApplication(getpid())) as? [AXUIElement] ?? []
        guard let window = windows.first(where: { attribute(kAXTitleAttribute, of: $0) as? String == title }) else {
            return nil
        }
        return element(identifier, under: window)
    }

    private static func waitForElement(_ identifier: String, in hosted: Hosted) async throws -> AXUIElement {
        let title = hosted.window.title
        try await waitUntil { element(identifier, inWindowTitled: title) != nil }
        return try #require(element(identifier, inWindowTitled: title))
    }

    private static func axValue(_ name: String, of element: AXUIElement) -> AXValue? {
        guard let raw = attribute(name, of: element), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXValue.self)
    }

    // AX counts y down from the top of the primary screen; AppKit counts up from its bottom.
    private static func frame(of element: AXUIElement) throws -> NSRect {
        let positionValue = try #require(axValue(kAXPositionAttribute, of: element))
        let sizeValue = try #require(axValue(kAXSizeAttribute, of: element))
        var position = CGPoint.zero
        var size = CGSize.zero
        let readPosition = AXValueGetValue(positionValue, .cgPoint, &position)
        let readSize = AXValueGetValue(sizeValue, .cgSize, &size)
        try #require(readPosition && readSize)
        let screenHeight = try #require(NSScreen.screens.first).frame.height
        return NSRect(x: position.x, y: screenHeight - position.y - size.height, width: size.width, height: size.height)
    }

    private static func name(of element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute($0, of: element) as? String }
    }

    @Test("The bar sits on the list's bottom edge, inside its border")
    func barSitsInsideTheBorder() async throws {
        let hosted = try await Self.host(.addMenu(canAdd: true))
        defer { hosted.window.orderOut(nil) }

        let removeElement = try await Self.waitForElement("list-bar-test-remove", in: hosted)
        let remove = try Self.frame(of: removeElement)
        let border = hosted.scrollViewFrame
        #expect(border.insetBy(dx: -hosted.tolerance, dy: -hosted.tolerance).contains(remove), "\(remove) should sit inside \(border)")
        #expect(remove.minY - border.minY < ListBarMetrics.height, "The bar should sit on the list's bottom edge")
        #expect(hosted.scrollView.contentInsets.bottom >= ListBarMetrics.height)
    }

    @Test("Scrolled to the end, the last row sits above the bar")
    func lastRowScrollsClearOfTheBar() async throws {
        let hosted = try await Self.host(.addMenu(canAdd: true))
        defer { hosted.window.orderOut(nil) }

        let removeElement = try await Self.waitForElement("list-bar-test-remove", in: hosted)
        let remove = try Self.frame(of: removeElement)
        hosted.scrollToEnd()
        let lastRow = hosted.lastRowFrame()
        #expect(lastRow.minY >= remove.maxY - hosted.tolerance, "Last row \(lastRow) runs under the bar at \(remove)")
    }

    @Test("The add and actions menus are named menu buttons, and the add menu follows canAdd")
    func glyphMenusAreNamedMenuButtons() async throws {
        let hosted = try await Self.host(.addMenu(canAdd: false))
        defer { hosted.window.orderOut(nil) }

        let add = try await Self.waitForElement("list-bar-test-add", in: hosted)
        #expect(Self.attribute(kAXRoleAttribute, of: add) as? String == kAXMenuButtonRole)
        #expect(Self.name(of: add).contains("Add Row"))
        #expect(Self.attribute(kAXEnabledAttribute, of: add) as? Bool == false)

        let actions = try await Self.waitForElement("list-bar-test-actions", in: hosted)
        #expect(Self.attribute(kAXRoleAttribute, of: actions) as? String == kAXMenuButtonRole)
        #expect(Self.name(of: actions).contains("Row Actions"))
        #expect(Self.attribute(kAXEnabledAttribute, of: actions) as? Bool == true)
    }

    @Test("A bar without + and − keeps its trailing button inside the border")
    func statusBarKeepsItsButtonInside() async throws {
        let hosted = try await Self.host(.status)
        defer { hosted.window.orderOut(nil) }

        let restoreElement = try await Self.waitForElement("list-bar-test-restore", in: hosted)
        let restore = try Self.frame(of: restoreElement)
        let border = hosted.scrollViewFrame
        #expect(border.insetBy(dx: -hosted.tolerance, dy: -hosted.tolerance).contains(restore), "\(restore) should sit inside \(border)")
        #expect(restore.minY - border.minY < ListBarMetrics.height, "The button should sit in the bar")
    }

    @Test("Without a bar, the last row scrolls down to the list's bottom edge")
    func noBarLeavesNoGap() async throws {
        let hosted = try await Self.host(.none)
        defer { hosted.window.orderOut(nil) }

        hosted.scrollToEnd()
        let gap = hosted.lastRowFrame().minY - hosted.scrollViewFrame.minY
        #expect(gap < ListBarMetrics.height, "Scrolled to the end, \(gap)pt stays empty under the last row")
        #expect(hosted.scrollView.contentInsets.bottom == 0)
    }
}
