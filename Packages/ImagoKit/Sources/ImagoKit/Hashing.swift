import CryptoKit
import Foundation

public enum FileHasher {
    /// SHA-256 of a file as lowercase hex, read in 1 MB pieces so videos don't load into memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).hexString
    }
}

extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
