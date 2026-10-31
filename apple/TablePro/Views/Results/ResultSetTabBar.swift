//
//  ResultSetTabBar.swift
//  TablePro
//

import AppKit
import SwiftUI

// Two or more results: a tab per result for one-click switching, and the pull-down that lists them all and acts on the current one.
struct ResultSetTabBar: View {
    let model: ResultSetMenuModel
    let actions: ResultSetActions

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                if model.offersTabs {
                    row(showsTabs: true, isSpelledOut: true)
                    row(showsTabs: true, isSpelledOut: false)
                }
                row(showsTabs: false, isSpelledOut: true)
                row(showsTabs: false, isSpelledOut: false)
            }
            .padding(.horizontal, StatusBarChrome.horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: StatusBarChrome.height)
            .paneBarBackground()
            Divider()
        }
    }

    private func row(showsTabs: Bool, isSpelledOut: Bool) -> some View {
        HStack(spacing: StatusBarChrome.clusterSpacing) {
            if showsTabs {
                // SwiftUI sets a hosted control's size from its environment, so it is set here and not in the control.
                ResultSetTabs(model: model, onActivate: actions.activate)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            ResultSetMenu(model: model, isSpelledOut: isSpelledOut, actions: actions)
        }
    }
}

struct ResultSetTabs: NSViewRepresentable {
    let model: ResultSetMenuModel
    let onActivate: (UUID) -> Void

    func makeNSView(context: Context) -> ResultSetTabsControl {
        ResultSetTabsControl()
    }

    func updateNSView(_ control: ResultSetTabsControl, context: Context) {
        control.onActivate = onActivate
        control.apply(model)
    }

    // Always the width every tab needs, so `ViewThatFits` gives up the tabs rather than squeezing them.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: ResultSetTabsControl, context: Context) -> CGSize? {
        control.intrinsicContentSize
    }
}

// AppKit on purpose: a SwiftUI segmented or `.tabs` picker drops a segment's image, and the pin is what a tab must show (measured on macOS 27).
@MainActor
final class ResultSetTabsControl: NSSegmentedControl {
    var onActivate: ((UUID) -> Void)?
    private var resultIds: [UUID] = []
    private var activeIndex = -1

    init() {
        super.init(frame: .zero)
        trackingMode = .selectOne
        #if SDK_MACOS_27
        if #available(macOS 27.0, *) {
            role = .tabs
        }
        #endif
        target = self
        action = #selector(segmentChosen(_:))
        setAccessibilityLabel(String(localized: "Results"))
        setAccessibilityIdentifier("result-set-tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ResultSetTabsControl does not support NSCoder init")
    }

    func apply(_ model: ResultSetMenuModel) {
        if segmentCount != model.entries.count {
            segmentCount = model.entries.count
        }
        for (index, entry) in model.entries.enumerated() {
            let title = model.tabTitle(of: entry)
            if label(forSegment: index) != title {
                setLabel(title, forSegment: index)
            }
            setImage(entry.isPinned ? Self.pinImage : nil, forSegment: index)
            setToolTip(model.displayLabel(of: entry), forSegment: index)
        }
        resultIds = model.entries.map(\.id)
        activeIndex = model.entries.firstIndex(where: \.isActive) ?? -1
        selectedSegment = activeIndex
    }

    @objc private func segmentChosen(_ sender: NSSegmentedControl) {
        let chosen = selectedSegment
        // The model decides which tab is lit, so a switch the discard prompt cancels leaves the current one selected.
        selectedSegment = activeIndex
        guard resultIds.indices.contains(chosen), chosen != activeIndex else { return }
        onActivate?(resultIds[chosen])
    }

    private static let pinImage = NSImage(
        systemSymbolName: "pin.fill",
        accessibilityDescription: String(localized: "Pinned")
    )?.withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .small))
}
