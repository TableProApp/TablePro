import Foundation
import os

@MainActor
@Observable
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    enum Level: Sendable {
        case normal
        case warning
        case critical
    }

    private(set) var currentLevel: Level = .normal

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MemoryPressureMonitor")
    private var source: DispatchSourceMemoryPressure?

    private init() {}

    func start() {
        guard source == nil else { return }

        let newSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )

        newSource.setEventHandler { @Sendable [weak self] in
            let event = newSource.data
            let level: Level
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            Self.logger.log("Memory pressure level: \(String(describing: level), privacy: .public)")
            Task { @MainActor in
                self?.currentLevel = level
            }
        }

        newSource.activate()
        source = newSource
    }

    nonisolated func availableMemoryBytes() -> Int {
        Int(os_proc_available_memory())
    }

    nonisolated func hasHeadroom(forBytes requiredBytes: Int) -> Bool {
        let available = availableMemoryBytes()
        guard available > 0 else { return true }
        return available > requiredBytes
    }

    nonisolated func textBudgetBytes() -> Int {
        Self.textBudgetBytes(availableBytes: availableMemoryBytes())
    }

    // A sixth of the headroom past the margin: the kept text, the four copies `exportFits` wants room for, and a
    // share for the rest of the app. The call answers 0 outside an app, where only the ceiling bounds it.
    nonisolated static func textBudgetBytes(availableBytes: Int) -> Int {
        guard availableBytes > 0 else { return textBudgetCeilingBytes }
        return min(textBudgetCeilingBytes, max(0, availableBytes - textBudgetMarginBytes) / 6)
    }

    nonisolated private static let textBudgetCeilingBytes = 64 * 1_024 * 1_024
    nonisolated private static let textBudgetMarginBytes = 64 * 1_024 * 1_024
}
