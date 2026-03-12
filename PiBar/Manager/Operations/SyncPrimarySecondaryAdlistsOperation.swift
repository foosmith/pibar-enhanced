//
//  SyncPrimarySecondaryAdlistsOperation.swift
//  PiBar
//
//  Created by Codex on 3/12/26.
//

import Foundation

final class SyncPrimarySecondaryAdlistsOperation: AsyncOperation, @unchecked Sendable {
    override func main() {
        Task { [weak self] in
            guard let self else { return }
            defer { self.state = .isFinished }

            SyncProgress.report("Adlists sync: starting…")

            guard Preferences.standard.syncEnabled else {
                Preferences.standard.set(syncLastStatus: "skipped")
                Preferences.standard.set(syncLastMessage: "Sync disabled.")
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: skipped (disabled).")
                return
            }

            let primaryId = Preferences.standard.syncPrimaryIdentifier
            let secondaryId = Preferences.standard.syncSecondaryIdentifier
            guard !primaryId.isEmpty, !secondaryId.isEmpty, primaryId != secondaryId else {
                Preferences.standard.set(syncLastStatus: "skipped")
                Preferences.standard.set(syncLastMessage: "Select distinct Primary and Secondary.")
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: skipped (select distinct Primary/Secondary).")
                return
            }

            let connections = Preferences.standard.piholes.filter(\.isV6)
            guard
                let primaryConnection = connections.first(where: { $0.identifier == primaryId }),
                let secondaryConnection = connections.first(where: { $0.identifier == secondaryId })
            else {
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: "Primary/Secondary connections not found.")
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: failed (connections not found).")
                return
            }

            if primaryConnection.passwordProtected, primaryConnection.token.isEmpty {
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: "Primary requires authentication (missing session).")
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: failed (primary missing session).")
                return
            }
            if secondaryConnection.passwordProtected, secondaryConnection.token.isEmpty {
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: "Secondary requires authentication (missing session).")
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: failed (secondary missing session).")
                return
            }

            let primaryAPI = Pihole6API(connection: primaryConnection)
            let secondaryAPI = Pihole6API(connection: secondaryConnection)

            do {
                if Preferences.standard.syncWipeSecondaryBeforeSync {
                    try await wipeSecondaryAdlists(secondary: secondaryAPI)
                }
                let result = try await syncAdlists(primary: primaryAPI, secondary: secondaryAPI)
                Preferences.standard.set(syncLastStatus: "success")
                Preferences.standard.set(syncLastMessage: result)
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: \(result)")
            } catch let apiError as APIError {
                let message: String
                switch apiError {
                case .forbidden:
                    message = "Secondary rejected writes (403). Enable Pi-hole v6 app_sudo (webserver.api.app_sudo=true)."
                case .unauthorized:
                    message = "Unauthorized (401). Re-authenticate Primary/Secondary in Preferences."
                case let .invalidResponse(statusCode: statusCode, content: content):
                    message = "Sync failed (\(statusCode)). \(content)"
                default:
                    message = "Sync failed: \(apiError)"
                }
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: message)
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: \(message)")
            } catch {
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: "Sync failed: \(error.localizedDescription)")
                Preferences.standard.set(syncLastRunAt: Date())
                SyncProgress.report("Adlists sync: failed (\(error.localizedDescription))")
            }
        }
    }

    private struct Adlist: Hashable {
        let id: Int?
        let addressStored: String
        let addressNormalized: String
        let enabled: Bool?
        let comment: String?
        let groups: [Int]
    }

    private struct AdlistWriteRequest: Encodable {
        let type: String?
        let address: String?
        let enabled: Bool?
        let comment: String?
        let groups: [Int]?
    }

    private struct AdlistCreateRequest: Encodable {
        let address: String
        let type: String
        let enabled: Bool?
        let comment: String?
        let groups: [Int]?
    }

    private func syncAdlists(primary: Pihole6API, secondary: Pihole6API) async throws -> String {
        SyncProgress.report("Adlists sync: fetching lists…")
        async let primaryLists = fetchAdlists(api: primary)
        async let secondaryLists = fetchAdlists(api: secondary)
        let (pl, slRaw) = try await (primaryLists, secondaryLists)

        let sl = try await sanitizeSecondaryPercentEncodedLists(secondary: secondary, lists: slRaw)

        let primaryByAddress = indexByNormalizedAddress(pl)
        let secondaryByAddress = indexByNormalizedAddress(sl)

        let primaryKeys = Set(primaryByAddress.keys)
        let secondaryKeys = Set(secondaryByAddress.keys)

        let toDelete = Array(secondaryKeys.subtracting(primaryKeys)).sorted()
        let toUpsert = Array(primaryKeys).sorted()

        SyncProgress.report("Adlists sync: will reconcile \(toUpsert.count) primary lists; \(toDelete.count) secondary extras.")

        var deleted = 0
        var disabled = 0
        if !toDelete.isEmpty {
            SyncProgress.report("Adlists sync: removing secondary extras…")
        }
        for address in toDelete {
            guard let list = secondaryByAddress[address] else { continue }
            // Primary/Secondary sync policy: remove extras. On this Pi-hole build, delete may not be supported
            // by address, so prefer id-based delete; otherwise disable.
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
                        // Fall through to disable.
                    } else {
                        throw apiError
                    }
                }
            }

            try await disableList(secondary: secondary, list: list, reason: "Disabled by PiBar sync (delete unsupported)")
            disabled += 1
        }

        var created = 0
        var updated = 0
        if !toUpsert.isEmpty {
            SyncProgress.report("Adlists sync: applying primary lists…")
        }
        for address in toUpsert {
            guard let desired = primaryByAddress[address] else { continue }
            let existing = secondaryByAddress[address]
            let isUpdate = existing != nil

            if let existingId = existing?.id {
                _ = try await secondary.putData(
                    "/lists/\(existingId)",
                    apiKey: secondary.connection.token,
                    queryItems: [
                        URLQueryItem(name: "type", value: "block"),
                        URLQueryItem(name: "app_sudo", value: "true"),
                    ],
                    body: AdlistWriteRequest(type: "block", address: desired.addressNormalized, enabled: desired.enabled, comment: desired.comment, groups: desired.groups)
                )
            } else {
                _ = try await secondary.postData(
                    "/lists",
                    apiKey: secondary.connection.token,
                    queryItems: [URLQueryItem(name: "app_sudo", value: "true")],
                    body: AdlistCreateRequest(address: desired.addressNormalized, type: "block", enabled: desired.enabled, comment: desired.comment, groups: desired.groups)
                )
            }

            if isUpdate {
                updated += 1
            } else {
                created += 1
            }

            let processed = created + updated
            if processed % 25 == 0 {
                SyncProgress.report("Adlists sync: processed \(processed)/\(toUpsert.count)…")
            }
        }

        if disabled > 0 {
            var notes: [String] = []
            if disabled > 0 { notes.append("disabled \(disabled) extras") }
            return "Adlists synced: +\(created) ~\(updated) -\(deleted) (\(notes.joined(separator: ", ")))"
        }
        return "Adlists synced: +\(created) ~\(updated) -\(deleted)"
    }

    private func sanitizeSecondaryPercentEncodedLists(secondary: Pihole6API, lists: [Adlist]) async throws -> [Adlist] {
        let bad = lists.filter { list in
            guard looksPercentEncoded(list.addressStored) else { return false }
            let decoded = list.addressStored.removingPercentEncoding ?? list.addressStored
            return decoded != list.addressStored
        }

        if bad.isEmpty {
            return lists
        }

        SyncProgress.report("Adlists sync: fixing \(bad.count) invalid encoded adlist URLs on secondary…")

        var deleted = 0
        var disabled = 0
        for list in bad {
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
                deleted += 1
            } catch let apiError as APIError {
                switch apiError {
                case .invalidResponse(statusCode: 404, content: _):
                    try await disableList(secondary: secondary, list: list, reason: "Disabled by PiBar sync (invalid encoded URL; delete unsupported)")
                    disabled += 1
                default:
                    do {
                        try await disableList(secondary: secondary, list: list, reason: "Disabled by PiBar sync (invalid encoded URL; delete failed)")
                        disabled += 1
                    } catch {
                        throw apiError
                    }
                }
            }
        }

        if disabled > 0 {
            SyncProgress.report("Adlists sync: removed \(deleted) invalid encoded URLs (disabled \(disabled) where delete unsupported).")
        } else {
            SyncProgress.report("Adlists sync: removed \(deleted) invalid encoded URLs.")
        }

        // Exclude them from the local reconcile set so we don't hit duplicate normalized keys.
        return lists.filter { list in
            let decoded = list.addressStored.removingPercentEncoding ?? list.addressStored
            return decoded == list.addressStored || !looksPercentEncoded(list.addressStored)
        }
    }

    private func indexByNormalizedAddress(_ lists: [Adlist]) -> [String: Adlist] {
        var result: [String: Adlist] = [:]
        for list in lists {
            let key = list.addressNormalized
            if let existing = result[key] {
                result[key] = preferredList(existing: existing, candidate: list)
            } else {
                result[key] = list
            }
        }
        return result
    }

    private func preferredList(existing: Adlist, candidate: Adlist) -> Adlist {
        // Prefer the one with a non-encoded stored address; then prefer enabled.
        let existingEncoded = looksPercentEncoded(existing.addressStored)
        let candidateEncoded = looksPercentEncoded(candidate.addressStored)
        if existingEncoded != candidateEncoded {
            return existingEncoded ? candidate : existing
        }
        let existingEnabled = existing.enabled ?? true
        let candidateEnabled = candidate.enabled ?? true
        if existingEnabled != candidateEnabled {
            return candidateEnabled ? candidate : existing
        }
        return existing
    }

    private func fetchAdlists(api: Pihole6API) async throws -> [Adlist] {
        let data = try await api.getData("/lists", apiKey: api.connection.token, queryItems: [URLQueryItem(name: "type", value: "block")])
        let object = try JSONSerialization.jsonObject(with: data)

        let listsArray: [Any]
        if let dict = object as? [String: Any], let raw = dict["lists"] as? [Any] {
            listsArray = raw
        } else if let array = object as? [Any] {
            listsArray = array
        } else {
            return []
        }

        return listsArray.compactMap { item in
            guard let d = item as? [String: Any] else { return nil }
            if let type = d["type"] as? String, type != "block" {
                return nil
            }
            let id = d["id"] as? Int
            guard let addressStored = d["address"] as? String, !addressStored.isEmpty else { return nil }
            let addressNormalized = addressStored.removingPercentEncoding ?? addressStored
            let enabled = d["enabled"] as? Bool
            let comment = d["comment"] as? String
            let groups = d["groups"] as? [Int] ?? []
            return Adlist(id: id, addressStored: addressStored, addressNormalized: addressNormalized, enabled: enabled, comment: comment, groups: groups)
        }
    }

    private func wipeSecondaryAdlists(secondary: Pihole6API) async throws {
        SyncProgress.report("Pre-clean: wiping secondary adlists…")

        let adlists = try await fetchAdlists(api: secondary)
        if adlists.isEmpty {
            SyncProgress.report("Pre-clean: no adlists to wipe.")
            return
        }

        var deleted = 0
        var disabled = 0
        for list in adlists {
            guard let id = list.id else { continue }
            do {
                // Prefer deletion for a clean slate; fall back to disabling when delete isn't supported.
                _ = try await secondary.deleteData(
                    "/lists/\(id)",
                    apiKey: secondary.connection.token,
                    queryItems: [
                        URLQueryItem(name: "type", value: "block"),
                        URLQueryItem(name: "app_sudo", value: "true"),
                    ]
                )
                deleted += 1
            } catch let apiError as APIError {
                switch apiError {
                case .invalidResponse(statusCode: 404, content: _):
                    try await disableList(secondary: secondary, list: list, reason: "Disabled by PiBar sync pre-clean (delete unsupported)")
                    disabled += 1
                default:
                    // Try disabling as a best-effort fallback; if that fails too, bubble up.
                    do {
                        try await disableList(secondary: secondary, list: list, reason: "Disabled by PiBar sync pre-clean (delete failed)")
                        disabled += 1
                    } catch {
                        throw apiError
                    }
                }
            }

            let processed = deleted + disabled
            if processed % 50 == 0 {
                SyncProgress.report("Pre-clean: processed \(processed)/\(adlists.count) adlists…")
            }
        }

        if disabled > 0 {
            SyncProgress.report("Pre-clean: wiped \(deleted) adlists (disabled \(disabled) where delete unsupported).")
        } else {
            SyncProgress.report("Pre-clean: wiped \(deleted) adlists.")
        }
    }

    private func disableList(secondary: Pihole6API, list: Adlist, reason: String) async throws {
        guard let id = list.id else { return }
        _ = try await secondary.putData(
            "/lists/\(id)",
            apiKey: secondary.connection.token,
            queryItems: [
                URLQueryItem(name: "type", value: "block"),
                URLQueryItem(name: "app_sudo", value: "true"),
            ],
            body: AdlistWriteRequest(type: "block", address: nil, enabled: false, comment: reason, groups: nil)
        )
    }

    private func looksPercentEncoded(_ address: String) -> Bool {
        address.contains("%2F") || address.contains("%3A")
    }
}
