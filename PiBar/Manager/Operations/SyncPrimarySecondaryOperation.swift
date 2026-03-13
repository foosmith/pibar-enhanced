//
//  SyncPrimarySecondaryOperation.swift
//  PiBar
//
//  Full Primary → Secondary sync covering Phase 3 (adlists), Phase 4 (domains),
//  and Phase 5 (groups + group ID translation for adlists/domains).
//
//  Sync order: groups first (so secondary group IDs are available for translation),
//  then adlists, then each domain bucket.
//
//  Respects preferences:
//  - syncDryRunEnabled  — compute diffs but skip all writes
//  - syncSkipGroups     — fetch groups for ID translation but skip group writes
//  - syncSkipAdlists    — skip adlist sync entirely
//  - syncSkipDomains    — skip domain sync entirely
//

import Foundation

final class SyncPrimarySecondaryOperation: AsyncOperation, @unchecked Sendable {

    override func main() {
        Task { [weak self] in
            guard let self else { return }
            defer { self.state = .isFinished }

            let isDryRun = Preferences.standard.syncDryRunEnabled
            let skipGroups = Preferences.standard.syncSkipGroups
            let skipAdlists = Preferences.standard.syncSkipAdlists
            let skipDomains = Preferences.standard.syncSkipDomains

            let modeTag = isDryRun ? " [dry run]" : ""
            SyncProgress.report("Sync\(modeTag): starting…")

            guard Preferences.standard.syncEnabled else {
                self.record(status: .skipped, message: "Sync disabled.")
                SyncProgress.report("Sync: skipped (disabled).")
                return
            }

            let primaryId = Preferences.standard.syncPrimaryIdentifier
            let secondaryId = Preferences.standard.syncSecondaryIdentifier
            guard !primaryId.isEmpty, !secondaryId.isEmpty, primaryId != secondaryId else {
                self.record(status: .skipped, message: "Select distinct Primary and Secondary.")
                SyncProgress.report("Sync: skipped (select distinct Primary/Secondary).")
                return
            }

            let connections = Preferences.standard.piholes.filter(\.isV6)
            guard
                let primaryConnection = connections.first(where: { $0.identifier == primaryId }),
                let secondaryConnection = connections.first(where: { $0.identifier == secondaryId })
            else {
                self.record(status: .failed, message: "Primary/Secondary connections not found.")
                SyncProgress.report("Sync: failed (connections not found).")
                return
            }

            if primaryConnection.passwordProtected, primaryConnection.token.isEmpty {
                self.record(status: .failed, message: "Primary requires authentication (missing session).")
                SyncProgress.report("Sync: failed (primary missing session).")
                return
            }
            if secondaryConnection.passwordProtected, secondaryConnection.token.isEmpty {
                self.record(status: .failed, message: "Secondary requires authentication (missing session).")
                SyncProgress.report("Sync: failed (secondary missing session).")
                return
            }

            let primary = Pihole6API(connection: primaryConnection)
            let secondary = Pihole6API(connection: secondaryConnection)

            do {
                // Phase 5: Sync groups first to build ID-translation maps.
                // Groups are always fetched even when skipped so adlists/domains can translate IDs.
                let (groupsSummary, primaryIdToName, secondaryNameToId) = try await self.syncGroups(
                    primary: primary, secondary: secondary,
                    dryRun: isDryRun, skip: skipGroups
                )

                // Phase 3: Adlists
                var adlistsSummary = "Adlists: skipped"
                if !skipAdlists {
                    if Preferences.standard.syncWipeSecondaryBeforeSync && !isDryRun {
                        try await self.wipeSecondaryAdlists(secondary: secondary)
                    }
                    adlistsSummary = try await self.syncAdlists(
                        primary: primary, secondary: secondary,
                        primaryIdToName: primaryIdToName,
                        secondaryNameToId: secondaryNameToId,
                        dryRun: isDryRun
                    )
                }

                // Phase 4: Domains — run all 4 buckets in parallel
                var domainsSummary = "Domains: skipped"
                if !skipDomains {
                    typealias BucketResult = (bucket: DomainBucket, created: Int, updated: Int, deleted: Int)
                    var bucketResults: [BucketResult] = []
                    try await withThrowingTaskGroup(of: BucketResult.self) { group in
                        for bucket in DomainBucket.allCases {
                            group.addTask {
                                let (c, u, d) = try await self.syncDomainBucket(
                                    bucket: bucket,
                                    primary: primary, secondary: secondary,
                                    primaryIdToName: primaryIdToName,
                                    secondaryNameToId: secondaryNameToId,
                                    dryRun: isDryRun
                                )
                                return (bucket, c, u, d)
                            }
                        }
                        for try await result in group {
                            bucketResults.append(result)
                        }
                    }
                    let domainParts = DomainBucket.allCases.compactMap { bucket -> String? in
                        guard let r = bucketResults.first(where: { $0.bucket == bucket }) else { return nil }
                        return "\(bucket.label): +\(r.created) ~\(r.updated) -\(r.deleted)"
                    }
                    domainsSummary = "Domains – \(domainParts.joined(separator: "; "))"
                }

                let fullSummary = "\(groupsSummary) | \(adlistsSummary) | \(domainsSummary)"
                self.record(status: isDryRun ? .dryRun : .success, message: fullSummary)
                SyncProgress.report("Sync\(modeTag): complete. \(fullSummary)")

            } catch let apiError as APIError {
                let message: String
                switch apiError {
                case .forbidden:
                    message = "Secondary rejected writes (403). Enable Pi-hole v6 app_sudo (webserver.api.app_sudo=true)."
                case .unauthorized:
                    message = "Unauthorized (401). Re-authenticate Primary/Secondary in Preferences."
                case let .invalidResponse(statusCode: code, content: content):
                    message = "Sync failed (\(code)). \(content)"
                default:
                    message = "Sync failed: \(apiError)"
                }
                self.record(status: .failed, message: message)
                SyncProgress.report("Sync: \(message)")
            } catch {
                let message = "Sync failed: \(error.localizedDescription)"
                self.record(status: .failed, message: message)
                SyncProgress.report("Sync: \(message)")
            }
        }
    }

