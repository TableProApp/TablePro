//
//  ConnectionOrigin.swift
//  TablePro
//

import Foundation

// Never synced, exported or shared. Prompt wording, and the one-time env-var migration approves only thisMac rows.
internal enum ConnectionOrigin: String, Codable, Sendable {
    case thisMac
    case imported
    case synced
    case link
    case linkedFolder
    case teamLibrary
}
