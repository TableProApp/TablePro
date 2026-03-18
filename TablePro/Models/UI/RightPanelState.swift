//
//  RightPanelState.swift
//  TablePro
//
//  Shared state object for the right panel, owned by ContentView.
//  Inspector data is now passed directly via InspectorContext instead
//  of being cached here.
//

import Foundation
import os

@MainActor @Observable final class RightPanelState {
    private static let isPresentedKey = "com.TablePro.rightPanel.isPresented"
    private static let panelWidthKey = "com.TablePro.rightPanel.width"
    private static let isPresentedChangedNotification = Notification.Name("com.TablePro.rightPanel.isPresentedChanged")
    private var isSyncing = false

    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 500
    static let defaultWidth: CGFloat = 320
    @ObservationIgnored private let _didTeardown = OSAllocatedUnfairLock(initialState: false)

    var isPresented: Bool {
        didSet {
            guard !isSyncing else { return }
            DispatchQueue.main.async { [self] in
                UserDefaults.standard.set(self.isPresented, forKey: Self.isPresentedKey)
                NotificationCenter.default.post(name: Self.isPresentedChangedNotification, object: self)
            }
        }
    }

    var panelWidth: CGFloat {
        didSet {
            let clamped = min(max(panelWidth, Self.minWidth), Self.maxWidth)
            if panelWidth != clamped { panelWidth = clamped }
            UserDefaults.standard.set(Double(clamped), forKey: Self.panelWidthKey)
        }
    }

    var activeTab: RightPanelTab = .details

    // Save closure — set by MainContentCommandActions, called by UnifiedRightPanelView
    var onSave: (() -> Void)?

    // Owned objects — lifted from MainContentView @StateObject
    let editState = MultiRowEditState()
    private var _aiViewModel: AIChatViewModel?
    var aiViewModel: AIChatViewModel {
        if _aiViewModel == nil {
            _aiViewModel = AIChatViewModel()
        }
        return _aiViewModel! // swiftlint:disable:this force_unwrapping
    }

    init() {
        self.isPresented = UserDefaults.standard.bool(forKey: Self.isPresentedKey)
        let savedWidth = UserDefaults.standard.double(forKey: Self.panelWidthKey)
        self.panelWidth = savedWidth > 0 ? min(max(savedWidth, Self.minWidth), Self.maxWidth) : Self.defaultWidth
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIsPresentedChanged(_:)),
            name: Self.isPresentedChangedNotification,
            object: nil
        )
    }

    /// Release all heavy data on disconnect so memory drops
    /// even if AppKit keeps the window alive.
    func teardown() {
        guard !_didTeardown.withLock({ $0 }) else { return }
        _didTeardown.withLock { $0 = true }
        onSave = nil
        _aiViewModel?.clearSessionData()
        editState.releaseData()
        NotificationCenter.default.removeObserver(self) // swiftlint:disable:this notification_center_detachment
    }

    deinit {
        if !_didTeardown.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(self)
        }
    }

    @objc private func handleIsPresentedChanged(_ notification: Notification) {
        guard let sender = notification.object as? RightPanelState, sender !== self else { return }
        let newValue = UserDefaults.standard.bool(forKey: Self.isPresentedKey)
        guard newValue != isPresented else { return }
        isSyncing = true
        isPresented = newValue
        isSyncing = false
    }
}