    // MARK: - Status Helpers

    private func record(status: SyncStatus, message: String) {
        Preferences.standard.set(syncLastStatus: status)
        Preferences.standard.set(syncLastMessage: message)
        Preferences.standard.set(syncLastRunAt: Date())
    }

    // MARK: - Models

    private struct Group {
        let id: Int
        let name: String
        let enabled: Bool
        let comment: String?
    }

    private struct GroupCreateRequest: Encodable {
        let name: String
        let enabled: Bool?
        let comment: String?
    }

    private struct GroupUpdateRequest: Encodable {
        let enabled: Bool?
        let comment: String?
    }

    private struct Adlist {
        let id: Int?
        let addressStored: String
        let addressNormalized: String
        let enabled: Bool?
        let comment: String?
        let groups: [Int]
    }

    private struct AdlistCreateRequest: Encodable {
        let address: String
        let type: String
        let enabled: Bool?
        let comment: String?
        let groups: [Int]?
    }

    private struct AdlistUpdateRequest: Encodable {
        let type: String?
        let address: String?
        let enabled: Bool?
        let comment: String?
        let groups: [Int]?
    }

    private struct Domain {
        let id: Int?
        let domain: String
        let enabled: Bool?
        let comment: String?
        let groups: [Int]
    }

    private struct DomainCreateRequest: Encodable {
        let domain: String
        let enabled: Bool?
        let comment: String?
        let groups: [Int]?
    }

    private struct DomainUpdateRequest: Encodable {
        let enabled: Bool?
        let comment: String?
        let groups: [Int]?
    }

    private enum DomainBucket: CaseIterable {
        case allowExact
        case denyExact
        case allowRegex
        case denyRegex

        var bucketType: String {
            switch self {
            case .allowExact, .allowRegex: return "allow"
            case .denyExact, .denyRegex: return "deny"
            }
        }

