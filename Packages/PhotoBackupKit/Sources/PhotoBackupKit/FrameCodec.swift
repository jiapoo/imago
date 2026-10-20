import Foundation

public enum Frame: Sendable, Equatable {
    case control(ControlMessage)
    /// Raw file bytes; kept out of JSON so photos aren't base64-inflated.
    case chunk(key: ResourceKey, offset: UInt64, data: Data)
    /// A control message from a newer version, by name. Receivers skip it instead of disconnecting.
    case unknown(String)
}

public enum FrameError: Error, Equatable {
    case frameTooLarge(Int)
    case unknownKind(UInt8)
    case malformed
}

/// Wire format: `[u32 length][body]`, all integers big-endian.
///   body = `[u8 kind][payload]`
///   kind 0: payload = JSON `ControlMessage`
///   kind 1: payload = `[u16 keyLength][key JSON][u64 offset][bytes]`
public enum FrameCodec {
    public static let maxFrameSize = 16 << 20
    public static let chunkSize = 512 << 10

    public static func encode(_ frame: Frame) throws -> Data {
        var body = Data()
        switch frame {
        case .control(let message):
            body.append(0)
            body.append(try makeEncoder().encode(message))
        case .unknown:
            throw FrameError.malformed
        case .chunk(let key, let offset, let data):
            let keyData = try makeEncoder().encode(key)
            guard keyData.count <= Int(UInt16.max) else { throw FrameError.malformed }
            body.reserveCapacity(1 + 2 + keyData.count + 8 + data.count)
            body.append(1)
            body.appendBigEndian(UInt16(keyData.count))
            body.append(keyData)
            body.appendBigEndian(offset)
            body.append(data)
        }
        guard body.count <= maxFrameSize else { throw FrameError.frameTooLarge(body.count) }

        var out = Data(capacity: 4 + body.count)
        out.appendBigEndian(UInt32(body.count))
        out.append(body)
        return out
    }

    static func decodeBody(_ body: Data) throws -> Frame {
        guard let kind = body.first else { throw FrameError.malformed }
        switch kind {
        case 0:
            let json = body.dropFirst()
            do {
                return .control(try makeDecoder().decode(ControlMessage.self, from: json))
            } catch {
                if let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any], object.count == 1,
                   let name = object.keys.first, !ControlMessage.names.contains(name) {
                    return .unknown(name)
                }
                throw error
            }
        case 1:
            guard body.count >= 3 else { throw FrameError.malformed }
            let keyEnd = 3 + Int(body.readBigEndian(UInt16.self, at: 1))
            guard body.count >= keyEnd + 8 else { throw FrameError.malformed }
            let key = try makeDecoder().decode(ResourceKey.self, from: body.subdata(in: 3..<keyEnd))
            let offset = body.readBigEndian(UInt64.self, at: keyEnd)
            return .chunk(key: key, offset: offset, data: body.subdata(in: (keyEnd + 8)..<body.count))
        default:
            throw FrameError.unknownKind(kind)
        }
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Accumulates bytes from the stream and hands back whole frames.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> Frame? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.readBigEndian(UInt32.self, at: 0))
        guard length <= FrameCodec.maxFrameSize else { throw FrameError.frameTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }

        let start = buffer.startIndex
        let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
        buffer = buffer.subdata(in: (start + 4 + length)..<buffer.endIndex)
        return try FrameCodec.decodeBody(body)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value = value << 8 | T(self[startIndex + offset + i])
        }
        return value
    }
}
