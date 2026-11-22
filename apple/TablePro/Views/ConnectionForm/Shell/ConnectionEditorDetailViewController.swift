//
//  ConnectionEditorDetailViewController.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ConnectionEditorFacetPage: View {
    let store: ConnectionEditorStore
    let facet: ConnectionFacet

    var body: some View {
        switch facet {
        case .general: GeneralFacetView(store: store)
        case .sshAndProxies: SSHAndProxiesFacetView(store: store)
        case .sslTLS: SSLFacetView(store: store)
        case .appearance: AppearanceFacetView(store: store)
        case .safeMode: SafeModeFacetView(store: store)
        case .aiAndMCP: AIAndMCPFacetView(store: store)
        case .startup: StartupFacetView(store: store)
        case .advanced: AdvancedFacetView(store: store)
        }
    }
}

// One hosting controller per visited facet, kept while the window is open: rebuilding a facet on every
// sidebar click drops its scroll position and @State, as it did in Settings. Only the shown one is in the
// window: a hidden hosting view still re-renders on every store change, which made a keystroke cost one
// render per visited facet.
@MainActor
final class ConnectionEditorDetailViewController: NSViewController {
    enum Content: Equatable {
        case facet(ConnectionFacet)
        case recordMissing
    }

    private let store: ConnectionEditorStore
    private let onCloseMissingRecord: () -> Void
    private let makePage: @MainActor (ConnectionFacet) -> AnyView
    private var facetHosts: [ConnectionFacet: NSHostingController<AnyView>] = [:]
    private var recordMissingHost: NSHostingController<ConnectionEditorRecordMissingView>?
    private(set) var shownContent: Content?

    init(
        store: ConnectionEditorStore,
        onCloseMissingRecord: @escaping () -> Void,
        makePage: (@MainActor (ConnectionFacet) -> AnyView)? = nil
    ) {
        self.store = store
        self.onCloseMissingRecord = onCloseMissingRecord
        self.makePage = makePage ?? { AnyView(ConnectionEditorFacetPage(store: store, facet: $0)) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionEditorDetailViewController does not support NSCoder init")
    }

    override func loadView() {
        view = NSView()
    }

    var visitedFacets: Set<ConnectionFacet> {
        Set(facetHosts.keys)
    }

    func show(_ content: Content) {
        _ = view
        guard content != shownContent else { return }
        let shown: NSViewController
        switch content {
        case .facet(let facet):
            shown = facetHosts[facet] ?? makeFacetHost(facet)
        case .recordMissing:
            shown = recordMissingHost ?? makeRecordMissingHost()
        }
        for child in children where child !== shown && child.view.superview != nil {
            child.view.removeFromSuperview()
        }
        shown.view.frame = view.bounds
        shown.view.autoresizingMask = [.width, .height]
        if shown.view.superview !== view {
            view.addSubview(shown.view)
        }
        shownContent = content
    }

    func host(for facet: ConnectionFacet) -> NSViewController? {
        facetHosts[facet]
    }

    private func makeFacetHost(_ facet: ConnectionFacet) -> NSHostingController<AnyView> {
        let host = NSHostingController(rootView: makePage(facet))
        install(host)
        facetHosts[facet] = host
        return host
    }

    private func makeRecordMissingHost() -> NSHostingController<ConnectionEditorRecordMissingView> {
        let host = NSHostingController(rootView: ConnectionEditorRecordMissingView(onClose: onCloseMissingRecord))
        install(host)
        recordMissingHost = host
        return host
    }

    private func install<Root: View>(_ host: NSHostingController<Root>) {
        // A split item's hosting controller fixes its fitting size as a required minimum unless this is cleared.
        host.sizingOptions = []
        if #available(macOS 14.0, *) {
            // The window title belongs to the shell; a facet's navigation title must not reach it.
            host.sceneBridgingOptions = []
        }
        addChild(host)
    }
}