        var kind: String {
            switch self {
            case .allowExact, .denyExact: return "exact"
            case .allowRegex, .denyRegex: return "regex"
            }
        }

        var path: String { "/domains/\(bucketType)/\(kind)" }
        var label: String { "\(bucketType)/\(kind)" }
    }

    // MARK: - Group Sync (Phase 5)

    /// Syncs group definitions and returns ID-translation maps.
    /// Groups are always fetched even when `skip` is true so that adlists/domains can translate IDs.
    private func syncGroups(
        primary: Pihole6API,
        secondary: Pihole6API,
        dryRun: Bool,
        skip: Bool
    ) async throws -> (summary: String, primaryIdToName: [Int: String], secondaryNameToId: [String: Int]) {

        async let pg = fetchGroups(api: primary)
        async let sg = fetchGroups(api: secondary)
        let (primaryGroups, secondaryGroups) = try await (pg, sg)

        let pgByName = Dictionary(primaryGroups.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let sgByName = Dictionary(secondaryGroups.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // Compute planned changes
        var toCreate: [(String, Group)] = []
        var toUpdate: [(String, Group)] = []
        var toDisable: [String] = []

        for (name, primaryGroup) in pgByName {
            if let secGroup = sgByName[name] {
                if secGroup.enabled != primaryGroup.enabled || secGroup.comment != primaryGroup.comment {
                    toUpdate.append((name, primaryGroup))
                }
            } else {
                toCreate.append((name, primaryGroup))
            }
        }
        for (name, secGroup) in sgByName where pgByName[name] == nil {
            if secGroup.enabled { toDisable.append(name) }
        }

        // Apply unless skipped or dry-run
        if !skip && !dryRun {
            for (name, group) in toCreate {
                try await createGroup(api: secondary, name: name, enabled: group.enabled, comment: group.comment)
            }
            for (name, group) in toUpdate {
                try await updateGroup(api: secondary, name: name, enabled: group.enabled, comment: group.comment)
            }
            for name in toDisable {
                if let secGroup = sgByName[name] {
                    try await updateGroup(api: secondary, name: name, enabled: false, comment: secGroup.comment)
                }
            }
        }

        let primaryIdToName = Dictionary(primaryGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        // Re-fetch secondary only if we actually created new groups (so we get their IDs).
        let sgFinal: [Group]
        if !skip && !dryRun && !toCreate.isEmpty {
            sgFinal = try await fetchGroups(api: secondary)
        } else {
            sgFinal = secondaryGroups
        }
        let secondaryNameToId = Dictionary(sgFinal.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })

        let summary: String
        if skip {
            summary = "Groups: skipped (ID maps built)"
        } else if dryRun {
            summary = "[Dry run] Groups: would +\(toCreate.count) ~\(toUpdate.count) (\(toDisable.count) extras would be disabled)"
        } else {
            summary = "Groups: +\(toCreate.count) ~\(toUpdate.count) (\(toDisable.count) extras disabled)"
        }

        SyncProgress.report("Sync: \(summary)")
        return (summary, primaryIdToName, secondaryNameToId)
    }

    private func fetchGroups(api: Pihole6API) async throws -> [Group] {
        let data = try await api.getData("/groups", apiKey: api.connection.token)
        let object = try JSONSerialization.jsonObject(with: data)

        let array: [Any]
        if let dict = object as? [String: Any], let raw = dict["groups"] as? [Any] {
            array = raw
        } else if let raw = object as? [Any] {
            array = raw
        } else {
            return []
        }

        return array.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            guard let name = d["name"] as? String, !name.isEmpty else { return nil }
            guard let id = d["id"] as? Int else { return nil }
            let enabled = (d["enabled"] as? Bool) ?? true
            let comment = d["comment"] as? String
            return Group(id: id, name: name, enabled: enabled, comment: comment)
        }
    }

    private func createGroup(api: Pihole6API, name: String, enabled: Bool, comment: String?) async throws {
        _ = try await api.postData(
            "/groups",
            apiKey: api.connection.token,
            queryItems: [URLQueryItem(name: "app_sudo", value: "true")],
            body: GroupCreateRequest(name: name, enabled: enabled, comment: comment)
        )
    }

    private func updateGroup(api: Pihole6API, name: String, enabled: Bool, comment: String?) async throws {
        let encoded = Pihole6API.encodePathComponent(name)
        _ = try await api.putData(
            "/groups/\(encoded)",
            apiKey: api.connection.token,
            queryItems: [URLQueryItem(name: "app_sudo", value: "true")],
            body: GroupUpdateRequest(enabled: enabled, comment: comment)
        )
    }

    // MARK: - Group ID Translation

    private func translateGroupIds(
        _ primaryIds: [Int],
        primaryIdToName: [Int: String],
        secondaryNameToId: [String: Int]
    ) -> [Int] {
        primaryIds.compactMap { id in
            guard let name = primaryIdToName[id] else { return nil }
            return secondaryNameToId[name]
        }
    }

    // MARK: - Adlist Sync (Phase 3)

    private func syncAdlists(
        primary: Pihole6API,
        secondary: Pihole6API,
        primaryIdToName: [Int: String],
        secondaryNameToId: [String: Int],
        dryRun: Bool
    ) async throws -> String {
        SyncProgress.report("Sync: fetching adlists…")
        async let primaryLists = fetchAdlists(api: primary)
        async let secondaryListsRaw = fetchAdlists(api: secondary)
        let (pl, slRaw) = try await (primaryLists, secondaryListsRaw)

        // Only sanitise percent-encoded URLs when we can actually write fixes.
        let sl = dryRun ? slRaw : (try await sanitizeSecondaryPercentEncodedLists(secondary: secondary, lists: slRaw))

        let primaryByAddress = indexAdlistsByNormalizedAddress(pl)
        let secondaryByAddress = indexAdlistsByNormalizedAddress(sl)

        let primaryKeys = Set(primaryByAddress.keys)
        let secondaryKeys = Set(secondaryByAddress.keys)

        let toDelete = Array(secondaryKeys.subtracting(primaryKeys)).sorted()
        let toUpsert = Array(primaryKeys).sorted()

        SyncProgress.report("Sync: \(dryRun ? "[dry run] " : "")\(toUpsert.count) primary adlists; \(toDelete.count) secondary extras to remove.")

        var deleted = 0
        var disabled = 0
        for address in toDelete {
            guard let list = secondaryByAddress[address] else { continue }
            if !dryRun {
                if let id = list.id {
                    do {
                        _ = try await secondary.deleteData(
                            "/lists/\(id)",
                            apiKey: secondary.connection.token,
                            queryItems: [
                                URLQueryItem(name: "type", value: "block"),
                                URLQueryItem(name: "app_sudo", value: "true"),
                            ]
                        )
                        deleted += 1
                        continue
                    } catch let apiError as APIError {
                        if case .invalidResponse(statusCode: 404, content: _) = apiError {
                            // fall through to disable
                        } else {
                            throw apiError
                        }
                    }
                }
                try await disableAdlist(secondary: secondary, list: list)
                disabled += 1
            } else {
                deleted += 1
            }
        }

        var created = 0
        var updated = 0
        for address in toUpsert {
            guard let desired = primaryByAddress[address] else { continue }
            let existing = secondaryByAddress[address]
            let translatedGroups = translateGroupIds(desired.groups, primaryIdToName: primaryIdToName, secondaryNameToId: secondaryNameToId)

            if !dryRun {
                let writeAddress = syncAdlistSanitizeWriteAddress(desired.addressNormalized)
                if let existingId = existing?.id {
                    _ = try await secondary.putData(
                        "/lists/\(existingId)",
                        apiKey: secondary.connection.token,
                        queryItems: [
                            URLQueryItem(name: "type", value: "block"),
                            URLQueryItem(name: "app_sudo", value: "true"),
                        ],
                        body: AdlistUpdateRequest(
                            type: "block", address: writeAddress,
                            enabled: desired.enabled, comment: desired.comment, groups: translatedGroups
                        )
                    )
                } else {
                    _ = try await secondary.postData(
                        "/lists",
                        apiKey: secondary.connection.token,
                        queryItems: [
                            URLQueryItem(name: "type", value: "block"),
                            URLQueryItem(name: "app_sudo", value: "true"),
                        ],
                        body: AdlistCreateRequest(
                            address: writeAddress, type: "block",
                            enabled: desired.enabled, comment: desired.comment, groups: translatedGroups
                        )
                    )
                }
            }

            if existing != nil { updated += 1 } else { created += 1 }

            let processed = created + updated
            if processed % 25 == 0 {
                SyncProgress.report("Sync: adlists processed \(processed)/\(toUpsert.count)…")
            }
        }

        let tag = dryRun ? "[Dry run] " : ""
        if disabled > 0 {
            return "\(tag)Adlists: +\(created) ~\(updated) -\(deleted) (disabled \(disabled) extras)"
        }
        return "\(tag)Adlists: +\(created) ~\(updated) -\(deleted)"
    }

    private func fetchAdlists(api: Pihole6API) async throws -> [Adlist] {
        let data = try await api.getData(
            "/lists",
            apiKey: api.connection.token,
            queryItems: [URLQueryItem(name: "type", value: "block")]
        )
        let object = try JSONSerialization.jsonObject(with: data)

        let array: [Any]
        if let dict = object as? [String: Any], let raw = dict["lists"] as? [Any] {
            array = raw
        } else if let raw = object as? [Any] {
            array = raw
        } else {
            return []
        }

        return array.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            if let type = d["type"] as? String, type != "block" { return nil }
            let id = d["id"] as? Int
            guard let addressStored = d["address"] as? String, !addressStored.isEmpty else { return nil }
            let addressNormalized = addressStored.removingPercentEncoding ?? addressStored
            let enabled = d["enabled"] as? Bool
            let comment = d["comment"] as? String
            let groups = d["groups"] as? [Int] ?? []
            return Adlist(
                id: id, addressStored: addressStored, addressNormalized: addressNormalized,
                enabled: enabled, comment: comment, groups: groups
            )
        }
    }

