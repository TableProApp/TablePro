//
//  WindowStateController.swift
//  TablePro
//

import AppKit
import Foundation
import os

private let windowStateLogger = Logger(subsystem: "com.TablePro", category: "WindowState")

@MainActor
internal final class WindowStateController {
    static let shared = WindowStateController()

    private let defaults: UserDefaults
    private var bindings: [ObjectIdentifier: WindowStateBinding] = [:]
    fileprivate private(set) var isTerminating = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observeApplicationLifecycle()
        windowStateLogger.info("[init] WindowStateController initialized")
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleApplicationWillTerminate()
            }
        }

        center.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let value = UserDefaults.standard.bool(forKey: WindowFramePolicy.editor.fullScreenStateKey)
                let frameKey = "NSWindow Frame \(WindowFramePolicy.editor.autosaveName)"
                let frame = UserDefaults.standard.object(forKey: frameKey) as? String ?? "<nil>"
                windowStateLogger.info("[launch] persisted editor.isFullScreen=\(value, privacy: .public) frame=\(frame, privacy: .public)")
            }
        }
    }

    private func handleApplicationWillTerminate() {
        isTerminating = true
        windowStateLogger.info("[terminate] applicationWillTerminate fired, snapshotting \(self.bindings.count) bindings")
        for binding in bindings.values {
            binding.captureCurrentFullScreenState()
        }
    }

    private func applyFirstRunFrame(to window: NSWindow, policy: WindowFramePolicy) {
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        if let size = policy.firstRunSizing.contentSize(for: screenFrame) {
            window.setContentSize(size)
        }
        window.center()
        windowStateLogger.info("[install] applied first-run frame for \(policy.autosaveName, privacy: .public) size=\(NSStringFromRect(window.frame), privacy: .public)")
    }

    fileprivate func releaseBinding(forWindowKey key: ObjectIdentifier) {
        bindings.removeValue(forKey: key)
    }
}

internal extension WindowStateController {
    func install(on window: NSWindow, policy: WindowFramePolicy) {
        let didSetAutosave = window.setFrameAutosaveName(policy.autosaveName)
        let restored = window.setFrameUsingName(policy.autosaveName)
        if !restored {
            applyFirstRunFrame(to: window, policy: policy)
        }

        let key = ObjectIdentifier(window)
        bindings[key]?.invalidate()

        let restorePending = defaults.bool(forKey: policy.fullScreenStateKey)
        windowStateLogger.info(
            "[install] \(policy.autosaveName, privacy: .public) didSetAutosave=\(didSetAutosave, privacy: .public) frameRestored=\(restored, privacy: .public) restoreFullScreen=\(restorePending, privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public) styleMask.fullScreen=\(window.styleMask.contains(.fullScreen), privacy: .public)"
        )

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

    func captureCurrentFullScreenState() {
        guard let window else {
            windowStateLogger.info("[snapshot] \(self.policy.autosaveName, privacy: .public) skipped, window is nil")
            return
        }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        defaults.set(isFullScreen, forKey: policy.fullScreenStateKey)
        windowStateLogger.info("[snapshot] \(self.policy.autosaveName, privacy: .public) wrote isFullScreen=\(isFullScreen, privacy: .public) frame=\(NSStringFromRect(window.frame), privacy: .public)")
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
            windowStateLogger.info("[event] willEnterFullScreen \(policy.autosaveName, privacy: .public) wrote isFullScreen=true")
        })

        liveObservers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isTerm = self.owner?.isTerminating == true
                windowStateLogger.info("[event] didExitFullScreen \(self.policy.autosaveName, privacy: .public) isTerminating=\(isTerm, privacy: .public)")
                guard !isTerm else { return }
                self.defaults.set(false, forKey: self.policy.fullScreenStateKey)
                windowStateLogger.info("[event] didExitFullScreen \(self.policy.autosaveName, privacy: .public) wrote isFullScreen=false")
            }
        })

        liveObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isTerm = self.owner?.isTerminating == true
                let isFullScreen = self.window?.styleMask.contains(.fullScreen) ?? false
                windowStateLogger.info("[event] willClose \(self.policy.autosaveName, privacy: .public) isTerminating=\(isTerm, privacy: .public) styleMask.fullScreen=\(isFullScreen, privacy: .public)")
                if isTerm && isFullScreen {
                    self.defaults.set(true, forKey: self.policy.fullScreenStateKey)
                    windowStateLogger.info("[event] willClose during terminate while fullscreen, locked isFullScreen=true")
                }
                self.invalidate()
                self.owner?.releaseBinding(forWindowKey: self.windowKey)
            }
        })
    }

    private func attachFullScreenRestoreObserver() {
        guard let window else { return }
        let center = NotificationCenter.default
        windowStateLogger.info("[install] \(self.policy.autosaveName, privacy: .public) registered didBecomeKey observer for fullscreen restore")

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
        let alreadyFullScreen = window.styleMask.contains(.fullScreen)
        windowStateLogger.info("[restore] \(self.policy.autosaveName, privacy: .public) didBecomeKey, alreadyFullScreen=\(alreadyFullScreen, privacy: .public) collectionBehaviorContainsFullScreenPrimary=\(window.collectionBehavior.contains(.fullScreenPrimary), privacy: .public)")
        guard !alreadyFullScreen else { return }
        window.toggleFullScreen(nil)
        windowStateLogger.info("[restore] \(self.policy.autosaveName, privacy: .public) toggleFullScreen called")
    }
}
