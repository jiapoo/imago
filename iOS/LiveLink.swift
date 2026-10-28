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
        client.requestRestoreNow = nil
        client.restoresInterrupted()
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
            client.requestRestoreNow = nil
            client.restoresInterrupted()
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
        client.requestRestoreNow = { change in
            Task { try? await peer.send(.control(.restoreRequest(change.id))) }
        }
        let restore = RestoreReceiver()
        defer { restore.discard() }
        state = .connected
        log.info("Live link connected")
        client.resumeWaitingRestores()

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
            case .control(.restoreAsset(let asset)):
                restore.begin(asset)
            case .chunk(let key, let offset, let data):
                restore.write(data, to: key, at: offset)
            case .control(.restoreEnd(let changeID, let missing)):
                await client.finishRestore(await restore.finish(changeID, missing: missing))
            case .control(.unavailable(let reason)):
                throw BackupClient.ClientError.refused(reason)
            default:
                break
            }
        }
    }
}

/// Takes in the files of a put-back from the Mac (version 7): each asset's details, then its files in
/// chunks, into temporary files. At the end each asset whose files arrived whole is added back to
/// Photos, and the report says its new identifier.
@MainActor
private final class RestoreReceiver {
    private struct Incoming {
        var asset: RestoreAsset
        var urls: [ResourceKey: URL]
    }

    private var incoming: [Incoming] = []
    private var handles: [ResourceKey: FileHandle] = [:]
    private let directory = FileManager.default.temporaryDirectory.appending(path: "restore-" + UUID().uuidString)

    func begin(_ asset: RestoreAsset) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [ResourceKey: URL] = [:]
        for file in asset.files {
            let url = directory.appending(path: UUID().uuidString + "-" + file.originalFilename)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            urls[file.key] = url
            handles[file.key] = try? FileHandle(forWritingTo: url)
        }
        incoming.append(Incoming(asset: asset, urls: urls))
    }

    func write(_ data: Data, to key: ResourceKey, at offset: UInt64) {
        guard let handle = handles[key] else { return }
        try? handle.seek(toOffset: offset)
        try? handle.write(contentsOf: data)
    }

    /// Adds what arrived to Photos and says how it went.
    func finish(_ changeID: UUID, missing: [String]) async -> ChangeReport {
        for handle in handles.values { try? handle.close() }
        handles = [:]
        var restored: [String: String] = [:]
        var failed = missing.count
        for item in incoming {
            let files = item.asset.files.compactMap { file in item.urls[file.key].map { (file, $0) } }
            let whole = await Task.detached {
                files.allSatisfy { file, url in (try? FileHasher.sha256(of: url)) == file.sha256 }
            }.value
            guard whole, let identifier = try? await PhotoLibrary.restore(item.asset, files: files) else {
                failed += 1
                continue
            }
            restored[item.asset.metadata.assetID] = identifier
        }
        incoming = []
        discard()
        let detail = failed > 0 ? "\(failed) \(failed == 1 ? "item couldn't" : "items couldn't") be put back." : nil
        return ChangeReport(changeID: changeID, outcome: restored.isEmpty ? .failed : .applied, assetCount: restored.count,
                            detail: detail, restored: restored)
    }

    /// Removes the temporary files of anything not put back.
    func discard() {
        for handle in handles.values { try? handle.close() }
        handles = [:]
        try? FileManager.default.removeItem(at: directory)
    }
}

