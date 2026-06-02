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
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                self?.retriggerReconciliation()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.TablePro.pluginNetworkMonitor"))
    }
}
