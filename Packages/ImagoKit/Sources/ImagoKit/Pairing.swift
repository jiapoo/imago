import CryptoKit
import Foundation
import Security

/// What the Mac shows as a QR code while "Add iPhone" is open. The secret only opens the
/// pairing service; it is regenerated every time, so an old photo of the code is useless.
public struct PairingInfo: Codable, Sendable, Equatable {
    public static let urlScheme = "photobackup"

    public var serverID: String
    public var serverName: String
    public var secret: Data

    public init(serverID: String, serverName: String, secret: Data) {
        self.serverID = serverID
        self.serverName = serverName
        self.secret = secret
    }

    public static func generate(serverName: String) -> PairingInfo {
        PairingInfo(serverID: UUID().uuidString, serverName: serverName, secret: Secret.random())
    }

    /// `photobackup://pair?d=<base64url JSON>`
    public var qrString: String {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return "\(Self.urlScheme)://pair?d=\(json.base64URLEncodedString())"
    }

    public init?(qrString: String) {
        guard let components = URLComponents(string: qrString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == Self.urlScheme, components.host == "pair",
              let payload = components.queryItems?.first(where: { $0.name == "d" })?.value,
              let json = Data(base64URLEncoded: payload),
              let info = try? JSONDecoder().decode(PairingInfo.self, from: json),
              info.secret.count == 32
        else { return nil }
        self = info
    }
}

/// What a phone keeps after pairing: its own key for this Mac. Removing the phone on the Mac
/// deletes the key there, so the phone can no longer connect.
public struct DeviceCredential: Codable, Sendable, Equatable {
    public var serverID: String
    public var serverName: String
    public var deviceID: String
    public var key: Data

    public init(serverID: String, serverName: String, deviceID: String, key: Data) {
        self.serverID = serverID
        self.serverName = serverName
        self.deviceID = deviceID
        self.key = key
    }
}

/// Proves in `hello` that the phone holds the key for the device ID it claims. TLS only shows the
/// phone holds one of the Mac's keys, not which one, so without this a paired phone could claim
/// another phone's ID. Bound to the TLS session, so a proof can't be replayed on another connection.
public enum HelloProof {
    /// TLS exporter label (RFC 5705) for the session binding; see `PeerConnection.keyingMaterial`.
    public static let exporterLabel = "EXPORTER-photobackup-hello"

    /// HMAC-SHA256(key, "photobackup-hello" 0x00 deviceID 0x00 binding)
    public static func make(key: Data, deviceID: String, binding: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(deviceID: deviceID, binding: binding), using: SymmetricKey(data: key)))
    }

    public static func isValid(_ proof: Data, key: Data, deviceID: String, binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message(deviceID: deviceID, binding: binding), using: SymmetricKey(data: key))
    }

    private static func message(deviceID: String, binding: Data) -> Data {
        Data("photobackup-hello".utf8) + [0] + Data(deviceID.utf8) + [0] + binding
    }
}

public enum Secret {
    public static func random() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// Minimal generic-password Keychain wrapper for the pairing secret.
public enum Keychain {
    public static func save(_ data: Data, account: String, service: String = "PhotoBackup") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func load(account: String, service: String = "PhotoBackup") -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public static func delete(account: String, service: String = "PhotoBackup") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainError: Error {
    public var status: OSStatus
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
