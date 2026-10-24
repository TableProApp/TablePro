//
//  MainThreadStallMonitor.swift
//  TablePro
//

import AppKit

// Each main run loop turn that kept the thread busy for 50 ms or more, on standard error next to the
// interaction traces, so a benchmark can hold every traced path to #3661's 100 ms rule.
@MainActor
internal final class MainThreadStallMonitor {
    private static var shared: MainThreadStallMonitor?
    private static let reportThreshold: TimeInterval = 0.05

    private var observers: [CFRunLoopObserver] = []
    private var busySince: TimeInterval?

    internal static func startIfRequested() {
        guard InteractionTracer.writesToStandardError, shared == nil else { return }
        let monitor = MainThreadStallMonitor()
        monitor.start()
        shared = monitor
    }

    // The turn starts before any other observer and ends after the last one, Core Animation's commit included.
    private func start() {
        let handler: (CFRunLoopObserver?, CFRunLoopActivity) -> Void = { [weak self] _, activity in
            MainActor.assumeIsolated { self?.observe(activity) }
        }
        let starts: CFRunLoopActivity = [.entry, .afterWaiting]
        let ends: CFRunLoopActivity = [.beforeWaiting, .exit]
        for (activities, order) in [(starts, CFIndex.min), (ends, CFIndex.max)] {
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, order, handler)
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            if let observer { observers.append(observer) }
        }
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        switch activity {
        case .afterWaiting:
            busySince = now
        case .entry:
            // Work between a nested loop's exit and the next entry belongs to the turn already running.
            if busySince == nil { busySince = now }
        default:
            if let busySince, now - busySince >= Self.reportThreshold {
                let line = String(format: "stall ms=%.1f end=%.3f\n", (now - busySince) * 1_000, now)
                FileHandle.standardError.write(Data(line.utf8))
            }
            // A nested loop that exits hands the thread back to the outer turn, which keeps working.
            busySince = activity == .exit ? now : nil
        }
    }
}
