import Foundation
@testable import TablePro
import Testing
import UserNotifications

@MainActor
private final class RecordingPresenter: UserNotificationPresenting {
    var status: UNAuthorizationStatus = .authorized
    private(set) var posted: [UNNotificationRequest] = []
    private(set) var removed: [String] = []
    private(set) var authorizationRequests = 0

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        authorizationRequests += 1
        return status == .authorized
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {}

    var onPost: (@MainActor () -> Void)?

    func post(_ request: UNNotificationRequest) async throws {
        posted.append(request)
        onPost?()
    }

    func removeDelivered(identifiers: [String]) { removed.append(contentsOf: identifiers) }
}

@MainActor
struct AgentAttentionNotifierTests {
    private let presenter = RecordingPresenter()

    private func makeSession() -> AgentSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentAttentionNotifierTests-\(UUID().uuidString)", isDirectory: true)
        return AgentSessionRegistry(store: AgentSessionStore(directory: directory)).startSession(for: UUID())
    }

    private func makeNotifier(
        enabled: Bool = true,
        onScreen: Bool = false
    ) -> AgentAttentionNotifier {
        AgentAttentionNotifier(
            presenter: presenter,
            authorization: NotificationAuthorization(presenter: presenter),
            categories: NotificationCategoryRegistry(presenter: presenter),
            settings: { NotificationSettings(isEnabled: enabled) },
            isOnScreen: { _ in onScreen },
            connectionName: { _ in "Production" }
        )
    }

    @Test("A session waiting on you out of sight posts a notification named after its connection")
    func waitingOutOfSightNotifies() async throws {
        let session = makeSession()
        session.mark(.waitingOnYou)
        let notifier = makeNotifier()

        await notifier.statusChanged(session, to: .waitingOnYou)?.value

        let request = try #require(presenter.posted.first)
        #expect(request.identifier == AgentAttentionNotifier.identifier(for: session.id))
        #expect(request.content.title == "Production")
        #expect(request.content.body == "The agent is waiting for your answer.")
    }

    @Test("A failed reply out of sight notifies too")
    func failedNotifies() async {
        let session = makeSession()
        session.mark(.failed)
        let notifier = makeNotifier()

        await notifier.statusChanged(session, to: .failed)?.value

        #expect(presenter.posted.count == 1)
        #expect(presenter.posted.first?.content.body.hasPrefix("The agent's reply failed") == true)
    }

    @Test("A session on screen posts nothing")
    func onScreenPostsNothing() {
        let session = makeSession()
        session.mark(.waitingOnYou)

        #expect(makeNotifier(onScreen: true).statusChanged(session, to: .waitingOnYou) == nil)
        #expect(presenter.posted.isEmpty)
    }

    @Test("The notifications switch off posts nothing and asks no permission")
    func switchOffPostsNothing() {
        let session = makeSession()
        session.mark(.failed)

        #expect(makeNotifier(enabled: false).statusChanged(session, to: .failed) == nil)
        #expect(presenter.authorizationRequests == 0)
    }

    @Test("Working and ready are not news")
    func ordinaryStatesAreQuiet() {
        let session = makeSession()
        let notifier = makeNotifier()

        #expect(notifier.statusChanged(session, to: .working) == nil)
        #expect(notifier.statusChanged(session, to: .ready) == nil)
        #expect(presenter.posted.isEmpty)
    }

    @Test("Answering removes the delivered notification")
    func leavingTheStateWithdrawsIt() async {
        let session = makeSession()
        session.mark(.waitingOnYou)
        let notifier = makeNotifier()
        await notifier.statusChanged(session, to: .waitingOnYou)?.value

        session.mark(.working)
        notifier.statusChanged(session, to: .working)

        #expect(presenter.removed == [AgentAttentionNotifier.identifier(for: session.id)])
    }

    @Test("A session answered before the permission came back is not announced")
    func answeredWhileAskingPostsNothing() async {
        let session = makeSession()
        session.mark(.waitingOnYou)
        let notifier = makeNotifier()

        let delivery = notifier.statusChanged(session, to: .waitingOnYou)
        session.mark(.working)
        await delivery?.value

        #expect(presenter.posted.isEmpty)
    }

    @Test("A session that fails while permission is asked is announced as failed, not waiting")
    func deliveryReadsTheCurrentState() async {
        let session = makeSession()
        session.mark(.waitingOnYou)
        let notifier = makeNotifier()

        let delivery = notifier.statusChanged(session, to: .waitingOnYou)
        session.mark(.failed)
        await delivery?.value

        #expect(presenter.posted.first?.content.body.hasPrefix("The agent's reply failed") == true)
    }

    @Test("An answer that lands while the post is in flight still removes the notification")
    func answerDuringPostWithdraws() async {
        let session = makeSession()
        session.mark(.waitingOnYou)
        let notifier = makeNotifier()
        presenter.onPost = { session.mark(.working) }

        await notifier.statusChanged(session, to: .waitingOnYou)?.value

        #expect(presenter.posted.count == 1)
        #expect(presenter.removed == [AgentAttentionNotifier.identifier(for: session.id)])
    }
}
