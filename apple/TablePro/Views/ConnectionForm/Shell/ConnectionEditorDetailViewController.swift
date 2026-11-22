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
// sidebar click drops its scroll position and @State, as it did in Settings.
@MainActor
final class ConnectionEditorDetailViewController: NSViewController {
    enum Content: Equatable {
        case facet(ConnectionFacet)
        case recordMissing
    }

    private let store: ConnectionEditorStore
    private let onCloseMissingRecord: () -> Void
    private var facetHosts: [ConnectionFacet: NSHostingController<ConnectionEditorFacetPage>] = [:]
    private var recordMissingHost: NSHostingController<ConnectionEditorRecordMissingView>?
    private(set) var shownContent: Content?

    init(store: ConnectionEditorStore, onCloseMissingRecord: @escaping () -> Void) {
        self.store = store
        self.onCloseMissingRecord = onCloseMissingRecord
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
        for child in children where child !== shown {
            // A hidden host leaves the key view loop and the accessibility tree, and adds nothing to a live resize.
            child.view.isHidden = true
            child.view.autoresizingMask = []
        }
        shown.view.frame = view.bounds
        shown.view.autoresizingMask = [.width, .height]
        shown.view.isHidden = false
        shownContent = content
    }

    private func makeFacetHost(_ facet: ConnectionFacet) -> NSHostingController<ConnectionEditorFacetPage> {
        let host = NSHostingController(rootView: ConnectionEditorFacetPage(store: store, facet: facet))
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
        host.view.frame = view.bounds
        view.addSubview(host.view)
    }
}
