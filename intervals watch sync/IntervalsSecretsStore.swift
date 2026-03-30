//
//  IntervalsSecretsStore.swift
//  intervals watch sync
//
//  Created by Codex on 24/03/2026.
//

import Foundation
import Security

enum IntervalsSecretsStore {
    enum SecretError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain operation failed with status \(status)."
            }
        }
    }

    private static let service = "com.johnnycorp.intervals-watch-sync"
    private static let apiKeyAccount = "intervals-api-key"

    static func loadAPIKey() -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        case errSecItemNotFound:
            return ""
        default:
            print("IntervalsSecretsStore load failed: \(status)")
            return ""
        }
    }

    static func hasAPIKey() -> Bool {
        !loadAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func saveAPIKey(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            try deleteAPIKey()
            return
        }

        let data = Data(trimmedKey.utf8)
        let status = SecItemCopyMatching(baseQuery() as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw SecretError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var query = baseQuery()
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretError.unexpectedStatus(addStatus)
            }
        default:
            throw SecretError.unexpectedStatus(status)
        }
    }

    static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretError.unexpectedStatus(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount
        ]
    }
}
