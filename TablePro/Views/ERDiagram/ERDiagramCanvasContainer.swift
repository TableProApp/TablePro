import AppKit
import SwiftUI

struct ERDiagramCanvasContainer<Content: View>: NSViewRepresentable {
    let viewModel: ERDiagramViewModel
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ERDiagramCanvasContainerView<Content> {
        ERDiagramCanvasContainerView(rootView: content(), viewModel: viewModel)
    }

    func updateNSView(_ nsView: ERDiagramCanvasContainerView<Content>, context: Context) {
        nsView.hostingView.rootView = content()
    }
}

@MainActor
final class ERDiagramCanvasContainerView<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    private let viewModel: ERDiagramViewModel

    init(rootView: Content, viewModel: ERDiagramViewModel) {
        self.viewModel = viewModel
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func scrollWheel(with event: NSEvent) {
        let action = ERDiagramScrollTranslator.action(
            scrollingDeltaX: event.scrollingDeltaX,
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            isZoomModifierActive: event.modifierFlags.contains(.command),
            currentOffset: viewModel.canvasOffset,
            currentMagnification: viewModel.magnification
        )
        switch action {
        case .pan(let offset):
            viewModel.canvasOffset = offset
        case .zoom(let magnification):
            viewModel.zoom(to: magnification)
        }
    }
}
