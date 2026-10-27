import Foundation
import Security
import UIKit

/// Stable per-device identifier bound to this app's vendor group.
/// First call: generates a UUID and persists it in the Keychain
/// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) so it survives
/// app reinstalls as long as the device is not wiped.
/// Subsequent calls return the cached value without a Keychain round-trip.
enum DeviceUID {
    private static let service  = "com.fluxcore.vip_flux.device_uid"
    private static let account  = "device_uid"

    /// Returns the stable device UID, generating and persisting one if needed.
    static var current: String {
        if let cached = _cached { return cached }
        let query: [String: Any] = [
            kSecClass           as String: kSecClassGenericPassword,
            kSecAttrService     as String: service,
            kSecAttrAccount     as String: account,
            kSecReturnData      as String: true,
            kSecMatchLimit      as String: kSecMatchLimitOne
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        if status == errSecSuccess,
           let data = ref as? Data,
           let uid  = String(data: data, encoding: .utf8),
           !uid.isEmpty {
            _cached = uid
            return uid
        }
        let uid = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        persist(uid)
        _cached = uid
        return uid
    }

    private static var _cached: String?

    private static func persist(_ uid: String) {
        guard let data = uid.data(using: .utf8) else { return }
        let attrs: [String: Any] = [
            kSecValueData       as String: data,
            kSecAttrAccessible  as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var item = query
            attrs.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
