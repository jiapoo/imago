import Foundation
import Network
import os

public enum BackupService {
    public static let bonjourType = "_photobackup._tcp"
    /// TXT record key holding `PairingInfo.serverID`, so the phone finds its Mac even if Bonjour renames it.
    public static let serverIDKey = "id"
    /// TXT record key telling the two services apart.
    public static let modeKey = "mode"

    public enum Mode: String, Sendable {
        /// Backups. Each paired phone connects with its own key.
        case backup
        /// Pairing. Only advertised while "Add iPhone" is open on the Mac.
        case pair
    }
    public static let pairingIdentity = "pair"

    public struct PreSharedKey: Sendable {
        public var identity: String
        public var key: Data

        public init(identity: String, key: Data) {
            self.identity = identity
            self.key = key
        }
    }

    /// Client side: TCP + TLS with one pre-shared key.
    public static func parameters(secret: Data, identity: String) -> NWParameters {
        parameters(keys: [PreSharedKey(identity: identity, key: secret)])
    }

    /// Server side: accepts a client presenting any of these identity/key pairs.
    public static func parameters(keys: [PreSharedKey]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        for psk in keys {
            let key = psk.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let id = Data(psk.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, id as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    public static func advertisement(serverID: String, name: String, mode: Mode) -> NWListener.Service {
        var txt = NWTXTRecord()
        txt[serverIDKey] = serverID
        txt[modeKey] = mode.rawValue
        let instance = mode == .pair ? "\(name) (Pairing)" : name
        return NWListener.Service(name: instance, type: bonjourType, txtRecord: txt)
    }

    /// Browses the local network (and nearby peer-to-peer Wi-Fi) for the Mac with this ID.
    public static func findServer(id serverID: String, mode: Mode = .backup, timeout: TimeInterval = 10) async throws -> NWEndpoint {
        let browserParameters = NWParameters.tcp
        browserParameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: bonjourType, domain: nil), using: browserParameters)
        defer { browser.cancel() }
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = { resumed.withLock { done in defer { done = true }; return !done } }

        return try await withCheckedThrowingContinuation { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                let match = results.first { result in
                    if case .bonjour(let txt) = result.metadata {
                        return txt[serverIDKey] == serverID && (txt[modeKey] ?? Mode.backup.rawValue) == mode.rawValue
                    }
                    return false
                }
                if let match, claim() { continuation.resume(returning: match.endpoint) }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state, claim() { continuation.resume(throwing: error) }
            }
            browser.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if claim() { continuation.resume(throwing: BackupServiceError.serverNotFound) }
            }
        }
    }
}

public enum BackupServiceError: LocalizedError {
    case serverNotFound

    public var errorDescription: String? {
        switch self {
        case .serverNotFound: "Couldn't find your Mac. Make sure Photo Backup is running and both devices are on the same Wi-Fi."
        }
    }
}

/// A framed, bidirectional connection. Incoming frames arrive on `frames`; `send` returns once
/// the bytes are handed to the network stack, which paces the sender.
public final class PeerConnection: @unchecked Sendable {
    public let frames: AsyncThrowingStream<Frame, Error>
    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PeerConnection")
    // Touched only on `queue`.
    private var decoder = FrameDecoder()
    private var readyContinuation: CheckedContinuation<Void, Error>?

    public init(connection: NWConnection) {
        self.connection = connection
        (frames, continuation) = AsyncThrowingStream.makeStream()
    }

    public convenience init(endpoint: NWEndpoint, parameters: NWParameters) {
        self.init(connection: NWConnection(to: endpoint, using: parameters))
    }

    /// Starts the connection and returns once the TLS handshake is done.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                readyContinuation = ready
                connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                connection.start(queue: queue)
            }
        }
    }

    public func send(_ frame: Frame) async throws {
        let data = try FrameCodec.encode(frame)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    public func cancel() {
        connection.cancel()
    }

    /// TLS exporter output (RFC 5705) for this session; both ends get the same bytes. Call after `start()`.
    public func keyingMaterial(label: String, length: Int = 32) -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let secret = sec_protocol_metadata_create_secret(tls.securityProtocolMetadata, label.utf8.count, label, length)
        else { return nil }
        return Data(secret as DispatchData)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            readyContinuation?.resume()
            readyContinuation = nil
            receiveNext()
        case .waiting(let error):
            // Usually a wrong pairing secret or no route; fail fast instead of retrying forever.
            finish(error)
            connection.cancel()
        case .failed(let error):
            finish(error)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func finish(_ error: Error?) {
        if let ready = readyContinuation {
            readyContinuation = nil
            ready.resume(throwing: error ?? CancellationError())
        }
        continuation.finish(throwing: error)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                decoder.append(data)
                do {
                    while let frame = try decoder.next() { continuation.yield(frame) }
                } catch {
                    finish(error)
                    connection.cancel()
                    return
                }
            }
            if let error {
                finish(error)
            } else if isComplete {
                finish(nil)
                connection.cancel()
            } else {
                receiveNext()
            }
        }
    }
}
