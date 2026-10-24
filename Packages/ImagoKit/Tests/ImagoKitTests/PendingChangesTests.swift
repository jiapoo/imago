import Foundation
import Testing
@testable import ImagoKit

private func asset(_ id: String, at seconds: TimeInterval? = 0, favorite: Bool = false, albums: [String] = [],
                   subtypes: [String]? = [], video: Bool = false) -> PhoneAsset {
    PhoneAsset(
        metadata: AssetMetadata(
            assetID: id, originalFilename: "IMG_0001.HEIC", creationDate: seconds.map { Date(timeIntervalSince1970: 1_792_506_612 + $0) },
            modificationDate: nil, mediaType: video ? "video" : "photo", pixelWidth: 1, pixelHeight: 1,
            duration: 0, isFavorite: favorite, location: nil, albums: albums, subtypes: subtypes
        ),
        originalSHA256: nil, bytes: 100, isBackedUp: true
    )
}

private func base(_ assets: [PhoneAsset]) -> [String: AssetMetadata] {
    Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.metadata) })
}

@Suite struct PendingChangesTests {
    @Test func applyShowsFavoritesAndAlbumsButKeepsDeletedAssets() {
        let assets = [asset("a"), asset("b", albums: ["Trip"]), asset("c")]
        let changes = [
            LibraryChange(action: .setFavorite(true), assetIDs: ["a"]),
            LibraryChange(action: .addToAlbum("Tennis"), assetIDs: ["a", "b"]),
            LibraryChange(action: .removeFromAlbum("Trip"), assetIDs: ["b"]),
            LibraryChange(action: .delete, assetIDs: ["c"]),
        ]
        let result = PendingChanges.apply(changes, to: assets)
        #expect(result.map(\.id) == ["a", "b", "c"])
        #expect(result[0].metadata.isFavorite)
        #expect(result[0].metadata.albums == ["Tennis"])
        #expect(result[1].metadata.albums == ["Tennis"])
        #expect(PendingChanges.deleting(changes) == ["c"])
        #expect(PendingChanges.touched(changes) == ["a", "b", "c"])
        #expect(PendingChanges.albums(["Trip"], with: changes) == ["Trip", "Tennis"])
    }

    @Test func undoingAChangeTakesItBack() {
        let assets = [asset("a"), asset("b")]
        var queue = PendingChanges.queue(LibraryChange(action: .setFavorite(true), assetIDs: ["a", "b"]), onto: [], base: base(assets))
        queue = PendingChanges.queue(LibraryChange(action: .setFavorite(false), assetIDs: ["a"]), onto: queue, base: base(assets))
        #expect(queue.count == 1)
        #expect(queue[0].assetIDs == ["b"])

        queue = PendingChanges.queue(LibraryChange(action: .setFavorite(false), assetIDs: ["b"]), onto: queue, base: base(assets))
        #expect(queue.isEmpty)
    }

    @Test func albumAddThenRemoveCancels() {
        let assets = [asset("a")]
        var queue = PendingChanges.queue(LibraryChange(action: .addToAlbum("New"), assetIDs: ["a"]), onto: [], base: base(assets))
        queue = PendingChanges.queue(LibraryChange(action: .removeFromAlbum("New"), assetIDs: ["a"]), onto: queue, base: base(assets))
        #expect(queue.isEmpty)
    }

    @Test func changesThatAreAlreadyTrueAreLeftOut() {
        let assets = [asset("fav", favorite: true), asset("plain"), asset("inTrip", albums: ["Trip"])]
        let queue = PendingChanges.queue(LibraryChange(action: .setFavorite(true), assetIDs: ["fav", "plain"]), onto: [], base: base(assets))
        #expect(queue.map(\.assetIDs) == [["plain"]])
        #expect(PendingChanges.queue(LibraryChange(action: .addToAlbum("Trip"), assetIDs: ["inTrip"]), onto: [], base: base(assets)).isEmpty)
        #expect(PendingChanges.queue(LibraryChange(action: .removeFromAlbum("Trip"), assetIDs: ["plain"]), onto: [], base: base(assets)).isEmpty)
    }

    @Test func deletionsAreNotQueuedTwice() {
        let assets = [asset("a"), asset("b")]
        var queue = PendingChanges.queue(LibraryChange(action: .delete, assetIDs: ["a"], bytes: 100), onto: [], base: base(assets))
        queue = PendingChanges.queue(LibraryChange(action: .delete, assetIDs: ["a", "b"], bytes: 200), onto: queue, base: base(assets))
        #expect(queue.map(\.assetIDs) == [["a"], ["b"]])
        #expect(queue[1].bytes == 100)
    }

    @Test func withdrawKeepsItemsAfterAll() {
        let pending = [
            LibraryChange(action: .delete, assetIDs: ["a", "b"], bytes: 200),
            LibraryChange(action: .setFavorite(true), assetIDs: ["a"]),
            LibraryChange(action: .delete, assetIDs: ["c"], bytes: 100),
        ]
        let left = PendingChanges.withdraw(["a", "c"], from: .delete, in: pending)
        #expect(left.map(\.assetIDs) == [["b"], ["a"]])
        #expect(left[0].bytes == 100)
    }

    @Test func mediaTypes() {
        let live = asset("live", subtypes: ["livePhoto"]), shot = asset("shot", subtypes: ["screenshot"])
        let recording = asset("rec", subtypes: ["screenRecording"], video: true)
        #expect(PhoneMediaType.livePhotos.contains(live))
        #expect(PhoneMediaType.screenshots.contains(shot))
        #expect(!PhoneMediaType.screenshots.contains(recording))
        #expect(PhoneMediaType.screenRecordings.contains(recording))
        #expect(PhoneMediaType.videos.contains(recording))
    }

    @Test func byMonthOldestFirstUndatedLast() {
        let day = 86_400.0
        let months = Cleanup.byMonth([asset("a"), asset("b", at: -40 * day), asset("c", at: nil), asset("d", at: 1)],
                                     timeZone: TimeZone(identifier: "UTC")!)
        #expect(months.map(\.month) == [9, 10, nil])
        #expect(months[1].assets.map(\.id) == ["a", "d"])
    }
}