    private func indexAdlistsByNormalizedAddress(_ lists: [Adlist]) -> [String: Adlist] {
        var result: [String: Adlist] = [:]
        for list in lists {
            let key = list.addressNormalized
            if let existing = result[key] {
                result[key] = preferredAdlist(existing: existing, candidate: list)
            } else {
                result[key] = list
            }
        }
        return result
    }

    private func preferredAdlist(existing: Adlist, candidate: Adlist) -> Adlist {
        let existingEncoded = syncAdlistLooksPercentEncoded(existing.addressStored)
        let candidateEncoded = syncAdlistLooksPercentEncoded(candidate.addressStored)
        if existingEncoded != candidateEncoded {
            return existingEncoded ? candidate : existing
        }
        return (existing.enabled ?? true) ? existing : candidate
    }

    private func sanitizeSecondaryPercentEncodedLists(secondary: Pihole6API, lists: [Adlist]) async throws -> [Adlist] {
        let bad = lists.filter {
            guard syncAdlistLooksPercentEncoded($0.addressStored) else { return false }
            return ($0.addressStored.removingPercentEncoding ?? $0.addressStored) != $0.addressStored
        }
        guard !bad.isEmpty else { return lists }

        SyncProgress.report("Sync: fixing \(bad.count) percent-encoded adlist URLs on secondary…")
        var fixedIdToDecoded: [Int: String] = [:]

        for list in bad {
            guard let id = list.id else { continue }
            let decoded = list.addressStored.removingPercentEncoding ?? list.addressStored
            let fixed = syncAdlistSanitizeWriteAddress(decoded)

            do {
                _ = try await secondary.putData(
                    "/lists/\(id)",
                    apiKey: secondary.connection.token,
                    queryItems: [
                        URLQueryItem(name: "type", value: "block"),
                        URLQueryItem(name: "app_sudo", value: "true"),
                    ],
                    body: AdlistUpdateRequest(
                        type: "block", address: fixed, enabled: false,
                        comment: "Fixed by PiBar sync (was percent-encoded)", groups: nil
                    )
                )
                fixedIdToDecoded[id] = fixed
                continue
            } catch {}

            do {
                _ = try await secondary.deleteData(
                    "/lists/\(id)",
                    apiKey: secondary.connection.token,
                    queryItems: [
                        URLQueryItem(name: "type", value: "block"),
                        URLQueryItem(name: "app_sudo", value: "true"),
                    ]
                )
            } catch let deleteError as APIError {
                if case .invalidResponse(statusCode: 404, content: _) = deleteError { /* already gone */ } else {
                    _ = try? await secondary.putData(
                        "/lists/\(id)",
                        apiKey: secondary.connection.token,
                        queryItems: [
                            URLQueryItem(name: "type", value: "block"),
                            URLQueryItem(name: "app_sudo", value: "true"),
                        ],
                        body: AdlistUpdateRequest(
                            type: "block", address: nil, enabled: false,
                            comment: "Disabled by PiBar sync (invalid encoded URL)", groups: nil
                        )
                    )
                }
            }
        }

        return lists.compactMap { list in
            if let id = list.id, let decoded = fixedIdToDecoded[id] {
                return Adlist(id: id, addressStored: decoded, addressNormalized: decoded, enabled: false, comment: list.comment, groups: list.groups)
            }
            let decoded = list.addressStored.removingPercentEncoding ?? list.addressStored
            if decoded != list.addressStored, syncAdlistLooksPercentEncoded(list.addressStored) { return nil }
            return list
        }
    }

