//
//  PiBarManager.swift
//  PiBar
//
//  Created by Brad Root on 5/20/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

protocol PiBarManagerDelegate: AnyObject {
    func updateNetwork(_ network: PiholeNetworkOverview)
}

class PiBarManager: NSObject {
    private var piholes: [String: Pihole] = [:]
    private let piholesLock = NSLock()
    private let updateStateLock = NSLock()
    private var isUpdateInFlight = false
    private var refreshRequested = false

    private let syncStateLock = NSLock()
    private var isSyncInFlight = false
    private var syncRequested = false
    private var syncTimer: Timer?
    private var syncInterval: TimeInterval = 15 * 60

    private var networkOverview: PiholeNetworkOverview {
        didSet {
            delegate?.updateNetwork(networkOverview)
        }
    }

    private var timer: Timer?
    private var updateInterval: TimeInterval
    private let operationQueue: OperationQueue = OperationQueue()

    override init() {
        #if DEBUG
        Log.logLevel = .debug
        Log.useEmoji = true
        #else
        Log.logLevel = .off
        Log.useEmoji = false
        #endif

        operationQueue.maxConcurrentOperationCount = 1

        updateInterval = TimeInterval(Preferences.standard.pollingRate)

        networkOverview = PiholeNetworkOverview(
            networkStatus: .initializing,
            canBeManaged: false,
            totalQueriesToday: 0,
            adsBlockedToday: 0,
            adsPercentageToday: 0.0,
            averageBlocklist: 0,
            piholes: [:]
        )
        super.init()

        delegate?.updateNetwork(networkOverview)

        loadConnections()
    }

    // MARK: - Public Variables and Functions

    weak var delegate: PiBarManagerDelegate?

    func loadConnections() {
        createPiholes(Preferences.standard.piholes)
    }

    func setPollingRate(to seconds: Int) {
        let newPollingRate = TimeInterval(seconds)
        if newPollingRate != updateInterval {
            Log.debug("Changed polling rate to: \(seconds)")
            updateInterval = newPollingRate
            startTimer()
        }
    }

