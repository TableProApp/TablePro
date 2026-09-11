//
//  WelcomeImportMenuButtonTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@MainActor
@Suite("WelcomeImportMenuButton")
struct WelcomeImportMenuButtonTests {
    private final class Recorder {
        var fired: [String] = []
    }

    private func makeCoordinator(_ recorder: Recorder) -> WelcomeImportMenuButton.Coordinator {
        WelcomeImportMenuButton.Coordinator(actions: WelcomeImportActions(
            importConnectionsFile: { recorder.fired.append("file") },
            importFromURL: { recorder.fired.append("url") },
            importFromApp: { recorder.fired.append("app") },
            openProjectFolder: { recorder.fired.append("folder") }
        ))
    }

    @Test("The first item is the pull-down's label and runs nothing")
    func labelItem() {
        let menu = makeCoordinator(Recorder()).makeMenu()

        #expect(menu.items.first?.title == "Import")
        #expect(menu.items.first?.action == nil)
    }

    @Test("Each choice runs its own action, in the File > Import order")
    func choicesRunTheirActions() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder)
        let menu = coordinator.makeMenu()

        for item in menu.items where item.action != nil {
            coordinator.runCommand(item)
        }

        #expect(recorder.fired == ["file", "url", "app", "folder"])
    }
}
