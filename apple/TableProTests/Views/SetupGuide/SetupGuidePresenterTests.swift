//
//  SetupGuidePresenterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct SetupGuidePresenterTests {
    @MainActor
    private final class Recorder {
        var inputs = SetupGuideGate.Inputs(
            trigger: .launch,
            isUserSession: true,
            hasRoutedWork: false,
            isUITestSandbox: false,
            uiTestRequestsGuide: false,
            libraryReadable: true,
            connectionCount: 0,
            hasSeen: false
        )
        var presented: [SetupGuideGate.Trigger] = []
        var seenWrites = 0
        var endings = 0
        var routedWorkAsked: [Bool] = []
    }

    private static func presenter(_ recorder: Recorder) -> SetupGuidePresenter {
        SetupGuidePresenter(environment: SetupGuidePresenter.Environment(
            launchInputs: { hasRoutedWork in
                recorder.routedWorkAsked.append(hasRoutedWork)
                var inputs = recorder.inputs
                inputs.hasRoutedWork = inputs.hasRoutedWork || hasRoutedWork
                return inputs
            },
            present: { recorder.presented.append($0) },
            markSeen: {
                recorder.seenWrites += 1
                recorder.inputs.hasSeen = true
            },
            guideDidEnd: { recorder.endings += 1 }
        ))
    }

    @Test("An empty library opens the guide once at launch, and closing it marks it seen before the sign-in check")
    func launchPresentsOnce() {
        let recorder = Recorder()
        let presenter = Self.presenter(recorder)
        #expect(presenter.isPending, "Undecided with the gate open, the sign-in window waits")

        presenter.welcomeDidAppear(hasRoutedWork: false)
        #expect(presenter.state == .presenting)
        #expect(recorder.presented == [.launch])
        #expect(presenter.isPending)
        #expect(recorder.endings == 0)

        presenter.welcomeDidAppear(hasRoutedWork: false)
        #expect(recorder.presented == [.launch], "Welcome reopening in the same launch decides nothing")

        presenter.guideDidClose()
        #expect(presenter.state == .closed)
        #expect(recorder.seenWrites == 1)
        #expect(recorder.endings == 1)
        #expect(!presenter.isPending)
    }

    @Test("A launch the gate refuses shows nothing and lets the sign-in window go at once")
    func launchNotShown() {
        let recorder = Recorder()
        recorder.inputs.connectionCount = 2
        let presenter = Self.presenter(recorder)
        #expect(!presenter.isPending)

        presenter.welcomeDidAppear(hasRoutedWork: false)

        #expect(presenter.state == .notShown)
        #expect(recorder.presented.isEmpty)
        #expect(recorder.seenWrites == 0, "A guide that never showed is not seen")
        #expect(recorder.endings == 1)
    }

    @Test("A sheet a routed request opened on Welcome keeps the guide away, and the sign-in window waits no more")
    func routedWorkWins() {
        let recorder = Recorder()
        let presenter = Self.presenter(recorder)

        presenter.welcomeDidAppear(hasRoutedWork: true)

        #expect(recorder.routedWorkAsked.last == true)
        #expect(presenter.state == .notShown)
        #expect(recorder.presented.isEmpty)
        #expect(!presenter.isPending)
        #expect(recorder.endings == 1)
    }

    @Test("Help > Setup Guide opens it after a launch that did not, and after it was seen")
    func menuReopens() {
        let recorder = Recorder()
        recorder.inputs.hasSeen = true
        let presenter = Self.presenter(recorder)
        presenter.welcomeDidAppear(hasRoutedWork: false)
        #expect(presenter.state == .notShown)

        presenter.presentFromMenu()
        #expect(presenter.state == .presenting)
        #expect(recorder.presented == [.menu])
        #expect(presenter.isPending)

        presenter.guideDidClose()
        presenter.presentFromMenu()
        #expect(recorder.presented == [.menu, .menu])
    }

    @Test("Opened from the menu before Welcome drew, the launch decision is skipped")
    func menuBeforeWelcome() {
        let recorder = Recorder()
        let presenter = Self.presenter(recorder)

        presenter.presentFromMenu()
        presenter.welcomeDidAppear(hasRoutedWork: false)

        #expect(recorder.presented == [.menu])
        #expect(presenter.state == .presenting)
    }
}
