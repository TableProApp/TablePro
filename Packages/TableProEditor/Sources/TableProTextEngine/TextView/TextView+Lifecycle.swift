//
//  TextView+Lifecycle.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 4/7/25.
//

import AppKit

public extension TextView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        layoutManager.layoutLines()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        guard let clipView = newSuperview as? NSClipView,
              let scrollView = enclosingScrollView ?? clipView.enclosingScrollView else {
            return
        }

        setUpScrollListeners(scrollView: scrollView)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateFrameIfNeeded()
    }

    /// AppKit redraws the text, but the emphasis layers hold colors resolved for the old appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        emphasisManager?.refreshColors()
    }
}
