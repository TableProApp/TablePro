//
//  AccountDevice.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

// A device of the account as GET /v2/devices or a device_limit_reached answer lists it.
internal struct AccountDevice: Equatable, Sendable, Identifiable {
    let id: String
    let machineID: String
    let name: String
    let platform: String
    let osVersion: String
    let lastSeenAt: Date
    let holdsLicense: Bool
    let offlineUntil: Date?

    init(
        id: String,
        machineID: String,
        name: String,
        platform: String,
        osVersion: String,
        lastSeenAt: Date,
        holdsLicense: Bool,
        offlineUntil: Date?
    ) {
        self.id = id
        self.machineID = machineID
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
        self.lastSeenAt = lastSeenAt
        self.holdsLicense = holdsLicense
        self.offlineUntil = offlineUntil
    }

    init(_ device: Components.Schemas.Device) {
        self.init(
            id: device.id,
            machineID: device.machineId,
            name: device.name,
            platform: OpenCode.of(device.platform),
            osVersion: device.osVersion,
            lastSeenAt: device.lastSeenAt,
            holdsLicense: device.licensedAt != nil,
            offlineUntil: device.offlineUntil
        )
    }

    init(_ device: Components.Schemas.LicensedDevice) {
        self.init(
            id: device.id,
            machineID: device.machineId,
            name: device.name,
            platform: OpenCode.of(device.platform),
            osVersion: device.osVersion,
            lastSeenAt: device.lastSeenAt,
            holdsLicense: true,
            offlineUntil: device.offlineUntil
        )
    }

    // A device with a live offline file keeps its slot: the server refuses to remove it (409 offline_file_active).
    func offlineFileValid(at now: Date) -> Bool {
        offlineUntil.map { $0 > now } ?? false
    }
}
