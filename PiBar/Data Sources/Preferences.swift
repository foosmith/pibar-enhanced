//
//  Preferences.swift
//  PiBar
//
//  Created by Brad Root on 5/17/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

struct Preferences {
    fileprivate enum Key {
        static let piholes = "piholes" // Deprecated in PiBar 1.1
        static let piholesV2 = "piholesV2" // Deprecated in PiBar 1.2
        static let piholesV3 = "piholesV3"
        static let showBlocked = "showBlocked"
        static let showQueries = "showQueries"
        static let showPercentage = "showPercentage"
        static let showLabels = "showLabels"
        static let verboseLabels = "verboseLabels"
        static let shortcutEnabled = "shortcutEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let pollingRate = "pollingRate"
        static let didMigrateLegacyDefaults = "didMigrateLegacyDefaults"

        // Primary -> Secondary Sync (Pi-hole v6)
        static let syncEnabled = "syncEnabled"
        static let syncPrimaryIdentifier = "syncPrimaryIdentifier"
        static let syncSecondaryIdentifier = "syncSecondaryIdentifier"
        static let syncIntervalMinutes = "syncIntervalMinutes"
        static let syncWipeSecondaryBeforeSync = "syncWipeSecondaryBeforeSync"
        static let syncLastRunAt = "syncLastRunAt"
        static let syncLastStatus = "syncLastStatus"
        static let syncLastMessage = "syncLastMessage"
        static let syncDryRunEnabled = "syncDryRunEnabled"
        static let syncSkipGroups = "syncSkipGroups"
        static let syncSkipAdlists = "syncSkipAdlists"
        static let syncSkipDomains = "syncSkipDomains"
    }

    private static let migrationLock = NSLock()
    private static let legacyPreferenceDomains = [
        // Original upstream PiBar bundle id (used by older installs).
        "net.amiantos.PiBar",
    ]

    static var standard: UserDefaults {
        let database = UserDefaults.standard
        database.register(defaults: [
            Key.piholes: [],
            Key.piholesV2: [],
            Key.piholesV3: [],
            Key.showBlocked: true,
            Key.showQueries: true,
            Key.showPercentage: true,
            Key.showLabels: false,
            Key.verboseLabels: false,
            Key.shortcutEnabled: true,
            Key.notificationsEnabled: true,
            Key.pollingRate: 3,
            Key.didMigrateLegacyDefaults: false,

            Key.syncEnabled: false,
            Key.syncPrimaryIdentifier: "",
            Key.syncSecondaryIdentifier: "",
            Key.syncIntervalMinutes: 15,
            Key.syncWipeSecondaryBeforeSync: false,
            Key.syncLastStatus: "",
            Key.syncLastMessage: "",
            Key.syncDryRunEnabled: false,
            Key.syncSkipGroups: false,
            Key.syncSkipAdlists: false,
            Key.syncSkipDomains: false,
        ])

        migrateLegacyDefaultsIfNeeded(database: database)
        return database
    }

    private static func migrateLegacyDefaultsIfNeeded(database: UserDefaults) {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        if database.bool(forKey: Key.didMigrateLegacyDefaults) {
            return
        }

        let hasAnyPiholes: Bool = {
            let v3 = database.array(forKey: Key.piholesV3) ?? []
            let v2 = database.array(forKey: Key.piholesV2) ?? []
            let v1 = database.array(forKey: Key.piholes) ?? []
            return !(v3.isEmpty && v2.isEmpty && v1.isEmpty)
        }()

        if hasAnyPiholes {
            database.set(true, forKey: Key.didMigrateLegacyDefaults)
            database.synchronize()
            return
        }

        for domain in legacyPreferenceDomains {
            guard let legacy = UserDefaults.standard.persistentDomain(forName: domain) else { continue }

            let legacyV3 = legacy[Key.piholesV3] as? [Any] ?? []
            let legacyV2 = legacy[Key.piholesV2] as? [Any] ?? []
            let legacyV1 = legacy[Key.piholes] as? [Any] ?? []

            guard !(legacyV3.isEmpty && legacyV2.isEmpty && legacyV1.isEmpty) else { continue }

            if !legacyV3.isEmpty {
                database.set(legacyV3, forKey: Key.piholesV3)
            } else if !legacyV2.isEmpty {
                database.set(legacyV2, forKey: Key.piholesV2)
            } else if !legacyV1.isEmpty {
                database.set(legacyV1, forKey: Key.piholes)
            }

            if let value = legacy[Key.showBlocked] { database.set(value, forKey: Key.showBlocked) }
            if let value = legacy[Key.showQueries] { database.set(value, forKey: Key.showQueries) }
            if let value = legacy[Key.showPercentage] { database.set(value, forKey: Key.showPercentage) }
            if let value = legacy[Key.showLabels] { database.set(value, forKey: Key.showLabels) }
            if let value = legacy[Key.verboseLabels] { database.set(value, forKey: Key.verboseLabels) }
            if let value = legacy[Key.shortcutEnabled] { database.set(value, forKey: Key.shortcutEnabled) }
            if let value = legacy[Key.notificationsEnabled] { database.set(value, forKey: Key.notificationsEnabled) }
            if let value = legacy[Key.pollingRate] { database.set(value, forKey: Key.pollingRate) }

            Log.debug("Migrated legacy defaults from \(domain)")
            break
        }

        database.set(true, forKey: Key.didMigrateLegacyDefaults)
        database.synchronize()
    }
}

