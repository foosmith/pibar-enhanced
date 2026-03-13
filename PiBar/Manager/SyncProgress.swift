//
//  SyncProgress.swift
//  PiBar
//
//  Created by Codex on 3/12/26.
//

import Foundation

extension Notification.Name {
    static let piBarSyncProgress = Notification.Name("PiBar.Sync.Progress")
    /// Posted on the main thread when a sync operation begins.
    static let piBarSyncBegan = Notification.Name("PiBar.Sync.Began")
    /// Posted on the main thread when a sync operation ends (success, failure, or skip).
    static let piBarSyncEnded = Notification.Name("PiBar.Sync.Ended")
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

// MARK: - Sync Status

enum SyncStatus: String {
    case success
    case failed
    case dryRun  = "dry-run"
    case skipped
}

// MARK: - Adlist URL Helpers (shared across sync operations)

/// Returns true if the URL string appears to contain percent-encoded path separators or colons,
/// which indicates a doubly-encoded URL that Pi-hole cannot use.
func syncAdlistLooksPercentEncoded(_ address: String) -> Bool {
    address.contains("%2F") || address.contains("%3A")
}

/// Sanitizes a URL string for writing to Pi-hole: trims whitespace and replaces any remaining
/// whitespace sequences with `%20` (Pi-hole rejects unencoded whitespace in address fields).
func syncAdlistSanitizeWriteAddress(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    var result = ""
    result.reserveCapacity(trimmed.count)
    var lastWasWhitespace = false
    for scalar in trimmed.unicodeScalars {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            if !lastWasWhitespace {
                result.append(contentsOf: "%20")
                lastWasWhitespace = true
            }
            continue
        }
        lastWasWhitespace = false
        result.unicodeScalars.append(scalar)
    }
    return result
}