    func configureSyncFromPreferences() {
        stopSyncTimer()

        let enabled = Preferences.standard.syncEnabled
        let minutes = Preferences.standard.syncIntervalMinutes
        let interval = TimeInterval(minutes) * 60
        syncInterval = interval

        guard enabled else {
            return
        }

        // Don't bother scheduling if Primary/Secondary aren't configured.
        let primaryId = Preferences.standard.syncPrimaryIdentifier
        let secondaryId = Preferences.standard.syncSecondaryIdentifier
        guard !primaryId.isEmpty, !secondaryId.isEmpty, primaryId != secondaryId else {
            return
        }

        let newTimer = Timer(timeInterval: syncInterval, target: self, selector: #selector(syncFromTimer), userInfo: nil, repeats: true)
        newTimer.tolerance = 10
        RunLoop.main.add(newTimer, forMode: .common)
        syncTimer = newTimer
        Log.debug("Manager: Sync Timer Started")
    }

    func syncNow() {
        enqueueFullSync()
    }

    // Enable / Disable Pi-hole(s)

    func toggleNetwork() {
        piholesLock.lock()
        let snapshot = piholes
        piholesLock.unlock()
        let status = networkStatus(in: snapshot)

        if status == .enabled || status == .partiallyEnabled {
            disableNetwork()
        } else if status == .disabled {
            enableNetwork()
        }
    }

    func disableNetwork(seconds: Int? = nil) {
        stopTimer()

        let completionOperation = BlockOperation {
            self.updatePiholes()
            self.startTimer()
        }
        piholesLock.lock()
        let snapshot = Array(piholes.values)
        piholesLock.unlock()
        snapshot.forEach { pihole in
            let operation = ChangePiholeStatusOperation(pihole: pihole, status: .disable, seconds: seconds)
            completionOperation.addDependency(operation)
            operationQueue.addOperation(operation)
        }
        operationQueue.addOperation(completionOperation)
    }

    func enableNetwork() {
        stopTimer()

        let completionOperation = BlockOperation {
            self.updatePiholes()
            self.startTimer()
        }
        piholesLock.lock()
        let snapshot = Array(piholes.values)
        piholesLock.unlock()
        snapshot.forEach { pihole in
            let operation = ChangePiholeStatusOperation(pihole: pihole, status: .enable)
            completionOperation.addDependency(operation)
            operationQueue.addOperation(operation)
        }
        operationQueue.addOperation(completionOperation)
    }

    // MARK: - Private Functions

    // MARK: Timer

    private func startTimer() {
        stopTimer()

        let newTimer = Timer(timeInterval: updateInterval, target: self, selector: #selector(updatePiholes), userInfo: nil, repeats: true)
        newTimer.tolerance = 0.2
        RunLoop.main.add(newTimer, forMode: .common)

        timer = newTimer

        Log.debug("Manager: Timer Started")
    }

    private func stopTimer() {
        if let existingTimer = timer {
            Log.debug("Manager: Timer Stopped")
            existingTimer.invalidate()
            timer = nil
        }
    }

    private func stopSyncTimer() {
        if let existingTimer = syncTimer {
            Log.debug("Manager: Sync Timer Stopped")
            existingTimer.invalidate()
            syncTimer = nil
        }
    }

    // MARK: Data Updates

    private func createNewNetwork() {
        networkOverview = PiholeNetworkOverview(
            networkStatus: .initializing,
            canBeManaged: false,
            totalQueriesToday: 0,
            adsBlockedToday: 0,
            adsPercentageToday: 0.0,
            averageBlocklist: 0,
            piholes: [:]
        )
    }

    private func createPiholes(_ connections: [PiholeConnectionV3]) {
        Log.debug("Manager: Updating Connections")

        stopTimer()
        piholesLock.lock()
        piholes.removeAll()
        piholesLock.unlock()
        createNewNetwork()
        
        for connection in connections {
            Log.debug("Manager: Updating Connection: \(connection.hostname)")
            if connection.isV6 {
                let api = Pihole6API(connection: connection)
                piholesLock.lock()
                piholes[api.identifier] = Pihole(
                    api: nil,
                    api6: api,
                    identifier: api.identifier,
                    online: false,
                    summary: nil,
                    canBeManaged: nil,
                    enabled: nil,
                    isV6: true
                )
                piholesLock.unlock()
            } else {
                let api = PiholeAPI(connection: connection)
                piholesLock.lock()
                piholes[api.identifier] = Pihole(
                    api: api,
                    api6: nil,
                    identifier: api.identifier,
                    online: false,
                    summary: nil,
                    canBeManaged: nil,
                    enabled: nil,
                    isV6: false
                )
                piholesLock.unlock()
                    
            }
        }

        updatePiholes()

        startTimer()
        configureSyncFromPreferences()
    }

    @objc private func updatePiholes() {
        updateStateLock.lock()
        if isUpdateInFlight {
            refreshRequested = true
            updateStateLock.unlock()
            return
        }
        isUpdateInFlight = true
        updateStateLock.unlock()

        Log.debug("Manager: Updating Pi-holes")

        var v6Operations: [UpdatePiholeV6Operation] = []
        var legacyOperations: [UpdatePiholeOperation] = []

        let completionOperation = BlockOperation { [weak self] in
            guard let self else { return }

            self.piholesLock.lock()
            for operation in v6Operations {
                self.piholes[operation.pihole.identifier] = operation.pihole
            }
            for operation in legacyOperations {
                self.piholes[operation.pihole.identifier] = operation.pihole
            }
            self.piholesLock.unlock()

            self.updateNetworkOverview()

            self.updateStateLock.lock()
            self.isUpdateInFlight = false
            let shouldRefreshAgain = self.refreshRequested
            self.refreshRequested = false
            self.updateStateLock.unlock()

            if shouldRefreshAgain {
                self.updatePiholes()
            }
        }

        piholesLock.lock()
        let snapshot = Array(piholes.values)
        piholesLock.unlock()

        for pihole in snapshot {
            if pihole.isV6 {
                Log.debug("Creating operation for \(pihole.identifier)")
                let operation = UpdatePiholeV6Operation(pihole)
                completionOperation.addDependency(operation)
                operationQueue.addOperation(operation)
                v6Operations.append(operation)
            } else {
                Log.debug("Creating operation for \(pihole.identifier)")
                let operation = UpdatePiholeOperation(pihole)
                completionOperation.addDependency(operation)
                operationQueue.addOperation(operation)
                legacyOperations.append(operation)
            }
        }

        operationQueue.addOperation(completionOperation)
    }

    private func updateNetworkOverview() {
        Log.debug("Updating Network Overview")

        piholesLock.lock()
        let snapshot = piholes
        piholesLock.unlock()

        networkOverview = PiholeNetworkOverview(
            networkStatus: networkStatus(in: snapshot),
            canBeManaged: canManage(in: snapshot),
            totalQueriesToday: networkTotalQueries(in: snapshot),
            adsBlockedToday: networkBlockedQueries(in: snapshot),
            adsPercentageToday: networkPercentageBlocked(in: snapshot),
            averageBlocklist: networkBlocklist(in: snapshot),
            piholes: snapshot
        )
    }

    // MARK: - Sync

    @objc private func syncFromTimer() {
        enqueueFullSync()
    }

    private func enqueueFullSync() {
        syncStateLock.lock()
        if isSyncInFlight {
            syncRequested = true
            syncStateLock.unlock()
            return
        }
        isSyncInFlight = true
        syncStateLock.unlock()

        Log.debug("Manager: Enqueuing full sync (groups + adlists + domains)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .piBarSyncBegan, object: nil)
        }

        let operation = SyncPrimarySecondaryOperation()

        let completion = BlockOperation { [weak self] in
            guard let self else { return }
            self.syncStateLock.lock()
            self.isSyncInFlight = false
            let shouldRunAgain = self.syncRequested
            self.syncRequested = false
            self.syncStateLock.unlock()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .piBarSyncEnded, object: nil)
            }

            if shouldRunAgain {
                self.enqueueFullSync()
            }
        }

        completion.addDependency(operation)
        operationQueue.addOperation(operation)
        operationQueue.addOperation(completion)
    }