extension UserDefaults {
    var piholes: [PiholeConnectionV3] {
        if let array = array(forKey: Preferences.Key.piholesV2), !array.isEmpty {
            // Migrate from PiBar v1.1 format to PiBar v1.2 format if needed
            Log.debug("Found V1 Pi-holes")
            var piholesV2: [PiholeConnectionV2] = []
            for data in array {
                Log.debug("Loading Pi-hole V2...")
                guard let data = data as? Data, let piholeConnection = PiholeConnectionV2(data: data) else { continue }
                piholesV2.append(piholeConnection)
            }
            if !piholesV2.isEmpty {
                let piholesV3 = piholesV2.map { pihole in
                    Log.debug("Converting V2 Pi-hole to V3")
                    return PiholeConnectionV3(
                        hostname: pihole.hostname,
                        port: pihole.port,
                        useSSL: pihole.useSSL,
                        token: pihole.token,
                        passwordProtected: pihole.passwordProtected,
                        adminPanelURL: pihole.adminPanelURL,
                        isV6: false
                    )
                }
                set([], for: Preferences.Key.piholesV2)
                persistPiholesV3(piholesV3)
            }
            return loadPiholesV3()
        } else if let array = array(forKey: Preferences.Key.piholesV3), !array.isEmpty {
            return loadPiholesV3()
        }
        return []
    }

    func set(piholes: [PiholeConnectionV3]) {
        // Clean up any stale keychain entries left over from before this migration
        // (one-time housekeeping — no-ops once keychain is clean).
        let newIdentifiers = Set(piholes.map(\.identifier))
        let removed = loadPiholesV3FromDefaults().filter { !newIdentifiers.contains($0.identifier) }
        for connection in removed {
            try? KeychainCredentialStore.shared.delete(account: connection.identifier)
        }

        persistPiholesV3(piholes)
    }

    var showBlocked: Bool {
        return bool(forKey: Preferences.Key.showBlocked)
    }

    func set(showBlocked: Bool) {
        set(showBlocked, for: Preferences.Key.showBlocked)
    }

    var showQueries: Bool {
        return bool(forKey: Preferences.Key.showQueries)
    }

    func set(showQueries: Bool) {
        set(showQueries, for: Preferences.Key.showQueries)
    }

    var showPercentage: Bool {
        return bool(forKey: Preferences.Key.showPercentage)
    }

    func set(showPercentage: Bool) {
        set(showPercentage, for: Preferences.Key.showPercentage)
    }

    var showLabels: Bool {
        return bool(forKey: Preferences.Key.showLabels)
    }

    func set(showLabels: Bool) {
        set(showLabels, for: Preferences.Key.showLabels)
    }

    var verboseLabels: Bool {
        return bool(forKey: Preferences.Key.verboseLabels)
    }

    func set(verboseLabels: Bool) {
        set(verboseLabels, for: Preferences.Key.verboseLabels)
    }

    var shortcutEnabled: Bool {
        return bool(forKey: Preferences.Key.shortcutEnabled)
    }

    func set(shortcutEnabled: Bool) {
        set(shortcutEnabled, for: Preferences.Key.shortcutEnabled)
    }

    var notificationsEnabled: Bool {
        bool(forKey: Preferences.Key.notificationsEnabled)
    }

    func set(notificationsEnabled: Bool) {
        set(notificationsEnabled, for: Preferences.Key.notificationsEnabled)
    }

    var pollingRate: Int {
        let savedPollingRate = integer(forKey: Preferences.Key.pollingRate)
        if savedPollingRate >= 3 {
            return savedPollingRate
        }
        set(pollingRate: 3)
        return 3
    }

    func set(pollingRate: Int) {
        set(pollingRate, for: Preferences.Key.pollingRate)
    }

    // MARK: - Primary -> Secondary Sync (Pi-hole v6)

    var syncEnabled: Bool {
        bool(forKey: Preferences.Key.syncEnabled)
    }

    func set(syncEnabled: Bool) {
        set(syncEnabled, for: Preferences.Key.syncEnabled)
    }

    var syncPrimaryIdentifier: String {
        string(forKey: Preferences.Key.syncPrimaryIdentifier) ?? ""
    }

