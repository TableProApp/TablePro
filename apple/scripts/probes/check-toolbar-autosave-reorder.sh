#!/usr/bin/env bash
#
# Check how NSToolbar's autosaved configuration treats a reordered default item list, which decides whether
# MainWindowToolbar.toolbarIdentifier has to be bumped when defaultItemIdentifiers changes order.
#
# A toolbar nobody customized must take the new order on the next launch, and one a user rearranged must keep
# theirs. Each launch is a separate process under one autosave identifier, as an app update is.
#
# Usage:
#   scripts/probes/check-toolbar-autosave-reorder.sh
#
# Writes only to the probe binary's own defaults domain and deletes it at the end. Exits 0 when both cases hold,
# 1 when one does not, and 3 when the check could not run.

set -uo pipefail

WORK="$(mktemp -d)"
DOMAIN="toolbar-reorder-probe"
trap 'defaults delete "$DOMAIN" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit

let ids = ["a", "b", "c", "d"].map { NSToolbarItem.Identifier("probe." + $0) }

final class Delegate: NSObject, NSToolbarDelegate {
    let order: [NSToolbarItem.Identifier]
    init(order: [NSToolbarItem.Identifier]) { self.order = order }
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue
        item.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { order }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
}

let reordered = CommandLine.arguments[1] == "reordered"
let customize = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "customize"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate(order: reordered ? [ids[0], ids[2], ids[3], ids[1]] : ids)
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
let toolbar = NSToolbar(identifier: "probe.reorder.toolbar")
toolbar.delegate = delegate
toolbar.allowsUserCustomization = true
toolbar.autosavesConfiguration = true
window.toolbar = toolbar
window.orderFront(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    if customize, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == ids[3] }) {
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: ids[3], at: 0)
    }
    print(toolbar.items.map { $0.itemIdentifier.rawValue.replacingOccurrences(of: "probe.", with: "") }.joined(separator: ","))
    UserDefaults.standard.synchronize()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
app.run()
SWIFT

swiftc -O "$WORK/main.swift" -o "$WORK/$DOMAIN" >/dev/null 2>&1 || {
    echo "the probe did not compile" >&2
    exit 3
}

status=0
defaults delete "$DOMAIN" >/dev/null 2>&1
"$WORK/$DOMAIN" original >/dev/null
uncustomized="$("$WORK/$DOMAIN" reordered)"
if [ "$uncustomized" = "a,c,d,b" ]; then
    echo "PASS uncustomized toolbar takes the new default order ($uncustomized)"
else
    echo "FAIL uncustomized toolbar kept $uncustomized, expected a,c,d,b"
    status=1
fi

defaults delete "$DOMAIN" >/dev/null 2>&1
"$WORK/$DOMAIN" original customize >/dev/null
customized="$("$WORK/$DOMAIN" reordered)"
if [ "$customized" = "d,a,b,c" ]; then
    echo "PASS customized toolbar keeps the user's order ($customized)"
else
    echo "FAIL customized toolbar showed $customized, expected d,a,b,c"
    status=1
fi

exit $status