    private func wipeSecondaryAdlists(secondary: Pihole6API) async throws {
        SyncProgress.report("Sync: wiping secondary adlists (pre-clean)…")
        let lists = try await fetchAdlists(api: secondary)
        guard !lists.isEmpty else {
            SyncProgress.report("Sync: no adlists to wipe.")
            return
        }
        var wiped = 0
        for list in lists {
            guard let id = list.id else { continue }
            do {
                _ = try await secondary.deleteData(
                    "/lists/\(id)",
                    apiKey: secondary.connection.token,
                    queryItems: [
                        URLQueryItem(name: "type", value: "block"),
                        URLQueryItem(name: "app_sudo", value: "true"),
                    ]
                )
                wiped += 1
            } catch let apiError as APIError {
                switch apiError {
                case .invalidResponse(statusCode: 404, content: _): break
                default:
                    _ = try? await secondary.putData(
                        "/lists/\(id)",
                        apiKey: secondary.connection.token,
                        queryItems: [
                            URLQueryItem(name: "type", value: "block"),
                            URLQueryItem(name: "app_sudo", value: "true"),
                        ],
                        body: AdlistUpdateRequest(type: "block", address: nil, enabled: false, comment: "Disabled by PiBar pre-clean", groups: nil)
                    )
                }
            }
            if wiped % 50 == 0 {
                SyncProgress.report("Sync: pre-clean wiped \(wiped)/\(lists.count) adlists…")
            }
        }
        SyncProgress.report("Sync: pre-clean complete (\(wiped) adlists wiped).")
    }

