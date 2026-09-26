import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
@Suite(.serialized)
struct WelcomeToolbarTests {
    @Test("The native toolbar stays icon-only and hides the system display-mode menu")
    func toolbarConfiguration() {
        let toolbar = NSToolbar(identifier: "com.TablePro.tests.welcome.toolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = true
        }

        WelcomeWindowController.configureToolbar(toolbar)

        #expect(toolbar.displayMode == .iconOnly)
        #expect(!toolbar.allowsUserCustomization)
        #expect(!toolbar.autosavesConfiguration)
        if #available(macOS 15.0, *) {
            #expect(!toolbar.allowsDisplayModeCustomization)
        }
    }

    @Test("Native display-mode changes are normalized to Icon Only")
    func nativeDisplayModeLock() {
        let toolbar = NSToolbar(identifier: "com.TablePro.tests.welcome.mode-lock")
        WelcomeWindowController.configureToolbar(toolbar)
        let observation = WelcomeWindowController.keepIconOnlyDisplayMode(of: toolbar)

        toolbar.displayMode = .labelOnly

        #expect(toolbar.displayMode == .iconOnly)
        withExtendedLifetime(observation) {}
    }

    @Test("The app offers Icon and Text and Icon Only, but not Text Only")
    func labelModes() {
        let presentation = WelcomeToolbarPresentation()

        #expect(WelcomeToolbarLabelMode.allCases == [.iconAndText, .iconOnly])
        #expect(presentation.labelMode == .iconOnly)
        presentation.labelMode = .iconAndText
        #expect(presentation.labelMode == .iconAndText)
    }

    @Test("The scene-bridged replacement toolbar receives the fixed native configuration")
    func liveToolbarConfiguration() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let seedToolbar = NSToolbar(identifier: "com.TablePro.tests.welcome.seed")
        window.toolbar = seedToolbar
        let content = toolbarHost(presentation: WelcomeToolbarPresentation())
        defer {
            if #available(macOS 14.0, *) {
                content.sceneBridgingOptions = []
            }
            window.contentViewController = nil
            window.toolbar = nil
            window.close()
        }

        window.contentViewController = content
        WelcomeWindowController.configureLiveToolbar(in: window)
        try await Task.sleep(for: .milliseconds(10))

        let liveToolbar = try #require(window.toolbar)
        if #available(macOS 14.0, *) {
            #expect(liveToolbar !== seedToolbar)
        } else {
            #expect(liveToolbar === seedToolbar)
        }
        #expect(liveToolbar.displayMode == .iconOnly)
        #expect(window.toolbarStyle == .unified)
        if #available(macOS 15.0, *) {
            #expect(!liveToolbar.allowsDisplayModeCustomization)
        }
    }

    @Test("The live toolbar and search field stay in one row")
    func liveToolbarGeometry() async throws {
        guard #available(macOS 14.0, *) else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "com.TablePro.tests.welcome.geometry")
        let presentation = WelcomeToolbarPresentation()
        presentation.labelMode = .iconAndText
        let content = toolbarHost(presentation: presentation)
        window.contentViewController = content
        WelcomeWindowController.configureLiveToolbar(in: window)
        defer {
            content.sceneBridgingOptions = []
            window.orderOut(nil)
            window.contentViewController = nil
            window.toolbar = nil
            window.close()
        }

        window.orderBack(nil)
        window.displayIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        window.displayIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()

        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        let searchCaption = allSubviews(in: window.contentView?.superview)
            .compactMap { $0 as? NSTextField }
            .first { !($0 is NSSearchField) && !$0.isHidden && $0.stringValue == String(localized: "Search") }

        #expect(chromeHeight < 60)
        #expect(searchCaption == nil)
    }

    @Test("Icon and Text renders each action title beside its icon")
    func actionLabelPresentation() {
        let iconAndText = actionLabelSize(labelMode: .iconAndText)
        let iconOnly = actionLabelSize(labelMode: .iconOnly)

        #expect(WelcomeToolbarTitleAndIconLabelStyle.spacing == 6)
        #expect(iconAndText.width > iconOnly.width)
        #expect(iconAndText.width > iconAndText.height)
    }

    @Test("Welcome actions keep native spacing as separate toolbar items")
    func actionItemSpacing() throws {
        let source = try welcomeLibrarySource()
        let start = try #require(source.range(of: "internal struct WelcomeLibraryToolbar"))
        let end = try #require(source.range(of: "internal struct WelcomeToolbarActionLabel"))
        let toolbar = String(source[start.lowerBound ..< end.lowerBound])
        let itemCount = toolbar.components(separatedBy: "ToolbarItem(placement: .primaryAction)").count - 1
        let spacerCount = toolbar.components(separatedBy: "ToolbarSpacer(.fixed").count - 1

        #expect(itemCount == 3)
        #expect(spacerCount == 2)
        #expect(!toolbar.contains("ToolbarItemGroup"))
    }

    @Test("Toolbar label modes are translated into every shipped language")
    func labelModeLocalization() throws {
        let catalog = try localizationCatalog()

        for key in ["Icon and Text", "Icon Only"] {
            let entry = try #require(catalog[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["ko", "tr", "vi", "zh-Hans", "zh-Hant"] {
                #expect(localizations[language] != nil, "\(language) has no translation for \(key)")
            }
        }
    }

    private func actionLabelSize(labelMode: WelcomeToolbarLabelMode) -> NSSize {
        let host = NSHostingView(
            rootView: WelcomeToolbarActionLabel(
                title: "Connection Action",
                systemImage: "plus",
                labelMode: labelMode
            )
            .fixedSize()
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func welcomeLibrarySource(file: StaticString = #filePath) throws -> String {
        let source = try repositoryRoot(file: file)
            .appendingPathComponent("TablePro/Views/Welcome/WelcomeLibraryPane.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    private func localizationCatalog(file: StaticString = #filePath) throws -> [String: Any] {
        let source = try repositoryRoot(file: file)
            .appendingPathComponent("TablePro/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: source))
        let root = try #require(json as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private func toolbarHost(
        presentation: WelcomeToolbarPresentation
    ) -> NSHostingController<WelcomeToolbarHostView> {
        let host = NSHostingController(rootView: WelcomeToolbarHostView(presentation: presentation))
        host.sizingOptions = []
        if #available(macOS 14.0, *) {
            host.sceneBridgingOptions = [.toolbars]
        }
        return host
    }

    private func repositoryRoot(file: StaticString) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let project = directory.appendingPathComponent("project.yml")
            if FileManager.default.fileExists(atPath: project.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw WelcomeToolbarTestError.repositoryRootNotFound
    }

    private func allSubviews(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { allSubviews(in: $0) }
    }

    private enum WelcomeToolbarTestError: Error {
        case repositoryRootNotFound
    }
}

private struct WelcomeToolbarHostView: View {
    @ObservedObject var presentation: WelcomeToolbarPresentation
    @State private var searchText = ""

    var body: some View {
        Color.clear
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: Text("Search Connections")
            )
            .toolbar {
                WelcomeToolbarHostContent(presentation: presentation)
            }
    }
}

private struct WelcomeToolbarHostContent: ToolbarContent {
    @ObservedObject var presentation: WelcomeToolbarPresentation

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {} label: {
                WelcomeToolbarActionLabel(
                    title: String(localized: "New Connection"),
                    systemImage: "plus",
                    labelMode: presentation.labelMode
                )
            }
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {} label: {
                WelcomeToolbarActionLabel(
                    title: String(localized: "New Group"),
                    systemImage: "folder.badge.plus",
                    labelMode: presentation.labelMode
                )
            }
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(String(localized: "Toolbar"), selection: $presentation.labelMode) {
                    ForEach(WelcomeToolbarLabelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } label: {
                Label(String(localized: "View Options"), systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}
