//
//  Structs.swift
//  PiBar
//
//  Created by Brad Root on 5/18/20.
//  Copyright © 2020 Brad Root. All rights reserved.
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation

// MARK: - Pi-hole Connections

protocol PBConnectionCodable: Codable {}

extension PBConnectionCodable {
    init?(data: Data) {
        let jsonDecoder = JSONDecoder()
        do {
            self = try jsonDecoder.decode(Self.self, from: data)
        } catch {
            Log.debug("Couldn't decode connection: \(error.localizedDescription)")
            return nil
        }
    }

    func encode() -> Data? {
        let jsonEncoder = JSONEncoder()
        return try? jsonEncoder.encode(self)
    }
}

// PiBar v1.0 format
struct PiholeConnectionV1: PBConnectionCodable {
    let hostname: String
    let port: Int
    let useSSL: Bool
    let token: String
}

// PiBar v1.1 format
struct PiholeConnectionV2: PBConnectionCodable {
    let hostname: String
    let port: Int
    let useSSL: Bool
    let token: String
    let passwordProtected: Bool
    let adminPanelURL: String
}

extension PiholeConnectionV2 {
    static func generateAdminPanelURL(hostname: String, port: Int, useSSL: Bool) -> String {
        let prefix: String = useSSL ? "https" : "http"
        return "\(prefix)://\(hostname):\(port)/admin/"
    }
}

// PiBar v1.2 format
struct PiholeConnectionV3: PBConnectionCodable {
    let hostname: String
    let port: Int
    let useSSL: Bool
    let token: String
    let passwordProtected: Bool
    let adminPanelURL: String
    let isV6: Bool
}

extension PiholeConnectionV3 {
    static func generateAdminPanelURL(hostname: String, port: Int, useSSL: Bool) -> String {
        let prefix: String = useSSL ? "https" : "http"
        return "\(prefix)://\(hostname):\(port)/admin/"
    }

    var identifier: String {
        let prefix: String = useSSL ? "https" : "http"
        let version = isV6 ? "v6" : "legacy"
        return "\(prefix)://\(hostname):\(port) [\(version)]"
    }

    func replacingToken(_ token: String) -> PiholeConnectionV3 {
        PiholeConnectionV3(
            hostname: hostname,
            port: port,
            useSSL: useSSL,
            token: token,
            passwordProtected: passwordProtected,
            adminPanelURL: adminPanelURL,
            isV6: isV6
        )
    }
}

enum PiholeConnectionTestResult {
    case success
    case failure
    case failureInvalidToken
}

// MARK: - Pi-hole API

struct PiholeAPIEndpoint {
    let queryParameter: String
    let authorizationRequired: Bool
}

struct PiholeAPISummary: Decodable {
    let domainsBeingBlocked: Int
    let dnsQueriesToday: Int
    let adsBlockedToday: Int
    let adsPercentageToday: Double
    let uniqueDomains: Int
    let queriesForwarded: Int
    let queriesCached: Int
    let uniqueClients: Int
    let dnsQueriesAllTypes: Int
    let status: String
}

struct PiholeAPIStatus: Decodable {
    let status: String
}

// MARK: - Pi-hole Network

enum PiholeNetworkStatus: String {
    case enabled = "Enabled"
    case disabled = "Disabled"
    case partiallyEnabled = "Partially Enabled"
    case offline = "Offline"
    case partiallyOffline = "Partially Offline"
    case noneSet = "No Pi-holes"
    case initializing = "Initializing"
}

struct Pihole {
    let api: PiholeAPI?
    let api6: Pihole6API?
    let identifier: String
    let online: Bool
    let summary: PiholeAPISummary?
    let canBeManaged: Bool?
    let enabled: Bool?
    let isV6: Bool

    var status: PiholeNetworkStatus {
        if !online {
            return .offline
        }
        if let enabled = enabled {
            if enabled {
                return .enabled
            }
            return .disabled
        }
        return .initializing
    }
}

struct PiholeNetworkOverview {
    let networkStatus: PiholeNetworkStatus
    let canBeManaged: Bool
    let totalQueriesToday: Int
    let adsBlockedToday: Int
    let adsPercentageToday: Double
    let averageBlocklist: Int

    let piholes: [String: Pihole]
}
