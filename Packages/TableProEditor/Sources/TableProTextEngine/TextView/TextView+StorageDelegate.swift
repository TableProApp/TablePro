//
//  TextView+StorageDelegate.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 11/8/23.
//

import AppKit

public extension TextView {
    func addStorageDelegate(_ delegate: NSTextStorageDelegate) {
        storageDelegate.addDelegate(delegate)
    }

    func removeStorageDelegate(_ delegate: NSTextStorageDelegate) {
        storageDelegate.removeDelegate(delegate)
    }
}
