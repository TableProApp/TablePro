//
//  ConnectionMenuPolicy.swift
//  TablePro
//

import Foundation

/// A context menu shows only what applies to the row it was opened on, so the rail hides Disconnect
/// on a workspace with no live session rather than dimming it. The menu bar does the opposite and
/// keeps both commands visible, which is why the two surfaces ask different questions here.
internal enum ConnectionMenuPolicy {
    internal static func showsDisconnect(status: ConnectionStatus) -> Bool {
        status.isConnected
    }
}