    func set(syncPrimaryIdentifier: String) {
        set(syncPrimaryIdentifier, for: Preferences.Key.syncPrimaryIdentifier)
    }

    var syncSecondaryIdentifier: String {
        string(forKey: Preferences.Key.syncSecondaryIdentifier) ?? ""
    }

    func set(syncSecondaryIdentifier: String) {
        set(syncSecondaryIdentifier, for: Preferences.Key.syncSecondaryIdentifier)
    }

    var syncIntervalMinutes: Int {
        let stored = integer(forKey: Preferences.Key.syncIntervalMinutes)
        if stored >= 5 {
            return stored
        }
        set(syncIntervalMinutes: 15)
        return 15
    }

    func set(syncIntervalMinutes: Int) {
        set(syncIntervalMinutes, for: Preferences.Key.syncIntervalMinutes)
    }

    var syncWipeSecondaryBeforeSync: Bool {
        bool(forKey: Preferences.Key.syncWipeSecondaryBeforeSync)
    }

    func set(syncWipeSecondaryBeforeSync: Bool) {
        set(syncWipeSecondaryBeforeSync, for: Preferences.Key.syncWipeSecondaryBeforeSync)
    }

    var syncLastRunAt: Date? {
        object(forKey: Preferences.Key.syncLastRunAt) as? Date
    }

    func set(syncLastRunAt: Date?) {
        set(syncLastRunAt, for: Preferences.Key.syncLastRunAt)
    }

    var syncLastStatus: String {
        string(forKey: Preferences.Key.syncLastStatus) ?? ""
    }

    func set(syncLastStatus: String) {
        set(syncLastStatus, for: Preferences.Key.syncLastStatus)
    }

    func set(syncLastStatus: SyncStatus) {
        set(syncLastStatus.rawValue, for: Preferences.Key.syncLastStatus)
    }

    var syncLastMessage: String {
        string(forKey: Preferences.Key.syncLastMessage) ?? ""
    }

    func set(syncLastMessage: String) {
        set(syncLastMessage, for: Preferences.Key.syncLastMessage)
    }

    var syncDryRunEnabled: Bool {
        bool(forKey: Preferences.Key.syncDryRunEnabled)
    }

    func set(syncDryRunEnabled: Bool) {
        set(syncDryRunEnabled, for: Preferences.Key.syncDryRunEnabled)
    }

    var syncSkipGroups: Bool {
        bool(forKey: Preferences.Key.syncSkipGroups)
    }

    func set(syncSkipGroups: Bool) {
        set(syncSkipGroups, for: Preferences.Key.syncSkipGroups)
    }

    var syncSkipAdlists: Bool {
        bool(forKey: Preferences.Key.syncSkipAdlists)
    }

    func set(syncSkipAdlists: Bool) {
        set(syncSkipAdlists, for: Preferences.Key.syncSkipAdlists)
    }

    var syncSkipDomains: Bool {
        bool(forKey: Preferences.Key.syncSkipDomains)
    }

    func set(syncSkipDomains: Bool) {
        set(syncSkipDomains, for: Preferences.Key.syncSkipDomains)
    }

    // Helpers

    var showTitle: Bool {
        return showQueries || showBlocked || showPercentage
    }

    /// Loads V3 connections from UserDefaults, migrating any tokens stored in the old keychain
    /// format on first access (one-time, then keychain entries are deleted).
    private func loadPiholesV3() -> [PiholeConnectionV3] {
        let stored = loadPiholesV3FromDefaults()
        var needsResave = false
        var results: [PiholeConnectionV3] = []

        for raw in stored {
            var token = raw.token
            // One-time migration: if no token in UserDefaults, check the old keychain storage.
            if token.isEmpty,
               let keychainToken = (try? KeychainCredentialStore.shared.readString(account: raw.identifier)) ?? nil,
               !keychainToken.isEmpty
            {
                token = keychainToken
                try? KeychainCredentialStore.shared.delete(account: raw.identifier)
                needsResave = true
            }
            results.append(raw.replacingToken(token))
        }

        if needsResave {
            persistPiholesV3(results)
        }

        return results
    }

    private func loadPiholesV3FromDefaults() -> [PiholeConnectionV3] {
        guard let array = array(forKey: Preferences.Key.piholesV3), !array.isEmpty else { return [] }
        var piholesV3: [PiholeConnectionV3] = []
        for data in array {
            Log.debug("Loading V3 Pi-hole")
            guard let data = data as? Data, let piholeConnection = PiholeConnectionV3(data: data) else { continue }
            piholesV3.append(piholeConnection)
        }
        return piholesV3
    }

    private func persistPiholesV3(_ piholes: [PiholeConnectionV3]) {
        let array = piholes.map { $0.encode()! }
        set(array, for: Preferences.Key.piholesV3)
    }
}

private extension UserDefaults {
    func set(_ object: Any?, for key: String) {
        set(object, forKey: key)
        synchronize()
    }
}
