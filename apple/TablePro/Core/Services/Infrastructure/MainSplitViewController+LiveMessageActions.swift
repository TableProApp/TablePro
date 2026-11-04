import AppKit

extension MainSplitViewController {
    @objc func openLiveMessages(_ sender: Any?) {
        guard let coordinator = liveMessagesCoordinator, coordinator.canOpenLiveMessages() else { return }
        coordinator.openLiveMessages()
    }

    var canOpenLiveMessages: Bool {
        liveMessagesCoordinator?.canOpenLiveMessages() == true
    }

    // Nil while the module is off, so no command reaches the subscription code.
    private var liveMessagesCoordinator: MainContentCoordinator? {
        guard AppModuleSettings.shared.isEnabled(.liveMessages) else { return nil }
        return commandActions?.coordinator
    }
}
