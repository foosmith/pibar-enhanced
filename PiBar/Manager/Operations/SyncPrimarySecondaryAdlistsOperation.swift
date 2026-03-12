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

            guard Preferences.standard.syncEnabled else {
                Preferences.standard.set(syncLastStatus: "skipped")
                Preferences.standard.set(syncLastMessage: "Sync disabled.")
                Preferences.standard.set(syncLastRunAt: Date())
                return
            }

            let primaryId = Preferences.standard.syncPrimaryIdentifier
            let secondaryId = Preferences.standard.syncSecondaryIdentifier
            guard !primaryId.isEmpty, !secondaryId.isEmpty, primaryId != secondaryId else {
                Preferences.standard.set(syncLastStatus: "skipped")
                Preferences.standard.set(syncLastMessage: "Select distinct Primary and Secondary.")
                Preferences.standard.set(syncLastRunAt: Date())
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
                return
            }

            if primaryConnection.passwordProtected, primaryConnection.token.isEmpty {
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: "Primary requires authentication (missing session).")
                Preferences.standard.set(syncLastRunAt: Date())
                return
            }
            if secondaryConnection.passwordProtected, secondaryConnection.token.isEmpty {
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: "Secondary requires authentication (missing session).")
                Preferences.standard.set(syncLastRunAt: Date())
                return
            }

            let primaryAPI = Pihole6API(connection: primaryConnection)
            let secondaryAPI = Pihole6API(connection: secondaryConnection)

            do {
                let result = try await syncAdlists(primary: primaryAPI, secondary: secondaryAPI)
                Preferences.standard.set(syncLastStatus: "success")
                Preferences.standard.set(syncLastMessage: result)
                Preferences.standard.set(syncLastRunAt: Date())
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
            } catch {
                Preferences.standard.set(syncLastStatus: "failed")
                Preferences.standard.set(syncLastMessage: "Sync failed: \(error.localizedDescription)")
                Preferences.standard.set(syncLastRunAt: Date())
            }
        }
    }

    private struct Adlist: Hashable {
        let id: Int?
        let address: String
        let enabled: Bool?
        let comment: String?
        let groups: [Int]
    }

    private struct AdlistWriteRequest: Encodable {
        let type: String?
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

    private struct BatchDeleteRequest: Encodable {
        let type: String
        let items: [EncodableItem]
    }

    private struct EncodableItem: Encodable {
        let id: Int?
        let address: String?
        let item: String?

        init(id: Int) {
            self.id = id
            address = nil
            item = nil
        }

        init(address: String) {
            id = nil
            self.address = address
            item = nil
        }

        init(item: String) {
            id = nil
            address = nil
            self.item = item
        }
    }

    private func syncAdlists(primary: Pihole6API, secondary: Pihole6API) async throws -> String {
        async let primaryLists = fetchAdlists(api: primary)
        async let secondaryLists = fetchAdlists(api: secondary)
        let (pl, sl) = try await (primaryLists, secondaryLists)

        let primaryByAddress = Dictionary(uniqueKeysWithValues: pl.map { ($0.address, $0) })
        let secondaryByAddress = Dictionary(uniqueKeysWithValues: sl.map { ($0.address, $0) })

        let primaryKeys = Set(primaryByAddress.keys)
        let secondaryKeys = Set(secondaryByAddress.keys)

        let toDelete = Array(secondaryKeys.subtracting(primaryKeys)).sorted()
        let toUpsert = Array(primaryKeys).sorted()

        var deleted = 0
        for address in toDelete {
            let encoded = Pihole6API.encodePathComponent(address)
            do {
                _ = try await secondary.deleteData(
                    "/lists/\(encoded)",
                    apiKey: secondary.connection.token,
                    queryItems: [
                        URLQueryItem(name: "type", value: "block"),
                        URLQueryItem(name: "app_sudo", value: "true"),
                    ]
                )
                deleted += 1
            } catch let apiError as APIError {
                // Some versions may not support DELETE for lists; try batchDelete.
                if case let .invalidResponse(statusCode: status, content: _) = apiError, status == 404 {
                    try await batchDeleteAdlist(address: address, secondaryByAddress: secondaryByAddress, secondary: secondary)
                    deleted += 1
                    continue
                }
                throw apiError
            }
        }

        var created = 0
        var updated = 0
        for address in toUpsert {
            guard let desired = primaryByAddress[address] else { continue }
            let existing = secondaryByAddress[address]
            let isUpdate = existing != nil

            let encoded = Pihole6API.encodePathComponent(address)
            do {
                _ = try await secondary.putData(
                    "/lists/\(encoded)",
                    apiKey: secondary.connection.token,
                    queryItems: [
                        URLQueryItem(name: "type", value: "block"),
                        URLQueryItem(name: "app_sudo", value: "true"),
                    ],
                    body: AdlistWriteRequest(type: "block", enabled: desired.enabled, comment: desired.comment, groups: desired.groups)
                )
            } catch let apiError as APIError {
                // Some versions may not allow PUT to create. Try POST /lists to create.
                if case let .invalidResponse(statusCode: status, content: _) = apiError, status == 404, !isUpdate {
                    _ = try await secondary.postData(
                        "/lists",
                        apiKey: secondary.connection.token,
                        queryItems: [URLQueryItem(name: "app_sudo", value: "true")],
                        body: AdlistCreateRequest(address: desired.address, type: "block", enabled: desired.enabled, comment: desired.comment, groups: desired.groups)
                    )
                } else {
                    throw apiError
                }
            }

            if isUpdate {
                updated += 1
            } else {
                created += 1
            }
        }

        return "Adlists synced: +\(created) ~\(updated) -\(deleted)"
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
            guard let address = d["address"] as? String, !address.isEmpty else { return nil }
            let enabled = d["enabled"] as? Bool
            let comment = d["comment"] as? String
            let groups = d["groups"] as? [Int] ?? []
            return Adlist(id: id, address: address, enabled: enabled, comment: comment, groups: groups)
        }
    }

    private func batchDeleteAdlist(address: String, secondaryByAddress: [String: Adlist], secondary: Pihole6API) async throws {
        // Prefer deleting by id if available; payload shapes appear to vary across Pi-hole v6 builds.
        var attempts: [(String, BatchDeleteRequest)] = []
        if let id = secondaryByAddress[address]?.id {
            attempts.append(("id", BatchDeleteRequest(type: "block", items: [EncodableItem(id: id)])))
        }
        attempts.append(("address", BatchDeleteRequest(type: "block", items: [EncodableItem(address: address)])))
        attempts.append(("item", BatchDeleteRequest(type: "block", items: [EncodableItem(item: address)])))

        var lastError: APIError?
        for (label, body) in attempts {
            do {
                _ = try await secondary.postData(
                    "/lists:batchDelete",
                    apiKey: secondary.connection.token,
                    queryItems: [URLQueryItem(name: "app_sudo", value: "true")],
                    body: body
                )
                return
            } catch let apiError as APIError {
                lastError = apiError
                if case .invalidResponse(statusCode: 400, content: _) = apiError {
                    Log.debug("Batch delete attempt failed (\(label))")
                    continue
                }
                throw apiError
            } catch {
                throw error
            }
        }

        if let lastError {
            throw lastError
        }
    }
}
