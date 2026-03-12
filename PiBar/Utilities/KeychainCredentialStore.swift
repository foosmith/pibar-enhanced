//
//  KeychainCredentialStore.swift
//  PiBar
//
//  Created by Codex on 3/12/26.
//

import Foundation
import Security

enum KeychainCredentialStoreError: Error {
    case unexpectedData
    case unhandledStatus(OSStatus)
}

final class KeychainCredentialStore {
    static let shared = KeychainCredentialStore()

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "net.amiantos.PiBar") {
        self.service = service
    }

    func readString(account: String) throws -> String? {
        var query: [String: Any] = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unhandledStatus(status)
        }
        guard let data = item as? Data else {
            throw KeychainCredentialStoreError.unexpectedData
        }
        return String(data: data, encoding: .utf8)
    }

    func upsertString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainCredentialStoreError.unhandledStatus(updateStatus)
            }
            return
        }
        if status != errSecItemNotFound {
            throw KeychainCredentialStoreError.unhandledStatus(status)
        }

        var insert = query
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialStoreError.unhandledStatus(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        throw KeychainCredentialStoreError.unhandledStatus(status)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}

