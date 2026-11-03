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

// AppKit twin of `ConnectionStatusMark` for the rail, drawn as a badge on the tile's corner. The backing
// punches it out of the tile's fill and of the selection, which an identity colour alone can match.
@MainActor
internal final class ConnectionStatusMarkView: NSView {
    internal static let rim: CGFloat = 1

    private let backing = NSBox()
    private let spinner = NSProgressIndicator()
    private let symbol = NSImageView()
    private var presentation = ConnectionStatusPresentation(.notConnected)
    private var isEmphasized = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backing.boxType = .custom
        backing.borderWidth = 0
        backing.titlePosition = .noTitle
        backing.contentViewMargins = .zero
        backing.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing)
        addSubview(spinner)
        addSubview(symbol)
        let rim = Self.rim
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rim),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rim),
            spinner.topAnchor.constraint(equalTo: topAnchor, constant: rim),
            spinner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -rim),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rim),
            symbol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rim),
            symbol.topAnchor.constraint(equalTo: topAnchor, constant: rim),
            symbol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -rim),
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

    internal var displayedTint: NSColor? {
        displayedSymbolName == nil ? nil : presentation.tint.nsColor
    }

    internal func configure(_ presentation: ConnectionStatusPresentation, isEmphasized: Bool) {
        self.presentation = presentation
        self.isEmphasized = isEmphasized
        apply()
    }

    override func layout() {
        super.layout()
        backing.cornerRadius = bounds.width / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAnimation()
    }

    private func apply() {
        let name = presentation.symbol?.systemName
        symbol.image = name.flatMap { Self.tintedSymbol(named: $0, color: presentation.tint.nsColor) }
        symbol.isHidden = name == nil
        isHidden = presentation.symbol == nil
        // The colour AppKit draws content in on a selection, as the old identity dot's rim did.
        backing.fillColor = isEmphasized ? .alternateSelectedControlTextColor : .windowBackgroundColor
        applyAnimation()
    }

    // A template follows the selected row's emphasized style into white, the colour of the backing under it.
    nonisolated private static func tintedSymbol(named name: String, color: NSColor) -> NSImage? {
        guard let template = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func applyAnimation() {
        if presentation.isBusy, window != nil {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}
