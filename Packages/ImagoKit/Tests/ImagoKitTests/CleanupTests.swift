import Foundation
import Testing
@testable import ImagoKit

private func asset(
    _ id: String, at seconds: TimeInterval? = 0, sha: String? = nil, bytes: UInt64 = 1_000, video: Bool = false,
    favorite: Bool = false, albums: [String] = [], subtypes: [String]? = [], burst: String? = nil,
    filename: String = "IMG_0001.HEIC", backedUp: Bool = true
) -> PhoneAsset {
    PhoneAsset(
        metadata: AssetMetadata(
            assetID: id, originalFilename: filename, creationDate: seconds.map { Date(timeIntervalSince1970: 1_792_506_612 + $0) },
            modificationDate: nil, mediaType: video ? "video" : "photo", pixelWidth: 4032, pixelHeight: 3024,
            duration: video ? 30 : 0, isFavorite: favorite, location: nil, albums: albums, subtypes: subtypes, burstID: burst
        ),
        originalSHA256: sha, bytes: bytes, isBackedUp: backedUp
    )
}

@Suite struct CleanupTests {
    @Test func exactDuplicatesKeepTheFavorite() {
        let groups = Cleanup.exactDuplicates([
            asset("a", sha: "x"), asset("b", at: 5, sha: "x", favorite: true), asset("c", sha: "y"), asset("d", sha: nil),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].keep.id == "b")
        #expect(groups[0].extras.map(\.id) == ["a"])
        #expect(groups[0].reclaimableBytes == 1_000)
    }

    @Test func exactDuplicatesKeepTheLargest() {
        let groups = Cleanup.exactDuplicates([
            asset("a", sha: "x", bytes: 900, favorite: true), asset("b", at: 5, sha: "x", bytes: 2_000), asset("c", at: 9, sha: "x", bytes: 1_500),
        ])
        #expect(groups[0].keep.id == "b")
        #expect(Set(groups[0].extras.map(\.id)) == ["a", "c"])
        #expect(groups[0].reclaimableBytes == 2_400)
    }

    @Test func keeperPrefersScoreThenAlbumsThenOldest() {
        let a = asset("a", at: 0), b = asset("b", at: 10, albums: ["Trip"]), c = asset("c", at: 20)
        #expect(Cleanup.bestToKeep([a, b, c]).id == "b")
        #expect(Cleanup.bestToKeep([a, b, c], scores: ["c": 0.9]).id == "c")
        #expect(Cleanup.bestToKeep([c, a]).id == "a")
    }

    @Test func momentsSplitOnGapsAndSkipVideosScreenshotsBursts() {
        let runs = Cleanup.moments([
            asset("a", at: 0), asset("b", at: 30), asset("c", at: 200), asset("d", at: 230),
            asset("v", at: 10, video: true), asset("s", at: 20, subtypes: ["screenshot"]), asset("u", at: 25, burst: "B"),
            asset("lonely", at: 1_000), asset("undated", at: nil),
        ])
        #expect(runs.map { $0.map(\.id) } == [["a", "b"], ["c", "d"]])
    }

    @Test func clusterJoinsChains() {
        let run = ["a", "b", "c", "d"].enumerated().map { asset($1, at: Double($0)) }
        let position: [String: Float] = ["a": 0, "b": 0.3, "c": 0.6, "d": 5]
        let groups = Cleanup.cluster(run, threshold: 0.45) { abs(position[$0.id]! - position[$1.id]!) }
        #expect(groups.count == 1)
        #expect(Set(groups[0].assets.map(\.id)) == ["a", "b", "c"])
    }

    @Test func burstsGroupByID() {
        let groups = Cleanup.bursts([asset("a", burst: "B"), asset("b", at: 1, burst: "B"), asset("c", burst: "C")])
        #expect(groups.map { Set($0.assets.map(\.id)) } == [["a", "b"]])
    }

    @Test func largeVideosAndScreenshots() {
        let all = [
            asset("small", bytes: 10, video: true), asset("big", bytes: 300_000_000, video: true),
            asset("bigger", bytes: 900_000_000, video: true), asset("shot", subtypes: ["screenshot"]),
            asset("rec", video: true, subtypes: ["screenRecording"]),
            asset("oldShot", subtypes: nil, filename: "IMG_0002.PNG"), asset("png", subtypes: nil, filename: "drawing.png"),
        ]
        #expect(Cleanup.largeVideos(all).map(\.id) == ["bigger", "big"])
        #expect(Set(Cleanup.screenshots(all).map(\.id)) == ["shot", "rec", "oldShot"])
    }

    @Test func byYearPutsUndatedLast() {
        let years = Cleanup.byYear([asset("a"), asset("b", at: -86_400 * 400), asset("c", at: nil)], timeZone: TimeZone(identifier: "UTC")!)
        #expect(years.map(\.year) == [2025, 2026, nil])
    }
}