    private func disableAdlist(secondary: Pihole6API, list: Adlist) async throws {
        guard let id = list.id else { return }
        _ = try await secondary.putData(
            "/lists/\(id)",
            apiKey: secondary.connection.token,
            queryItems: [
                URLQueryItem(name: "type", value: "block"),
                URLQueryItem(name: "app_sudo", value: "true"),
            ],
            body: AdlistUpdateRequest(type: "block", address: nil, enabled: false, comment: "Disabled by PiBar sync", groups: nil)
        )
    }

    // MARK: - Domain Sync (Phase 4)

    private func syncDomainBucket(
        bucket: DomainBucket,
        primary: Pihole6API,
        secondary: Pihole6API,
        primaryIdToName: [Int: String],
        secondaryNameToId: [String: Int],
        dryRun: Bool
    ) async throws -> (created: Int, updated: Int, deleted: Int) {

        SyncProgress.report("Sync: \(dryRun ? "[dry run] " : "")syncing \(bucket.label)…")

        async let pd = fetchDomains(api: primary, bucket: bucket)
        async let sd = fetchDomains(api: secondary, bucket: bucket)
        let (primaryDomains, secondaryDomains) = try await (pd, sd)

        let primaryByDomain = Dictionary(primaryDomains.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })
        let secondaryByDomain = Dictionary(secondaryDomains.map { ($0.domain, $0) }, uniquingKeysWith: { a, _ in a })

