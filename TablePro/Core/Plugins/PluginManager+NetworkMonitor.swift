//
//  PluginManager+NetworkMonitor.swift
//  TablePro
//

import Network

extension PluginManager {
    func startNetworkReachabilityMonitor() {
        guard pluginNetworkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pluginNetworkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handleNetworkPathChange(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.TablePro.pluginNetworkMonitor"))
    }

    private func handleNetworkPathChange(satisfied: Bool) {
        defer { lastNetworkSatisfied = satisfied }
        guard satisfied, !lastNetworkSatisfied else { return }
        retriggerReconciliation()
    }
}
