//
//  SyncProgress.swift
//  PiBar
//
//  Created by Codex on 3/12/26.
//

import Foundation

extension Notification.Name {
    static let piBarSyncProgress = Notification.Name("PiBar.Sync.Progress")
}

enum SyncProgress {
    static let messageKey = "message"

    static func report(_ message: String) {
        let userInfo: [String: Any] = [messageKey: message]
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .piBarSyncProgress, object: nil, userInfo: userInfo)
        }
    }
}

