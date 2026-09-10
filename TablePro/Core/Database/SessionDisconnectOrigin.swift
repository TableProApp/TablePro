//
//  SessionDisconnectOrigin.swift
//  TablePro
//

import Foundation

/// Who ended the session. A closing window or a tool call is the app tidying up after itself; a
/// user choosing Disconnect is a decision the window has to reflect and "Reopen Last Session" has
/// to respect. Defaulting to `appManaged` keeps quit and window close out of the user-intent path.
internal enum SessionDisconnectOrigin: Equatable, Sendable {
    case appManaged
    case userRequested
}
