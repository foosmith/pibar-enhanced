//
//  SyncPrimarySecondaryDryRunOperation.swift
//  PiBar
//
//  Created by Codex on 3/12/26.
//

import Foundation

final class SyncPrimarySecondaryDryRunOperation: AsyncOperation, @unchecked Sendable {
    private(set) var resultMessage: String = ""

    override func main() {
        Task { [weak self] in
            guard let self else { return }
            defer { self.state = .isFinished }

            let enabled = Preferences.standard.syncEnabled
            if !enabled {
                self.resultMessage = "Sync disabled."
                Preferences.standard.set(syncLastStatus: "skipped")
                Preferences.standard.set(syncLastMessage: self.resultMessage)
                Preferences.standard.set(syncLastRunAt: Date())
                return
            }

            let primaryId = Preferences.standard.syncPrimaryIdentifier
            let secondaryId = Preferences.standard.syncSecondaryIdentifier
            if primaryId.isEmpty || secondaryId.isEmpty || primaryId == secondaryId {
                self.resultMessage = "Select distinct Primary and Secondary."
                Preferences.standard.set(syncLastStatus: "skipped")
                Preferences.standard.set(syncLastMessage: self.resultMessage)
                Preferences.standard.set(syncLastRunAt: Date())
                return
            }

            let connections = Preferences.standard.piholes.filter(\.isV6)
            guard
                let primaryConnection = connections.first(where: { $0.identifier == primaryId }),
                let secondaryConnection = connections.first(where: { $0.identifier == secondaryId })
            else {
                self.resultMessage = "Primary/Secondary connections not found."
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: self.resultMessage)
                Preferences.standard.set(syncLastRunAt: Date())
                return
            }

            let primaryAPI = Pihole6API(connection: primaryConnection)
            let secondaryAPI = Pihole6API(connection: secondaryConnection)

            do {
                let dryRun = try await computeDryRun(primary: primaryAPI, secondary: secondaryAPI)
                self.resultMessage = dryRun
                Preferences.standard.set(syncLastStatus: "dry-run")
                Preferences.standard.set(syncLastMessage: dryRun)
                Preferences.standard.set(syncLastRunAt: Date())
            } catch let apiError as APIError {
                self.resultMessage = "Dry run failed: \(apiError)"
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: self.resultMessage)
                Preferences.standard.set(syncLastRunAt: Date())
            } catch {
                self.resultMessage = "Dry run failed: \(error.localizedDescription)"
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: self.resultMessage)
                Preferences.standard.set(syncLastRunAt: Date())
            }
        }
    }

    private func computeDryRun(primary: Pihole6API, secondary: Pihole6API) async throws -> String {
        // Phase 2: read-only diff engine. Endpoints assumed verified in Phase 0.
        async let primaryGroups = fetchGroups(api: primary)
        async let secondaryGroups = fetchGroups(api: secondary)
        async let primaryLists = fetchAdlists(api: primary)
        async let secondaryLists = fetchAdlists(api: secondary)
        async let primaryDomains = fetchDomains(api: primary)
        async let secondaryDomains = fetchDomains(api: secondary)

        let (pg, sg, pl, sl, pd, sd) = try await (primaryGroups, secondaryGroups, primaryLists, secondaryLists, primaryDomains, secondaryDomains)

        let groupDiff = diffByKey(primary: pg, secondary: sg, key: \.name)
        let listDiff = diffByKey(primary: pl, secondary: sl, key: \.address)

        var domainSummary: [String] = []
        for bucket in DomainBucket.allCases {
            let diff = diffByKey(primary: pd[bucket] ?? [], secondary: sd[bucket] ?? [], key: \.domain)
            domainSummary.append("\(bucket.label): +\(diff.add) ~\(diff.update) -\(diff.remove)")
        }

        let summary = [
            "Dry run (no changes applied):",
            "Groups: +\(groupDiff.add) ~\(groupDiff.update) -\(groupDiff.remove) (extras disabled later)",
            "Adlists: +\(listDiff.add) ~\(listDiff.update) -\(listDiff.remove)",
            "Domains: \(domainSummary.joined(separator: "; "))",
        ].joined(separator: " ")

        return summary
    }

    // MARK: - Models

    private struct Group: Hashable {
        let name: String
        let enabled: Bool?
        let comment: String?
    }

    private struct Adlist: Hashable {
        let address: String
        let enabled: Bool?
        let comment: String?
        let groups: Set<String>
    }

    private struct Domain: Hashable {
        let domain: String
        let enabled: Bool?
        let comment: String?
        let groups: Set<String>
    }

    private enum DomainBucket: CaseIterable {
        case allowExact
        case denyExact
        case allowRegex
        case denyRegex

        var path: String {
            switch self {
            case .allowExact: return "/domains/allow/exact"
            case .denyExact: return "/domains/deny/exact"
            case .allowRegex: return "/domains/allow/regex"
            case .denyRegex: return "/domains/deny/regex"
            }
        }

        var label: String {
            switch self {
            case .allowExact: return "allow/exact"
            case .denyExact: return "deny/exact"
            case .allowRegex: return "allow/regex"
            case .denyRegex: return "deny/regex"
            }
        }
    }

    // MARK: - Fetch + Parse (tolerant JSON)

    private func fetchGroups(api: Pihole6API) async throws -> [Group] {
        let data = try await api.getData("/groups", apiKey: api.connection.token)
        let object = try JSONSerialization.jsonObject(with: data)

        let groupsArray: [Any]
        if let dict = object as? [String: Any], let raw = dict["groups"] as? [Any] {
            groupsArray = raw
        } else if let array = object as? [Any] {
            groupsArray = array
        } else {
            return []
        }

        return groupsArray.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            guard let name = d["name"] as? String, !name.isEmpty else { return nil }
            let enabled = d["enabled"] as? Bool
            let comment = (d["comment"] as? String) ?? (d["description"] as? String)
            return Group(name: name, enabled: enabled, comment: comment)
        }
    }

    private func fetchAdlists(api: Pihole6API) async throws -> [Adlist] {
        let data = try await api.getData("/lists", apiKey: api.connection.token)
        let object = try JSONSerialization.jsonObject(with: data)

        let listsArray: [Any]
        if let dict = object as? [String: Any], let raw = dict["lists"] as? [Any] {
            listsArray = raw
        } else if let array = object as? [Any] {
            listsArray = array
        } else {
            return []
        }

        // Group mapping by id -> name if present in the response, otherwise assignments become id strings.
        let groupIdToName = extractGroupIdToName(from: object)

        return listsArray.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            if let type = d["type"] as? String, type != "block" {
                return nil
            }
            guard let address = d["address"] as? String, !address.isEmpty else { return nil }
            let enabled = d["enabled"] as? Bool
            let comment = d["comment"] as? String
            let groups = groupNames(from: d["groups"], idToName: groupIdToName)
            return Adlist(address: address, enabled: enabled, comment: comment, groups: groups)
        }
    }

    private func fetchDomains(api: Pihole6API) async throws -> [DomainBucket: [Domain]] {
        async let groups = fetchGroups(api: api)
        let groupsByName = try await groups
        let nameById: [Int: String] = {
            // If the API returns ids, we can’t rely on them here; but if present in group objects, use them.
            // This uses a best-effort parse from raw JSON via `extractGroupIdToName` in each bucket response.
            _ = groupsByName
            return [:]
        }()
        _ = nameById

        var results: [DomainBucket: [Domain]] = [:]
        for bucket in DomainBucket.allCases {
            let data = try await api.getData(bucket.path, apiKey: api.connection.token)
            let object = try JSONSerialization.jsonObject(with: data)

            let domainsArray: [Any]
            if let dict = object as? [String: Any], let raw = dict["domains"] as? [Any] {
                domainsArray = raw
            } else if let array = object as? [Any] {
                domainsArray = array
            } else {
                results[bucket] = []
                continue
            }

            let groupIdToName = extractGroupIdToName(from: object)
            let domains: [Domain] = domainsArray.compactMap { item in
                guard let d = item as? [String: Any] else { return nil }
                guard let domain = d["domain"] as? String, !domain.isEmpty else { return nil }
                let enabled = d["enabled"] as? Bool
                let comment = d["comment"] as? String
                let groups = groupNames(from: d["groups"], idToName: groupIdToName)
                return Domain(domain: domain, enabled: enabled, comment: comment, groups: groups)
            }
            results[bucket] = domains
        }
        return results
    }

    private func extractGroupIdToName(from object: Any) -> [Int: String] {
        guard let dict = object as? [String: Any] else { return [:] }
        guard let groups = dict["groups"] as? [Any] else { return [:] }
        var map: [Int: String] = [:]
        for item in groups {
            guard let d = item as? [String: Any] else { continue }
            guard let id = d["id"] as? Int else { continue }
            guard let name = d["name"] as? String else { continue }
            map[id] = name
        }
        return map
    }

    private func groupNames(from raw: Any?, idToName: [Int: String]) -> Set<String> {
        if let ids = raw as? [Int] {
            return Set(ids.map { idToName[$0] ?? "id:\($0)" })
        }
        if let idsAny = raw as? [Any] {
            let ids = idsAny.compactMap { $0 as? Int }
            if !ids.isEmpty {
                return Set(ids.map { idToName[$0] ?? "id:\($0)" })
            }
        }
        return []
    }

    // MARK: - Diff

    private struct DiffCounts {
        let add: Int
        let update: Int
        let remove: Int
    }

    private func diffByKey<T: Hashable, K: Hashable>(
        primary: [T],
        secondary: [T],
        key: (T) -> K
    ) -> DiffCounts {
        let primaryByKey: [K: T] = Dictionary(uniqueKeysWithValues: primary.map { (key($0), $0) })
        let secondaryByKey: [K: T] = Dictionary(uniqueKeysWithValues: secondary.map { (key($0), $0) })

        let primaryKeys = Set(primaryByKey.keys)
        let secondaryKeys = Set(secondaryByKey.keys)

        let toAdd = primaryKeys.subtracting(secondaryKeys).count
        let toRemove = secondaryKeys.subtracting(primaryKeys).count

        var toUpdate = 0
        for k in primaryKeys.intersection(secondaryKeys) {
            if primaryByKey[k] != secondaryByKey[k] {
                toUpdate += 1
            }
        }

        return DiffCounts(add: toAdd, update: toUpdate, remove: toRemove)
    }
}
