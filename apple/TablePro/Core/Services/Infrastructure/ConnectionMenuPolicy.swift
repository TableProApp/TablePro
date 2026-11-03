//
//  ConnectionMenuPolicy.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

/// A context menu shows only what applies to the row it was opened on, so the rail and Welcome hide
/// a command that does not apply rather than dimming it. The menu bar does the opposite and keeps
/// its commands visible, which is why the two surfaces ask different questions here.
internal enum ConnectionMenuPolicy {
    // A lost connection whose session entry has already gone holds nothing left to end.
    internal static func showsDisconnect(status: ConnectionDisplayStatus, holdsSession: Bool) -> Bool {
        holdsSession && ConnectionStatusPresentation(status).offersDisconnect
    }

    internal static func primaryAction(status: ConnectionDisplayStatus) -> ConnectionStatusAction? {
        ConnectionStatusPresentation(status).primaryAction
    }
}