@Suite struct ProtocolV4Tests {
    @Test func newMessagesRoundTrip() throws {
        let change = LibraryChange(action: .addToAlbum("Trip"), assetIDs: ["a/L0/001"], bytes: 5)
        let frames: [Frame] = [
            .control(.manifestEnd(albums: ["Trip", "Empty"])),
            .control(.changes([change, LibraryChange(action: .delete, assetIDs: ["b"])])),
            .control(.changeReport([ChangeReport(changeID: change.id, outcome: .declined, assetCount: 0)])),
        ]
        var decoder = FrameDecoder()
        for frame in frames { decoder.append(try FrameCodec.encode(frame)) }
        for frame in frames {
            // Dates lose fractions on the wire, so compare after a second round trip.
            let decoded = try decoder.next()
            var again = FrameDecoder()
            again.append(try FrameCodec.encode(decoded!))
            #expect(try again.next() == decoded)
            if case .control(.manifestEnd) = frame { #expect(decoded == frame) }
        }
    }

    @Test func unknownMessagesAreSkippedNotFatal() throws {
        var body = Data([0])
        body.append(Data(#"{"fromTheFuture":{"x":1}}"#.utf8))
        var framed = Data()
        framed.appendBigEndian(UInt32(body.count))
        framed.append(body)
        framed.append(try FrameCodec.encode(.control(.goodbye)))

        var decoder = FrameDecoder()
        decoder.append(framed)
        #expect(try decoder.next() == .unknown("fromTheFuture"))
        #expect(try decoder.next() == .control(.goodbye))
    }

    @Test func aBrokenKnownMessageIsStillAnError() {
        var body = Data([0])
        body.append(Data(#"{"hello":{"deviceID":1}}"#.utf8))
        #expect(throws: (any Error).self) { try FrameCodec.decodeBody(body) }
    }

    @Test func liveMessagesRoundTrip() throws {
        let frames: [Frame] = [
            .control(.live), .control(.thumbnailRequest(["a/L0/001"])),
            .control(.thumbnails([Thumbnail(assetID: "a/L0/001", jpeg: Data([0xFF, 0xD8, 0xFF]))])),
        ]
        for frame in frames {
            var decoder = FrameDecoder()
            decoder.append(try FrameCodec.encode(frame))
            #expect(try decoder.next() == frame)
        }
        #expect(String(decoding: try JSONEncoder().encode(ControlMessage.live), as: UTF8.self) == #"{"live":{}}"#)
    }

    @Test func libraryChangesRoundTrip() throws {
        let metadata = AssetMetadata(assetID: "a", originalFilename: "a", creationDate: Date(timeIntervalSince1970: 1_700_000_000), modificationDate: nil, mediaType: "photo",
                                     pixelWidth: 1, pixelHeight: 1, duration: 0, isFavorite: true, location: nil, albums: ["Trips"])
        let frame = Frame.control(.libraryChanges(changed: [ManifestEntry(metadata: metadata, resources: [])], removed: ["b", "c"], albums: ["Trips"]))
        var decoder = FrameDecoder()
        decoder.append(try FrameCodec.encode(frame))
        #expect(try decoder.next() == frame)
    }

    @Test func everyMessageNameIsListed() throws {
        let key = ResourceKey(assetID: "a", kind: .photo, revision: "original")
        let descriptor = ResourceDescriptor(key: key, originalFilename: "a", uti: "public.heic")
        let metadata = AssetMetadata(assetID: "a", originalFilename: "a", creationDate: nil, modificationDate: nil, mediaType: "photo",
                                     pixelWidth: 1, pixelHeight: 1, duration: 0, isFavorite: false, location: nil, albums: [])
        let all: [ControlMessage] = [
            .pairRequest(deviceID: "", deviceName: "", protocolVersion: 4), .paired(deviceKey: Data(), serverName: ""),
            .hello(deviceID: "", deviceName: "", protocolVersion: 4, proof: nil), .welcome(serverName: ""), .unavailable(reason: ""),
            .manifest([]), .need([]), .beginResource(descriptor, metadata: metadata, size: 0), .endResource(key, sha256: ""),
            .stored(key), .failed(key, reason: ""), .goodbye, .manifestEnd(albums: []), .changes([]), .changeReport([]),
            .live, .thumbnailRequest([]), .thumbnails([]),
            .restoreRequest(UUID()), .restoreAsset(RestoreAsset(metadata: metadata, files: [])), .restoreEnd(UUID(), missing: []),
            .libraryChanges(changed: [ManifestEntry(metadata: metadata, resources: [descriptor])], removed: ["b"], albums: ["Trips"]),
        ]
        let names = try all.map { try (JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as! [String: Any]).keys.first! }
        #expect(Set(names) == ControlMessage.names)
    }
}
