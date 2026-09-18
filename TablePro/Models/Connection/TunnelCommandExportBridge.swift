//
//  TunnelCommandExportBridge.swift
//  TablePro
//

import Foundation
import TableProImport
import TableProPluginKit

extension ExportableTunnelCommand {
    init(_ config: TunnelCommandConfiguration) {
        self.init(
            method: config.method.rawValue,
            command: config.command.nilIfEmpty,
            executablePath: config.executablePath.nilIfEmpty,
            kubernetesNamespace: config.kubernetesNamespace.nilIfEmpty,
            kubernetesResource: config.kubernetesResource.nilIfEmpty,
            kubernetesContext: config.kubernetesContext.nilIfEmpty,
            awsTarget: config.awsTarget.nilIfEmpty,
            awsProfile: config.awsProfile.nilIfEmpty,
            awsRegion: config.awsRegion.nilIfEmpty
        )
    }
}

extension TunnelCommandConfiguration {
    init(_ exportable: ExportableTunnelCommand) {
        self.init(
            method: TunnelCommandMethod(rawValue: exportable.method) ?? .custom,
            command: exportable.command ?? "",
            executablePath: exportable.executablePath ?? "",
            kubernetesNamespace: exportable.kubernetesNamespace ?? "",
            kubernetesResource: exportable.kubernetesResource ?? "",
            kubernetesContext: exportable.kubernetesContext ?? "",
            awsTarget: exportable.awsTarget ?? "",
            awsProfile: exportable.awsProfile ?? "",
            awsRegion: exportable.awsRegion ?? ""
        )
    }
}
