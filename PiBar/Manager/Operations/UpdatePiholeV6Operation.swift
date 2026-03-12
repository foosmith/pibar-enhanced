//
//  UpdatePiholeV6Operation.swift
//  PiBar
//
//  Created by Brad Root on 3/16/25.
//  Copyright © 2025 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

final class UpdatePiholeV6Operation: AsyncOperation, @unchecked Sendable {
    private(set) var pihole: Pihole

    init(_ pihole: Pihole) {
        self.pihole = pihole
    }

    override func main() {
        Log.debug("Updating Pi-hole: \(pihole.identifier)")
        guard let api6 = pihole.api6 else {
            pihole = Pihole(
                api: nil,
                api6: nil,
                identifier: pihole.identifier,
                online: false,
                summary: nil,
                canBeManaged: false,
                enabled: nil,
                isV6: true
            )
            state = .isFinished
            return
        }

        Task { [weak self] in
            guard let self else { return }
            var enabled: Bool? = true
            var online = true
            var canBeManaged = !api6.connection.token.isEmpty || !api6.connection.passwordProtected

            do {
                let result = try await api6.fetchSummary()
                let blockingResult = try await api6.fetchBlockingStatus()

                if blockingResult.blocking != "enabled" {
                    enabled = false
                }

                let newSummary = PiholeAPISummary(
                    domainsBeingBlocked: result.gravity.domainsBeingBlocked,
                    dnsQueriesToday: result.queries.total,
                    adsBlockedToday: result.queries.blocked,
                    adsPercentageToday: result.queries.percentBlocked,
                    uniqueDomains: result.queries.uniqueDomains,
                    queriesForwarded: result.queries.forwarded,
                    queriesCached: result.queries.cached,
                    uniqueClients: result.clients.active,
                    dnsQueriesAllTypes: 0,
                    status: blockingResult.blocking
                )

                self.pihole = Pihole(
                    api: nil,
                    api6: api6,
                    identifier: api6.identifier,
                    online: online,
                    summary: newSummary,
                    canBeManaged: canBeManaged,
                    enabled: enabled,
                    isV6: true
                )
            } catch {
                Log.error(error)
                online = false
                enabled = nil
                canBeManaged = false
                self.pihole = Pihole(
                    api: nil,
                    api6: api6,
                    identifier: api6.identifier,
                    online: online,
                    summary: nil,
                    canBeManaged: canBeManaged,
                    enabled: enabled,
                    isV6: true
                )
            }
            self.state = .isFinished
        }
    }
}
