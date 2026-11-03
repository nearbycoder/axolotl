import Foundation
import CryptoKit
import CommonCrypto

/// Keys derived from a vault's sync code. The sync code is the only secret: the sync server
/// only ever sees the vault id, an auth token and AES-GCM ciphertext.
public struct VaultKeys: Sendable {
    public let code: String
    public let vaultId: String
    public let authToken: String
    let encKey: SymmetricKey
    let macKey: SymmetricKey
    /// Short public hint advertised over Bonjour so peers only connect to devices in the same vault.
    public let lanHint: String

    public static let codePrefix = "AXO"

    public init?(syncCode: String) {
        let cleaned = syncCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.hasPrefix(Self.codePrefix) else { return nil }
        let body = String(cleaned.dropFirst(Self.codePrefix.count))
        guard let secret = Base32.decode(body), secret.count == 20 else { return nil }
        self.code = Self.format(secret)
        let master = SymmetricKey(data: secret)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("axolotl-v1".utf8), info: Data(info.utf8), outputByteCount: 32)
        }
        encKey = derive("enc")
        macKey = derive("mac")
        let idKey = derive("vault-id")
        vaultId = idKey.withUnsafeBytes { Data($0) }.prefix(16).hex
        authToken = derive("auth").withUnsafeBytes { Data($0) }.hex
        lanHint = derive("lan").withUnsafeBytes { Data($0) }.prefix(6).hex
    }

    public static func generateCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return format(Data(bytes))
    }

    static func format(_ secret: Data) -> String {
        let encoded = Base32.encode(secret)
        var groups: [String] = [codePrefix]
        var chunk = ""
        for c in encoded {
            chunk.append(c)
            if chunk.count == 4 { groups.append(chunk); chunk = "" }
        }
        if !chunk.isEmpty { groups.append(chunk) }
        return groups.joined(separator: "-")
    }

    public func seal(_ data: Data) throws -> Data {
        try AES.GCM.seal(data, using: encKey).combined!
    }

    public func open(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encKey)
    }

    /// Opaque, stable identifier for a record field, used by the server for compaction.
    public func rowKey(_ row: SyncRow) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("\(row.entity)\u{1}\(row.id)\u{1}\(row.field)".utf8), using: macKey)).prefix(16).hex
    }

    public func blobKey(_ hash: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("blob\u{1}\(hash)".utf8), using: macKey)).prefix(16).hex
    }
}

/// Password-based encryption for individually locked notes.
public enum NoteCrypto {
    public static let prefix = "AXENC1:"
    static let checkPlaintext = "axolotl-note-lock-check"
    public static let iterations: UInt32 = 120_000

    public static func isEncrypted(_ body: String) -> Bool { body.hasPrefix(prefix) }

    public static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    public static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        salt.withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
        }
        return SymmetricKey(data: derived)
    }

    public static func makeCheck(key: SymmetricKey) -> String {
        (try? AES.GCM.seal(Data(checkPlaintext.utf8), using: key).combined?.base64EncodedString()) ?? ""
    }

    public static func verify(key: SymmetricKey, check: String) -> Bool {
        guard let data = Data(base64Encoded: check),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return false }
        return String(decoding: plain, as: UTF8.self) == checkPlaintext
    }

    public static func encrypt(_ text: String, key: SymmetricKey) throws -> String {
        let box = try AES.GCM.seal(Data(text.utf8), using: key)
        return prefix + box.combined!.base64EncodedString()
    }

    public static func decrypt(_ body: String, key: SymmetricKey) throws -> String {
        guard isEncrypted(body), let data = Data(base64Encoded: String(body.dropFirst(prefix.count))) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        return String(decoding: plain, as: UTF8.self)
    }
}

enum Base32 {
    // Crockford alphabet: no I, L, O, U.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for byte in data {
            buffer = ((buffer << 8) | Int(byte)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func decode(_ string: String) -> Data? {
        var map: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = i }
        map["O"] = 0; map["I"] = 1; map["L"] = 1
        var out = Data()
        var buffer = 0, bits = 0
        for c in string {
            guard let v = map[c] else { return nil }
            buffer = ((buffer << 5) | v) & 0xFFFF
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var sha256: String { Data(SHA256.hash(data: self)).hex }
}
