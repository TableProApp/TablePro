//
//  TextView+StorageDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 11/8/23.
//

import AppKit

extension TextView {
    public func addStorageDelegate(_ delegate: NSTextStorageDelegate) {
        storageDelegate.addDelegate(delegate)
    }

    public func removeStorageDelegate(_ delegate: NSTextStorageDelegate) {
        storageDelegate.removeDelegate(delegate)
    }
}
