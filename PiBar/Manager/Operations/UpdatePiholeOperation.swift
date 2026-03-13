//
//  UpdatePiholeOperation.swift
//  PiBar
//
//  Created by Brad Root on 5/26/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

final class UpdatePiholeOperation: AsyncOperation, @unchecked Sendable {
    private(set) var pihole: Pihole

    init(_ pihole: Pihole) {
        self.pihole = pihole
    }

    override func main() {
        Log.debug("Updating Pi-hole: \(pihole.identifier)")
        guard let api = pihole.api else {
            pihole = Pihole(
                api: nil,
                api6: nil,
                identifier: pihole.identifier,
                online: false,
                summary: nil,
                canBeManaged: false,
                enabled: nil,
                isV6: false,
                topDomains: [],
                topClients: []
            )
            state = .isFinished
            return
        }

        api.fetchSummary { [weak self] summary in
            guard let self else { return }
            Log.debug("Received Summary for \(self.pihole.identifier)")
            var enabled: Bool? = true
            var online = true
            var canBeManaged: Bool = false
            var topDomains: [TopListEntry] = []
            var topClients: [TopListEntry] = []

            if let summary = summary {
                if summary.status != "enabled" {
                    enabled = false
                }
                if !api.connection.token.isEmpty || !api.connection.passwordProtected {
                    canBeManaged = true
                }

                let group = DispatchGroup()
                group.enter()
                api.fetchTopDomains { entries in
                    topDomains = entries
                    group.leave()
                }
                group.enter()
                api.fetchTopClients { entries in
                    topClients = entries
                    group.leave()
                }
                group.notify(queue: .global(qos: .background)) {
                    let updatedPihole: Pihole = Pihole(
                        api: api,
                        api6: nil,
                        identifier: api.identifier,
                        online: online,
                        summary: summary,
                        canBeManaged: canBeManaged,
                        enabled: enabled,
                        isV6: false,
                        topDomains: topDomains,
                        topClients: topClients
                    )

                    self.pihole = updatedPihole
                    self.state = .isFinished
                }
                return
            } else {
                enabled = nil
                online = false
                canBeManaged = false
            }

            let updatedPihole: Pihole = Pihole(
                api: api,
                api6: nil,
                identifier: api.identifier,
                online: online,
                summary: summary,
                canBeManaged: canBeManaged,
                enabled: enabled,
                isV6: false,
                topDomains: [],
                topClients: []
            )

            self.pihole = updatedPihole

            self.state = .isFinished
        }
    }
}
