//
//  TextViewController+ReloadUI.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/17/25.
//

import AppKit

extension TextViewController {
    func reloadUI() {
        configuration.didSetOnController(controller: self, oldConfig: nil)

        styleScrollView()
        styleTextView()

        minimapView.updateContentViewHeight()
        minimapView.updateDocumentVisibleViewPosition()
        reformattingGuideView.updatePosition(in: self)
    }
}
