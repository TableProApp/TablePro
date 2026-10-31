//
//  SupportAskSheetPresenter.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal protocol SupportAskPresenting: AnyObject {
    var isPresenting: Bool { get }

    /// Attaches the ask to `parent`. Returns false, and calls nothing, when it cannot.
    func present(usageDays: Int, on parent: NSWindow, answer: @escaping (SupportAskAnswer) -> Void) -> Bool
}

/// Runs the ask as a sheet on the window in use, the shape `ExportSheetPresenter` uses.
///
/// Every way the sheet can go reports exactly one answer: a button, Escape, which is Not Now, or
/// the window closing under it, which counts as Not Now too.
@MainActor
internal final class SupportAskSheetPresenter: SupportAskPresenting {
    private var sheetWindow: NSWindow?
    private weak var parentWindow: NSWindow?
    private var report: ((SupportAskAnswer) -> Void)?
    private var parentCloseObserver: NSObjectProtocol?

    internal init() {}

    internal var isPresenting: Bool {
        sheetWindow != nil
    }

    internal func present(
        usageDays: Int,
        on parent: NSWindow,
        answer: @escaping (SupportAskAnswer) -> Void
    ) -> Bool {
        guard sheetWindow == nil, parent.attachedSheet == nil else { return false }

        let view = SupportAskView(usageDays: usageDays) { [weak self] choice in
            self?.finish(with: choice)
        }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: hosting)
        sheet.isReleasedWhenClosed = false

        sheetWindow = sheet
        parentWindow = parent
        report = answer
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parent,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(with: .notNow) }
        }
        parent.beginSheet(sheet)
        return true
    }

    private func finish(with choice: SupportAskAnswer) {
        guard let sheet = sheetWindow else { return }
        let reportAnswer = report
        let parent = parentWindow

        sheetWindow = nil
        parentWindow = nil
        report = nil
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
        }
        parentCloseObserver = nil

        if let parent, parent.attachedSheet === sheet {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        sheet.contentViewController = nil
        reportAnswer?(choice)
    }
}
