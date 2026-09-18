//
//  OperationCompletionReporterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing
import UserNotifications

@MainActor
private final class FakeNotificationPresenter: UserNotificationPresenting {
    var status: UNAuthorizationStatus = .authorized
    var grantsWhenAsked = true
    private(set) var posted: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [String] = []
    private(set) var categorySets: [Set<UNNotificationCategory>] = []
    private(set) var requestedOptions: [UNAuthorizationOptions] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        requestedOptions.append(options)
        status = grantsWhenAsked ? .authorized : .denied
        return grantsWhenAsked
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) { categorySets.append(categories) }

    func post(_ request: UNNotificationRequest) async throws { posted.append(request) }

    func removeDelivered(identifiers: [String]) { removedIdentifiers.append(contentsOf: identifiers) }
}

/// The real notification centre has no authorization on CI and drops everything silently, so a
/// test written against it passes whether or not the code works.
@Suite("OperationCompletionReporter")
@MainActor
struct OperationCompletionReporterTests {
    private func makeReporter(
        presenter: FakeNotificationPresenter,
        visibility: ResultVisibility = .offScreen,
        settings: NotificationSettings = .default,
        marked: @escaping (OperationOwner) -> Void = { _ in }
    ) -> OperationCompletionReporter {
        OperationCompletionReporter(
            presenter: presenter,
            authorization: NotificationAuthorization(presenter: presenter),
            categories: NotificationCategoryRegistry(presenter: presenter),
            settings: { settings },
            resolveVisibility: { _, _ in visibility },
            markUnseen: marked
        )
    }

    private func completion(
        elapsed: Duration = .seconds(60),
        outcome: OperationOutcome = .succeeded(OperationSummary(rowsReturned: 3))
    ) -> OperationCompletion {
        OperationCompletion(
            kind: .query,
            owner: .tab(windowId: nil, tabId: UUID()),
            connectionId: UUID(),
            connectionName: "Sales",
            databaseName: "production",
            elapsed: elapsed,
            outcome: outcome
        )
    }

    @Test("A finished operation the user could not see posts one notification")
    func postsOneNotification() async throws {
        let presenter = FakeNotificationPresenter()
        let reporter = makeReporter(presenter: presenter)

        reporter.report(completion())
        try await Task.sleep(for: .milliseconds(120))

        #expect(presenter.posted.count == 1)
        let content = try #require(presenter.posted.first?.content)
        #expect(content.title == "Sales")
        #expect(content.subtitle == "production")
        #expect(content.body == "3 rows in 1m 00s")
    }

    @Test("Work the user cancelled posts nothing")
    func cancelledPostsNothing() async throws {
        let presenter = FakeNotificationPresenter()
        let reporter = makeReporter(presenter: presenter)

        reporter.report(completion(outcome: .cancelled))
        try await Task.sleep(for: .milliseconds(120))

        #expect(presenter.posted.isEmpty)
    }

    @Test("A result the user is looking at posts nothing and marks nothing")
    func visibleResultPostsNothing() async throws {
        let presenter = FakeNotificationPresenter()
        var marked: [OperationOwner] = []
        let reporter = makeReporter(presenter: presenter, visibility: .onScreen) { marked.append($0) }

        reporter.report(completion())
        try await Task.sleep(for: .milliseconds(120))

        #expect(presenter.posted.isEmpty)
        #expect(marked.isEmpty)
    }

    @Test("A denied permission still marks the tab, and posts nothing")
    func deniedStillMarksTheTab() async throws {
        let presenter = FakeNotificationPresenter()
        presenter.status = .denied
        presenter.grantsWhenAsked = false
        var marked: [OperationOwner] = []
        let reporter = makeReporter(presenter: presenter) { marked.append($0) }

        reporter.report(completion())
        try await Task.sleep(for: .milliseconds(120))

        #expect(presenter.posted.isEmpty)
        #expect(marked.count == 1)
    }

    /// Permission is asked for the first time there is something to say, never at launch, and the
    /// options include sound so a fresh grant can carry one.
    @Test("Permission is requested in context, with sound")
    func permissionRequestedInContext() async throws {
        let presenter = FakeNotificationPresenter()
        presenter.status = .notDetermined
        let reporter = makeReporter(presenter: presenter)

        #expect(presenter.requestedOptions.isEmpty)

        reporter.report(completion())
        try await Task.sleep(for: .milliseconds(120))

        #expect(presenter.requestedOptions == [[.alert, .sound]])
        #expect(presenter.posted.count == 1)
    }

    @Test("Registering categories unions every owner rather than replacing the set")
    func categoriesUnionAcrossOwners() {
        let presenter = FakeNotificationPresenter()
        let registry = NotificationCategoryRegistry(presenter: presenter)

        let plugin = UNNotificationCategory(
            identifier: "plugins", actions: [], intentIdentifiers: [], options: []
        )
        let operations = UNNotificationCategory(
            identifier: "operations", actions: [], intentIdentifiers: [], options: []
        )
        registry.register([plugin], owner: "plugins")
        registry.register([operations], owner: "operations")

        let identifiers = Set(registry.allCategories.map(\.identifier))
        #expect(identifiers == ["plugins", "operations"])
        #expect(presenter.categorySets.last?.count == 2)
    }

    @Test("Clearing a tab's notifications removes only that tab's")
    func clearingIsScopedToTheOwner() async throws {
        let presenter = FakeNotificationPresenter()
        let reporter = makeReporter(presenter: presenter)
        let mine = completion()

        reporter.report(mine)
        reporter.report(completion())
        try await Task.sleep(for: .milliseconds(150))
        #expect(presenter.posted.count == 2)

        reporter.clearDelivered(for: mine.owner)

        #expect(presenter.removedIdentifiers == [OperationCompletionPolicy.identifier(for: mine)])
    }
}
