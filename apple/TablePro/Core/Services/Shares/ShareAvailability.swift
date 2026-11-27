//
//  ShareAvailability.swift
//  TablePro
//

import AppKit

// Share links live on tablepro.app, and a company server keeps none, so while signed in to one no share command
// shows. Opening a tablepro.app link someone sent still works.
@MainActor
internal enum ShareAvailability {
    static var isAvailable: Bool {
        isAvailable(in: FeatureAccess.shared.state)
    }

    nonisolated static func isAvailable(in state: AccountState) -> Bool {
        state.server.isProduction
    }

    // Signed in where shared links live; a company sign-in is none.
    nonisolated static func isSignedIn(_ state: AccountState) -> Bool {
        state.isSignedIn && isAvailable(in: state)
    }
}

// File > Share Query…, Share Result… and Manage Shared Links…, with the separator after them.
@MainActor
internal enum SharingMenuGroup {
    internal static let separatorIdentifier = NSUserInterfaceItemIdentifier("file.share.separator")

    private static let actions: Set<Selector> = [
        #selector(MainSplitViewController.shareQuery(_:)),
        #selector(MainSplitViewController.shareQueryResult(_:)),
        #selector(AppDelegate.manageSharedLinks(_:))
    ]

    internal static func update(in menu: NSMenu) {
        setShown(ShareAvailability.isAvailable, in: menu)
    }

    internal static func setShown(_ shown: Bool, in menu: NSMenu) {
        for item in menu.items where item.identifier == separatorIdentifier || item.action.map(actions.contains) == true {
            // Runs on every modified keystroke, and an unchanged write still re-lays out an open menu.
            if item.isHidden == shown {
                item.isHidden = !shown
            }
        }
    }
}
