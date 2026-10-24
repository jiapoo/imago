import Foundation
import ImagoKit
import Observation

/// While Imago is open, keeps a connection to the Mac so changes made there arrive right away
/// (protocol version 5), and answers the Mac's requests for previews of photos it hasn't backed up
/// yet. iOS closes it when the app leaves the screen; it reconnects when the app comes back.
@MainActor @Observable
final class LiveLink {
    enum State: Equatable {
        case off
        case connecting
        case connected
    }

    private(set) var state: State = .off
    private let client: BackupClient
    private var task: Task<Void, Never>?
    private var peer: PeerConnection?

    init(client: BackupClient) {
        self.client = client
    }

    func start() {
        guard task == nil, client.credential != nil else { return }
        task = Task { await keepConnected() }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let peer { Task { try? await peer.send(.control(.goodbye)); peer.cancel() } }
        peer = nil
        client.sendReportsNow = nil
        state = .off
    }

    /// Reconnects after a drop, waiting longer each time, until stopped.
    private func keepConnected() async {
        var delay = 2
        while !Task.isCancelled, let credential = client.credential {
            do {
                try await session(credential)
                delay = 2
            } catch is CancellationError {
                break
            } catch BackupClient.ClientError.refused(let reason) {
                // The Mac turned the phone away (drive unplugged, older Mac app); try again much later.
                log.notice("Live link refused: \(reason, privacy: .public)")
                delay = 60
            } catch {
                log.info("Live link dropped: \(String(describing: error), privacy: .public)")
            }
            client.sendReportsNow = nil
            peer = nil
            if Task.isCancelled { break }
            state = .connecting
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 60)
        }
        state = .off
    }

    private func session(_ credential: DeviceCredential) async throws {
        state = .connecting
        let (peer, connectedReplies) = try await client.connect(credential)
        var replies = connectedReplies
        defer { peer.cancel() }
        self.peer = peer
        try await peer.send(.control(.live))
        client.sendReportsNow = { reports in
            Task { try? await peer.send(.control(.changeReport(reports))) }
        }
        state = .connected
        log.info("Live link connected")

        while let frame = try await replies.next(isolation: #isolation) {
            switch frame {
            case .control(.changes(let changes)):
                client.receive(changes)
            case .control(.thumbnailRequest(let assetIDs)):
                let thumbnails = await PhotoLibrary.thumbnails(assetIDs)
                // Several frames, each well under the 16 MiB limit.
                for start in stride(from: 0, to: thumbnails.count, by: 20) {
                    try await peer.send(.control(.thumbnails(Array(thumbnails[start..<min(start + 20, thumbnails.count)]))))
                }
            case .control(.unavailable(let reason)):
                throw BackupClient.ClientError.refused(reason)
            default:
                break
            }
        }
    }
}
