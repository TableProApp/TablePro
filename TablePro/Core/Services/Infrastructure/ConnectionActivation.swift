//
//  ConnectionActivation.swift
//  TablePro
//

import AppKit
import Foundation

/// Going to a saved connection means raising the window it already has, or opening one
/// for it. A window never changes which connection it shows, so every surface that
/// offers a list of connections routes here rather than retargeting anything in place.
@MainActor
internal enum ConnectionActivation {
    internal static func open(connectionId: UUID) async {
        do {
            try await TabRouter.shared.route(.openConnection(connectionId))
        } catch {
            AlertHelper.showErrorSheet(
                title: String(localized: "Connection Failed"),
                message: error.localizedDescription,
                window: NSApp.keyWindow
            )
        }
    }
}
