//
//  ExportSheetPresenter.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class ExportSheetPresenter {
    private var sheetWindow: NSWindow?
    private weak var parentWindow: NSWindow?

    internal init() {}

    internal var isPresenting: Bool {
        sheetWindow != nil
    }

    @discardableResult
    internal func present(_ request: DataSourceExportRequest, on parent: NSWindow) -> Bool {
        present(.dataSource(request), on: parent)
    }

    @discardableResult
    internal func present(_ mode: ExportMode, on parent: NSWindow) -> Bool {
        guard sheetWindow == nil, parent.attachedSheet == nil else { return false }
        let hosting = NSHostingController(rootView: ExportDialog(isPresented: presentationBinding, mode: mode))
        let sheet = NSWindow(contentViewController: hosting)
        sheet.isReleasedWhenClosed = false
        sheetWindow = sheet
        parentWindow = parent
        parent.beginSheet(sheet)
        return true
    }

    internal func dismiss() {
        guard let sheet = sheetWindow else { return }
        sheetWindow = nil
        let parent = parentWindow
        parentWindow = nil
        if let parent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        sheet.contentViewController = nil
    }

    private var presentationBinding: Binding<Bool> {
        Binding(
            get: { [weak self] in self?.sheetWindow != nil },
            set: { [weak self] isPresented in
                guard !isPresented else { return }
                self?.dismiss()
            }
        )
    }
}
