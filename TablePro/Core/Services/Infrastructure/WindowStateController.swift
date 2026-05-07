//
//  WindowStateController.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor
internal final class WindowStateController {
    static let shared = WindowStateController()

    private static let logger = Logger(subsystem: "com.TablePro", category: "WindowState")

    private let defaults: UserDefaults
    private var bindings: [ObjectIdentifier: WindowStateBinding] = [:]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func applyFirstRunFrame(to window: NSWindow, policy: WindowFramePolicy) {
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        if let size = policy.firstRunSizing.contentSize(for: screenFrame) {
            window.setContentSize(size)
        }
        window.center()
    }

    fileprivate func releaseBinding(forWindowKey key: ObjectIdentifier) {
        bindings.removeValue(forKey: key)
    }
}

internal extension WindowStateController {
    func install(on window: NSWindow, policy: WindowFramePolicy) {
        window.setFrameAutosaveName(policy.autosaveName)

        if !window.setFrameUsingName(policy.autosaveName) {
            applyFirstRunFrame(to: window, policy: policy)
        }

        let key = ObjectIdentifier(window)
        bindings[key]?.invalidate()

        let restorePending = defaults.bool(forKey: policy.fullScreenStateKey)
        bindings[key] = WindowStateBinding(
            windowKey: key,
            window: window,
            policy: policy,
            defaults: defaults,
            restoreFullScreenOnFirstKey: restorePending,
            owner: self
        )
    }

    func hasPriorState(for policy: WindowFramePolicy) -> Bool {
        let frameKey = "NSWindow Frame \(policy.autosaveName)"
        let hasSavedFrame = defaults.object(forKey: frameKey) != nil
        let wasInFullScreen = defaults.bool(forKey: policy.fullScreenStateKey)
        return hasSavedFrame || wasInFullScreen
    }
}

@MainActor
private final class WindowStateBinding {
    private let windowKey: ObjectIdentifier
    private weak var window: NSWindow?
    private let policy: WindowFramePolicy
    private let defaults: UserDefaults
    private weak var owner: WindowStateController?

    private var liveObservers: [NSObjectProtocol] = []
    private var fullScreenRestoreObserver: NSObjectProtocol?

    init(
        windowKey: ObjectIdentifier,
        window: NSWindow,
        policy: WindowFramePolicy,
        defaults: UserDefaults,
        restoreFullScreenOnFirstKey: Bool,
        owner: WindowStateController
    ) {
        self.windowKey = windowKey
        self.window = window
        self.policy = policy
        self.defaults = defaults
        self.owner = owner

        attachLiveObservers()
        if restoreFullScreenOnFirstKey {
            attachFullScreenRestoreObserver()
        }
    }

    func invalidate() {
        let center = NotificationCenter.default
        for observer in liveObservers {
            center.removeObserver(observer)
        }
        liveObservers.removeAll()
        if let fullScreenRestoreObserver {
            center.removeObserver(fullScreenRestoreObserver)
            self.fullScreenRestoreObserver = nil
        }
    }

    private func attachLiveObservers() {
        guard let window else { return }
        let center = NotificationCenter.default

        liveObservers.append(center.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { [defaults, policy] _ in
            defaults.set(true, forKey: policy.fullScreenStateKey)
        })

        liveObservers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [defaults, policy] _ in
            defaults.set(false, forKey: policy.fullScreenStateKey)
        })

        liveObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.invalidate()
                self.owner?.releaseBinding(forWindowKey: self.windowKey)
            }
        })
    }

    private func attachFullScreenRestoreObserver() {
        guard let window else { return }
        let center = NotificationCenter.default

        fullScreenRestoreObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performFullScreenRestore()
            }
        }
    }

    private func performFullScreenRestore() {
        guard let window else { return }
        if let observer = fullScreenRestoreObserver {
            NotificationCenter.default.removeObserver(observer)
            fullScreenRestoreObserver = nil
        }
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
}
