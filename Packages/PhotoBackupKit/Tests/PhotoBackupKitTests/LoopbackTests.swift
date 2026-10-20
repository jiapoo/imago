import Foundation
import Network
import Testing
@testable import PhotoBackupKit

/// Real TLS-PSK connection over localhost: frames go both ways, and a wrong secret is refused.
@Suite struct LoopbackTests {
    @Test func framesFlowOverPairedConnection() async throws {
        let pairing = PairingInfo.generate(serverName: "Test")
        let (listener, port) = try await startEchoListener(secret: pairing.secret)
        defer { listener.cancel() }

        let client = PeerConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: BackupService.parameters(secret: pairing.secret, identity: "phone")
        )
        try await client.start()
        defer { client.cancel() }

        let payload = Data((0..<(FrameCodec.chunkSize)).map { UInt8($0 % 256) })
        let key = ResourceKey(assetID: "A", kind: .photo, revision: "original")
        try await client.send(.control(.hello(deviceID: "d", deviceName: "n", protocolVersion: 4, proof: nil)))
        try await client.send(.chunk(key: key, offset: 7, data: payload))

        var replies = client.frames.makeAsyncIterator()
        #expect(try await replies.next() == .control(.hello(deviceID: "d", deviceName: "n", protocolVersion: 4, proof: nil)))
        #expect(try await replies.next() == .chunk(key: key, offset: 7, data: payload))
    }

    @Test func wrongSecretIsRefused() async throws {
        let (listener, port) = try await startEchoListener(secret: PairingInfo.generate(serverName: "A").secret)
        defer { listener.cancel() }

        let client = PeerConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: BackupService.parameters(secret: PairingInfo.generate(serverName: "B").secret, identity: "phone")
        )
        defer { client.cancel() }
        await #expect(throws: (any Error).self) { try await client.start() }
    }

    @Test func eachPhoneConnectsWithItsOwnKey() async throws {
        let keyA = Secret.random(), keyB = Secret.random()
        let (listener, port) = try await startEchoListener(keys: [
            .init(identity: "phone-a", key: keyA), .init(identity: "phone-b", key: keyB),
        ])
        defer { listener.cancel() }

        for (identity, key) in [("phone-a", keyA), ("phone-b", keyB)] {
            let client = PeerConnection(
                endpoint: .hostPort(host: "127.0.0.1", port: port),
                parameters: BackupService.parameters(secret: key, identity: identity)
            )
            try await client.start()
            try await client.send(.control(.goodbye))
            var replies = client.frames.makeAsyncIterator()
            #expect(try await replies.next() == .control(.goodbye))
            client.cancel()
        }

        // A removed phone (key no longer registered) is refused, even with a known identity.
        let stranger = PeerConnection(
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            parameters: BackupService.parameters(secret: Secret.random(), identity: "phone-a")
        )
        defer { stranger.cancel() }
        await #expect(throws: (any Error).self) { try await stranger.start() }
    }

    /// Like the Mac: a hello is welcomed only with a proof made from the claimed phone's own key.
    @Test func phoneCanOnlyClaimItsOwnDeviceID() async throws {
        let keys: [String: Data] = ["phone-a": Secret.random(), "phone-b": Secret.random()]
        let (listener, port) = try await startListener(keys: keys.map { .init(identity: $0.key, key: $0.value) }) { peer in
            guard case .control(.hello(let deviceID, _, _, let proof?))? = try await peer.frames.first(where: { _ in true }),
                  let key = keys[deviceID], let binding = peer.keyingMaterial(label: HelloProof.exporterLabel)
            else { return }
            let ok = HelloProof.isValid(proof, key: key, deviceID: deviceID, binding: binding)
            try await peer.send(.control(ok ? .welcome(serverName: "Mac") : .unavailable(reason: "no")))
        }
        defer { listener.cancel() }

        // phone-a connects with its own key, then claims to be each phone in turn.
        for (claimed, expectWelcome) in [("phone-a", true), ("phone-b", false)] {
            let client = PeerConnection(
                endpoint: .hostPort(host: "127.0.0.1", port: port),
                parameters: BackupService.parameters(secret: keys["phone-a"]!, identity: "phone-a")
            )
            try await client.start()
            let binding = try #require(client.keyingMaterial(label: HelloProof.exporterLabel))
            #expect(binding.count == 32)
            try await client.send(.control(.hello(
                deviceID: claimed, deviceName: "n", protocolVersion: ProtocolVersion.current,
                proof: HelloProof.make(key: keys["phone-a"]!, deviceID: claimed, binding: binding)
            )))
            var replies = client.frames.makeAsyncIterator()
            let reply = try await replies.next()
            #expect(reply == (expectWelcome ? .control(.welcome(serverName: "Mac")) : .control(.unavailable(reason: "no"))))
            client.cancel()
        }
    }

    private func startEchoListener(secret: Data) async throws -> (NWListener, NWEndpoint.Port) {
        try await startEchoListener(keys: [.init(identity: "phone", key: secret)])
    }

    /// A listener that sends every frame straight back.
    private func startEchoListener(keys: [BackupService.PreSharedKey]) async throws -> (NWListener, NWEndpoint.Port) {
        try await startListener(keys: keys) { peer in
            for try await frame in peer.frames { try await peer.send(frame) }
        }
    }

    private func startListener(
        keys: [BackupService.PreSharedKey], handle: @escaping @Sendable (PeerConnection) async throws -> Void
    ) async throws -> (NWListener, NWEndpoint.Port) {
        let listener = try NWListener(using: BackupService.parameters(keys: keys), on: .any)
        listener.newConnectionHandler = { connection in
            let peer = PeerConnection(connection: connection)
            Task {
                try await peer.start()
                try await handle(peer)
            }
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return (listener, port)
    }
}
