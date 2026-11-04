//
//  MachineIdentity.swift
//  TablePro
//

import Foundation
import IOKit
import os
import SystemConfiguration

internal struct MachineDescription: Equatable, Sendable {
    let machineID: String
    let name: String
    let appVersion: String
    let osVersion: String

    static func current() -> MachineDescription {
        MachineDescription(
            machineID: MachineIdentity.shared.machineID,
            name: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac",
            appVersion: Bundle.main.appVersion,
            osVersion: osVersion(ProcessInfo.processInfo.operatingSystemVersion)
        )
    }

    static func osVersion(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }
}

// The SHA-256 of the hardware UUID, the value the license system registered, so migrated devices match.
internal final class MachineIdentity: Sendable {
    static let shared = MachineIdentity(defaults: AppStorageEnvironment.shared.defaults)

    static let fallbackKey = "com.TablePro.license.fallbackMachineId"

    private let defaults: UserDefaults
    private let cached = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var machineID: String {
        cached.withLock { value in
            if let value { return value }
            let computed = Self.compute(hardwareUUID: Self.hardwareUUID(), defaults: defaults)
            value = computed
            return computed
        }
    }

    static func compute(hardwareUUID: String?, defaults: UserDefaults) -> String {
        if let hardwareUUID {
            return hardwareUUID.sha256
        }
        if let existing = defaults.string(forKey: fallbackKey) {
            return existing.sha256
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: fallbackKey)
        return generated.sha256
    }

    private static func hardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }
        guard platformExpert != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }
}
