//
//  ManagedPolicyCenter.swift
//  TablePro
//

import Combine
import CoreServices
import Foundation
import os

// The managed values this run holds. Read at launch, and again whenever the system writes a configuration profile's
// preferences while the app runs (core ADR 0055, When a value applies).
@MainActor
internal final class ManagedPolicyCenter: ObservableObject {
    static let shared = ManagedPolicyCenter(reader: ManagedPolicyReader.shared)

    @Published private(set) var snapshot: ManagedPolicySnapshot

    private let reader: any ManagedPolicyReading
    private var monitor: ManagedPreferencesMonitor?

    init(reader: any ManagedPolicyReading) {
        self.reader = reader
        snapshot = ManagedPolicySnapshot(reading: reader)
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = ManagedPreferencesMonitor { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        // cfprefsd caches the domain; a profile installed since the last read is seen only after this.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let next = ManagedPolicySnapshot(reading: reader)
        guard next != snapshot else { return }
        snapshot = next
    }
}

// macOS writes a configuration profile's preferences under /Library/Managed Preferences, per user and for the whole
// Mac, and posts no notification a process can observe for a key with dots in its name.
private final class ManagedPreferencesMonitor: @unchecked Sendable {
    private static let directory = "/Library/Managed Preferences"
    private static let logger = Logger(subsystem: "com.TablePro", category: "ManagedPolicy")

    nonisolated private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<ManagedPreferencesMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
    }

    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.TablePro.managedPreferences")
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            [Self.directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        ) else {
            Self.logger.error("Managed preferences are read at launch only: the folder could not be watched")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
