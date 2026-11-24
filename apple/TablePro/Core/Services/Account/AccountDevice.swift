//
//  AccountDevice.swift
//  TablePro
//

import Foundation

// A device of the account as the core lists it, or names it in a device_limit_reached answer.
internal struct AccountDevice: Equatable, Sendable, Identifiable {
    let id: String
    let machineID: String
    let name: String
    let platform: String
    let osVersion: String
    let lastSeenAt: Date
    let holdsLicense: Bool
    let offlineUntil: Date?

    // A device with a live offline file keeps its slot: the server refuses to remove it (409 offline_file_active).
    func offlineFileValid(at now: Date) -> Bool {
        offlineUntil.map { $0 > now } ?? false
    }
}
