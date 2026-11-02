//
//  ConnectionStatusMark.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

internal extension ConnectionStatusTint {
    var nsColor: NSColor {
        switch self {
        case .secondary: .secondaryLabelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    var color: Color {
        switch self {
        case .secondary: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}

// The mark a row shows beside a connection's name: a spinner while it dials, a symbol when it is
// lost or failed, and nothing at rest.
internal struct ConnectionStatusMark: View {
    let presentation: ConnectionStatusPresentation

    var body: some View {
        switch presentation.symbol {
        case .progress:
            ProgressView()
                .controlSize(.mini)
                .help(presentation.help ?? "")
                .accessibilityLabel(Text(presentation.accessibilityStatus))
        case .lost, .failed:
            if let name = presentation.symbol?.systemName {
                Image(systemName: name)
                    .imageScale(.small)
                    .selectionAwareTint(presentation.tint.color)
                    .help(presentation.help ?? "")
                    .accessibilityLabel(Text(presentation.accessibilityStatus))
            }
        case nil:
            EmptyView()
        }
    }
}

// AppKit twin of `ConnectionStatusMark` for the rail cell, which is an `NSTableCellView`.
@MainActor
internal final class ConnectionStatusMarkView: NSView {
    private let spinner = NSProgressIndicator()
    private let symbol = NSImageView()
    private var presentation = ConnectionStatusPresentation(.notConnected)
    private var isEmphasized = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        addSubview(symbol)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            spinner.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.trailingAnchor.constraint(equalTo: trailingAnchor),
            symbol.topAnchor.constraint(equalTo: topAnchor),
            symbol.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionStatusMarkView does not support NSCoder init")
    }

    internal var showsMark: Bool {
        presentation.symbol != nil
    }

    internal var displayedSymbolName: String? {
        guard !symbol.isHidden else { return nil }
        return presentation.symbol?.systemName
    }

    internal var isSpinning: Bool {
        presentation.isBusy
    }

    internal func configure(_ presentation: ConnectionStatusPresentation, isEmphasized: Bool) {
        self.presentation = presentation
        self.isEmphasized = isEmphasized
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func apply() {
        let name = presentation.symbol?.systemName
        symbol.image = name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbol.isHidden = name == nil
        isHidden = presentation.symbol == nil
        applyTint()
        applyAnimation()
    }

    // On the selected row the mark takes the selection's foreground, as the label beside it does.
    private func applyTint() {
        symbol.contentTintColor = isEmphasized ? .alternateSelectedControlTextColor : presentation.tint.nsColor
    }

    private func applyAnimation() {
        if presentation.isBusy, window != nil {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}