    private func networkTotalQueries(in piholes: [String: Pihole]) -> Int {
        var queries: Int = 0
        piholes.values.forEach {
            queries += $0.summary?.dnsQueriesToday ?? 0
        }
        return queries
    }

    private func networkBlockedQueries(in piholes: [String: Pihole]) -> Int {
        var queries: Int = 0
        piholes.values.forEach {
            queries += $0.summary?.adsBlockedToday ?? 0
        }
        return queries
    }

    private func networkPercentageBlocked(in piholes: [String: Pihole]) -> Double {
        let totalQueries = networkTotalQueries(in: piholes)
        let blockedQueries = networkBlockedQueries(in: piholes)
        if totalQueries == 0 || blockedQueries == 0 {
            return 0.0
        }
        return Double(blockedQueries) / Double(totalQueries) * 100.0
    }

    private func networkBlocklist(in piholes: [String: Pihole]) -> Int {
        var blocklistCounts: [Int] = []
        piholes.values.forEach {
            blocklistCounts.append($0.summary?.domainsBeingBlocked ?? 0)
        }
        return blocklistCounts.average()
    }

    private func networkStatus(in piholes: [String: Pihole]) -> PiholeNetworkStatus {
        var summaries: [PiholeAPISummary] = []
        piholes.values.forEach {
            if let summary = $0.summary { summaries.append(summary) }
        }

        if piholes.isEmpty {
            return .noneSet
        } else if summaries.isEmpty {
            return .offline
        } else if summaries.count < piholes.count {
            return .partiallyOffline
        }

        var status = Set<String>()
        summaries.forEach {
            status.insert($0.status)
        }
        if status.count == 1 {
            let statusString = status.first!
            if statusString == "enabled" {
                return .enabled
            } else {
                return .disabled
            }
        } else {
            return .partiallyEnabled
        }
    }

    private func canManage(in piholes: [String: Pihole]) -> Bool {
        for pihole in piholes.values where pihole.canBeManaged ?? false {
            return true
        }

        return false
    }
}
