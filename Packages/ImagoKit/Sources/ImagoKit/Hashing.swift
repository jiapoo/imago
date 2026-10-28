import CryptoKit
import Foundation

public enum FileHasher {
    /// SHA-256 of a file as lowercase hex, read in 1 MB pieces so videos don't load into memory.
    /// `progress` gets the bytes read so far, every 16 MB or so, for a progress bar on a big video.
    public static func sha256(of url: URL, progress: ((UInt64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var read: UInt64 = 0
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
            read += UInt64(data.count)
            if read % (16 << 20) < (1 << 20) { progress?(read) }
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