        let toDelete = Array(Set(secondaryByDomain.keys).subtracting(primaryByDomain.keys))
        let toUpsert = Array(primaryByDomain.keys)

        var deleted = 0
        for domainStr in toDelete {
            guard let existing = secondaryByDomain[domainStr] else { continue }
            if !dryRun {
                try await deleteDomain(api: secondary, domain: existing, bucket: bucket)
            }
            deleted += 1
        }

        var created = 0
        var updated = 0
        for domainStr in toUpsert {
            guard let desired = primaryByDomain[domainStr] else { continue }
            let existing = secondaryByDomain[domainStr]
            let translatedGroups = translateGroupIds(
                desired.groups, primaryIdToName: primaryIdToName, secondaryNameToId: secondaryNameToId
            )

            if !dryRun {
                if let existingId = existing?.id {
                    _ = try await secondary.putData(
                        "/domains/\(existingId)",
                        apiKey: secondary.connection.token,
                        queryItems: [URLQueryItem(name: "app_sudo", value: "true")],
                        body: DomainUpdateRequest(enabled: desired.enabled, comment: desired.comment, groups: translatedGroups)
                    )
                } else {
                    _ = try await secondary.postData(
                        bucket.path,
                        apiKey: secondary.connection.token,
                        queryItems: [URLQueryItem(name: "app_sudo", value: "true")],
                        body: DomainCreateRequest(
                            domain: domainStr, enabled: desired.enabled,
                            comment: desired.comment, groups: translatedGroups
                        )
                    )
                }
            }

            if existing != nil { updated += 1 } else { created += 1 }
        }

        return (created, updated, deleted)
    }

    private func fetchDomains(api: Pihole6API, bucket: DomainBucket) async throws -> [Domain] {
        let data = try await api.getData(bucket.path, apiKey: api.connection.token)
        let object = try JSONSerialization.jsonObject(with: data)

        let array: [Any]
        if let dict = object as? [String: Any], let raw = dict["domains"] as? [Any] {
            array = raw
        } else if let raw = object as? [Any] {
            array = raw
        } else {
            return []
        }

        return array.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            guard let domain = d["domain"] as? String, !domain.isEmpty else { return nil }
            let id = d["id"] as? Int
            let enabled = d["enabled"] as? Bool
            let comment = d["comment"] as? String
            let groups = d["groups"] as? [Int] ?? []
            return Domain(id: id, domain: domain, enabled: enabled, comment: comment, groups: groups)
        }
    }

    private func deleteDomain(api: Pihole6API, domain: Domain, bucket: DomainBucket) async throws {
        if let id = domain.id {
            do {
                _ = try await api.deleteData(
                    "/domains/\(id)",
                    apiKey: api.connection.token,
                    queryItems: [URLQueryItem(name: "app_sudo", value: "true")]
                )
                return
            } catch let apiError as APIError {
                if case .invalidResponse(statusCode: 404, content: _) = apiError { return }
                // For other errors, fall through to path-based delete.
            }
        }

        let encoded = Pihole6API.encodePathComponent(domain.domain)
        _ = try await api.deleteData(
            "\(bucket.path)/\(encoded)",
            apiKey: api.connection.token,
            queryItems: [URLQueryItem(name: "app_sudo", value: "true")]
        )
    }

}
