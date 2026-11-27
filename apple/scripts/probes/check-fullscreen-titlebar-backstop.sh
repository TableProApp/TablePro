#!/usr/bin/env bash
#
# Check why ContentWindow keeps its titlebar opaque in full screen, and why the editor tab strip resolves its
# fills in the non-vibrant appearance (#4498).
#
# In full screen the titlebar moves into NSToolbarFullScreenWindow. With a custom window backgroundColor and a
# transparent titlebar, AppKit hides the titlebar backgrounds and shows an opaque NSOpaqueBackstop layer under
# one titlebar section, the sidebar's when the split has an inspector item. The system color keeps it hidden,
# but handing it back at willEnterFullScreen comes too late. An opaque titlebar hides it, and gives the
# titlebar accessory a vibrant appearance. The window copies the main window: sidebar, content, collapsed
# inspector, unified toolbar and a bottom titlebar accessory.
#
# Usage:
#   scripts/probes/check-fullscreen-titlebar-backstop.sh
#
# Opens a window, enters full screen for a few seconds per case and leaves it. Exits 0 when all four cases
# hold, 1 when one does not, and 3 when the check could not run.

set -uo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit

let transparent = CommandLine.arguments.contains("--transparent")
let customColor = CommandLine.arguments.contains("--custom-color")
let handsBack = CommandLine.arguments.contains("--hand-back")

final class ToolbarDelegate: NSObject, NSToolbarDelegate {
    let ids: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? { NSToolbarItem(itemIdentifier: id) }
}

final class Pane: NSViewController {
    override func loadView() { view = NSView() }
}

final class Accessory: NSTitlebarAccessoryViewController {
    let marker = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 36))
        view.addSubview(marker)
    }
}

func backstopShown(in window: NSWindow) -> Bool? {
    var found: Bool?
    func walk(_ layer: CALayer) {
        if layer.name == "NSOpaqueBackstop" { found = (found ?? false) || !layer.isHidden }
        layer.sublayers?.forEach(walk)
    }
    if let root = window.contentView?.superview?.layer { walk(root) }
    return found
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let toolbarDelegate = ToolbarDelegate()
    let accessory = Accessory()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: Pane())
        sidebar.minimumThickness = 300
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: Pane()))
        let inspector = NSSplitViewItem(inspectorWithViewController: Pane())
        inspector.canCollapse = true
        inspector.isCollapsed = true
        split.addSplitViewItem(inspector)
        window.contentViewController = split
        let toolbar = NSToolbar(identifier: "backstop-probe")
        toolbar.delegate = toolbarDelegate
        window.toolbar = toolbar
        accessory.layoutAttribute = .bottom
        accessory.automaticallyAdjustsSize = false
        accessory.fullScreenMinHeight = 36
        window.addTitlebarAccessoryViewController(accessory)
        window.titlebarAppearsTransparent = transparent
        if customColor { window.backgroundColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.2, alpha: 1) }
        if handsBack {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.window.backgroundColor = .windowBackgroundColor }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.window.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.report() }
    }

    func report() {
        guard window.styleMask.contains(.fullScreen),
              let bar = NSApp.windows.first(where: { "\(type(of: $0))" == "NSToolbarFullScreenWindow" })
        else {
            print("UNAVAILABLE: the window did not enter full screen")
            exit(3)
        }
        let vibrant = accessory.marker.effectiveAppearance.name.rawValue.contains("Vibrant")
        switch backstopShown(in: bar) {
        case nil: print("UNAVAILABLE: no NSOpaqueBackstop layer in the full-screen toolbar window")
        case let shown?: print("\(shown ? "backstop shown" : "backstop hidden"), \(vibrant ? "vibrant" : "not vibrant")")
        }
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT

if ! swiftc -O "$WORK/main.swift" -o "$WORK/probe" 2>"$WORK/build.log"; then
    cat "$WORK/build.log"
    echo "INCONCLUSIVE: the probe did not compile"
    exit 3
fi

custom="$("$WORK/probe" --transparent --custom-color)"
system="$("$WORK/probe" --transparent)"
handed="$("$WORK/probe" --transparent --custom-color --hand-back)"
opaque="$("$WORK/probe" --custom-color)"
echo "transparent titlebar, custom color:           $custom"
echo "transparent titlebar, system color:           $system"
echo "transparent titlebar, color handed back late: $handed"
echo "opaque titlebar, custom color:                $opaque"

case "$custom$system$handed$opaque" in
    *UNAVAILABLE*) echo "INCONCLUSIVE"; exit 3 ;;
esac
if [[ "$custom" == "backstop shown, not vibrant" && "$system" == "backstop hidden, not vibrant" \
    && "$handed" == "backstop shown, not vibrant" && "$opaque" == "backstop hidden, vibrant" ]]; then
    echo "PASS: a transparent titlebar shows the backstop under a custom color, an opaque one never does"
    exit 0
fi
echo "FAIL: AppKit changed; recheck ContentWindow.titlebarIsTransparent and EditorTabStripPalette.drawing"
exit 1
