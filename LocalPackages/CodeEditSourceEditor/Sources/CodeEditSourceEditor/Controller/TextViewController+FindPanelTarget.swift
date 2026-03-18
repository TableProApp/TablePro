//
//  TextViewController+FindPanelTarget.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/16/25.
//

import AppKit
import CodeEditTextView

extension TextViewController: FindPanelTarget {
    var findPanelTargetView: NSView {
        textView
    }

    func findPanelWillShow(panelHeight: CGFloat) {
        updateContentInsets()
    }

    func findPanelWillHide(panelHeight: CGFloat) {
        updateContentInsets()
    }

    func findPanelModeDidChange(to mode: FindPanelMode) {
        updateContentInsets()
    }

    var emphasisManager: EmphasisManager? {
        textView?.emphasisManager
    }
}
