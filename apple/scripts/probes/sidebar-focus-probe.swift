import AppKit

// The two AppKit facts SidebarOutlineView and WorkspacePaneHost are built on, measured in a really key window:
// 1. A source list that takes first responder inside its own viewDidMoveToWindow, with its rows already laid out,
//    keeps every row unemphasized; one main-queue turn later it is emphasized.
// 2. At first show, a window whose initialFirstResponder refuses focus walks on to the next valid key view, unless
//    that view names none while the window is not visible; Tab from the empty window still works afterwards.
// check-sidebar-focus.sh builds this as an app bundle and launches it, since only a foreground app gets a key window.

let outputPath = CommandLine.arguments.dropFirst().first ?? "/dev/stdout"
var lines: [String] = []

func report(_ line: String) {
    lines.append(line)
}

final class Rows: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let items: [NSString] = ["alpha", "beta", "gamma", "delta"]

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: String(describing: item))
        label.frame = NSRect(x: 4, y: 2, width: 160, height: 18)
        cell.addSubview(label)
        return cell
    }
}

final class AdoptingOutline: NSOutlineView {
    var defersAdoption = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        guard defersAdoption else {
            adopt(in: window)
            return
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.adopt(in: window)
        }
    }

    private func adopt(in window: NSWindow) {
        guard window.firstResponder === window else { return }
        window.makeFirstResponder(self)
    }
}

final class FirstFocusContainer: NSView {
    var namesNoKeyViewUntilVisible = false

    override var acceptsFirstResponder: Bool { false }

    override var nextValidKeyView: NSView? {
        guard !namesNoKeyViewUntilVisible || window?.isVisible == true else { return nil }
        return super.nextValidKeyView
    }
}

func responderName(_ responder: NSResponder?, in window: NSWindow) -> String {
    guard let responder else { return "nil" }
    if responder === window { return "window" }
    if let editor = responder as? NSTextView, editor.delegate is NSTextField { return "field" }
    return String(describing: type(of: responder))
}

@MainActor
func emphasisCase(defers: Bool, then next: @escaping () -> Void) {
    let rows = Rows()
    let outline = AdoptingOutline(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
    outline.defersAdoption = defers
    outline.style = .sourceList
    outline.headerView = nil
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column"))
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.dataSource = rows
    outline.delegate = rows
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
    scroll.documentView = outline
    outline.reloadData()
    outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    // SwiftUI sizes and lays out a representable before it puts it in the window.
    scroll.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()

    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 500, height: 320),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
    window.makeKeyAndOrderFront(nil)
    window.contentView?.addSubview(scroll)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        let row = outline.rowView(atRow: 2, makeIfNecessary: false)
        let label = defers ? "deferred" : "inside-move"
        report("emphasis \(label): key=\(window.isKeyWindow) firstResponderIsList=\(window.firstResponder === outline) "
            + "rowEmphasized=\(row?.isEmphasized ?? false)")
        _ = rows
        window.orderOut(nil)
        next()
    }
}

@MainActor
func firstFocusCase(namesNoKeyViewUntilVisible: Bool) {
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 700, height: 400),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.autorecalculatesKeyViewLoop = true
    let sidebar = NSViewController()
    sidebar.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    sidebar.view.addSubview(NSSearchField(frame: NSRect(x: 10, y: 360, width: 180, height: 22)))
    let container = FirstFocusContainer(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    container.namesNoKeyViewUntilVisible = namesNoKeyViewUntilVisible
    let detail = NSViewController()
    detail.view = container
    let split = NSSplitViewController()
    split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebar))
    split.addSplitViewItem(NSSplitViewItem(viewController: detail))
    window.contentViewController = split
    window.initialFirstResponder = container

    window.makeKeyAndOrderFront(nil)
    let atShow = responderName(window.firstResponder, in: window)
    _ = window.makeFirstResponder(nil)
    window.selectNextKeyView(nil)
    let afterTab = responderName(window.firstResponder, in: window)
    let label = namesNoKeyViewUntilVisible ? "none-until-visible" : "plain"
    report("first-focus \(label): key=\(window.isKeyWindow) atShow=\(atShow) tabFromEmpty=\(afterTab)")
    window.orderOut(nil)
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                report("os \(ProcessInfo.processInfo.operatingSystemVersionString) active=\(NSApp.isActive)")
                firstFocusCase(namesNoKeyViewUntilVisible: false)
                firstFocusCase(namesNoKeyViewUntilVisible: true)
                emphasisCase(defers: false) {
                    emphasisCase(defers: true) {
                        let text = lines.joined(separator: "\n") + "\n"
                        try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
