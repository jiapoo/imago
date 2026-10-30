import CoreLocation
import Foundation
import Photos
import UIKit
import ImagoKit

/// Reads the Photos library into a manifest (metadata only) and exports single files on demand.
enum PhotoLibrary {
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// One entry per asset, oldest first. No file data is read here. After the first time, only
    /// what changed since is read again (see `LibraryList`).
    /// `progress` gets 0...1 as assets are read.
    static func scan(progress: @escaping (Double) -> Void = { _ in }) -> [ManifestEntry] {
        LibraryList.shared.manifest(progress: progress)
    }

    /// Every asset a scan lists, oldest first.
    fileprivate static func fetchAll() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        return PHAsset.fetchAssets(with: options)
    }

    /// What photos and videos take up on this iPhone: the size of every file of each, originals and
    /// edits alike, as Settings › iPhone Storage counts them. Reads no file data, but asks Photos
    /// about every file, so on a large library it takes a few seconds: call it off the main thread.
    static func sizes() -> (photos: Int64, videos: Int64) {
        var photos: Int64 = 0
        var videos: Int64 = 0
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let bytes = PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { $0 + fileSize(of: $1) }
            if asset.mediaType == .video { videos += bytes } else { photos += bytes }
        }
        return (photos, videos)
    }

    /// Photos doesn't publish a resource's size, but every resource has had it under this key since
    /// iOS 10. Checked first so a future iOS without it reads as 0 instead of crashing.
    private static func fileSize(of resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    /// Writes one resource to a temporary file, downloading the original from iCloud if needed.
    /// `progress` gets 0...1 while the original downloads from iCloud; it isn't called for files already on the iPhone.
    static func export(_ key: ResourceKey, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [key.assetID], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { ResourceKind($0.type) == key.kind })
        else { throw ExportError.missing(key) }

        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + "-" + resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress($0) }
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }

    enum ExportError: LocalizedError {
        case missing(ResourceKey)
        var errorDescription: String? { "This item was deleted or changed on the iPhone." }
    }

    fileprivate static func entry(for asset: PHAsset, albums: [String]) -> ManifestEntry? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Originals never change. Edits are keyed by modification date so a re-edit is sent again.
        // (Favoriting also bumps it, which re-sends the edited render; acceptable for now.)
        let editRevision = String(Int(asset.modificationDate?.timeIntervalSince1970 ?? 0))
        let descriptors: [ResourceDescriptor] = resources.compactMap { resource in
            guard let kind = ResourceKind(resource.type) else { return nil }
            return ResourceDescriptor(
                key: ResourceKey(assetID: asset.localIdentifier, kind: kind, revision: kind.isEdit ? editRevision : "original"),
                originalFilename: resource.originalFilename,
                uti: resource.uniformTypeIdentifier
            )
        }
        guard !descriptors.isEmpty else { return nil }

        let primary = resources.first { $0.type == .photo || $0.type == .video }?.originalFilename
            ?? descriptors[0].originalFilename
        let metadata = AssetMetadata(
            assetID: asset.localIdentifier,
            originalFilename: primary,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            mediaType: asset.mediaType == .video ? "video" : "photo",
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            location: asset.location.map {
                .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: $0.altitude)
            },
            albums: albums,
            subtypes: subtypeNames(asset.mediaSubtypes),
            burstID: asset.burstIdentifier
        )
        return ManifestEntry(metadata: metadata, resources: descriptors)
    }

    private static func subtypeNames(_ subtypes: PHAssetMediaSubtype) -> [String] {
        let names: [(PHAssetMediaSubtype, String)] = [
            (.photoScreenshot, "screenshot"), (.videoScreenRecording, "screenRecording"), (.photoLive, "livePhoto"),
            (.photoPanorama, "panorama"), (.photoHDR, "hdr"), (.photoDepthEffect, "depthEffect"),
            (.videoHighFrameRate, "highFrameRate"), (.videoTimelapse, "timelapse"), (.videoCinematic, "cinematic"),
            (.spatialMedia, "spatial"),
        ]
        return names.filter { subtypes.contains($0.0) }.map(\.1)
    }

    /// Every album title, including empty albums.
    static func albumTitles() -> [String] {
        var titles: [String] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { album, _, _ in
            if let title = album.localizedTitle, !titles.contains(title) { titles.append(title) }
        }
        return titles
    }

    // MARK: Previews for the Mac

    /// Small JPEG previews, from what's on the phone (no iCloud downloads). Missing assets are left out.
    static func thumbnails(_ assetIDs: [String]) async -> [Thumbnail] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in list.append(asset) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        let size = CGSize(width: Thumbnail.pixelSize, height: Thumbnail.pixelSize)
        var thumbnails: [Thumbnail] = []
        for asset in list {
            let image: UIImage? = await withCheckedContinuation { done in
                PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                    done.resume(returning: image)
                }
            }
            if let jpeg = image?.jpegData(compressionQuality: 0.7) {
                thumbnails.append(Thumbnail(assetID: asset.localIdentifier, jpeg: jpeg))
            }
        }
        return thumbnails
    }

    // MARK: Changes from the Mac

    /// Makes one change the user approved. Deletions show iOS's own confirmation first.
    static func apply(_ change: LibraryChange) async -> ChangeReport {
        // An album to delete has no assets of its own.
        if case .deleteAlbum(let title) = change.action { return await deleteAlbum(titled: title, change: change) }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: change.assetIDs, options: nil).count
        guard found > 0 else {
            return ChangeReport(changeID: change.id, outcome: .failed, assetCount: 0,
                                detail: "These items are no longer on the iPhone.")
        }
        if case .removeFromAlbum(let title) = change.action, editableAlbum(titled: title) == nil {
            return ChangeReport(changeID: change.id, outcome: .failed, assetCount: 0,
                                detail: "There's no album named “\(title)” on the iPhone that can be changed.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // Fetched again here: PhotoKit objects can't cross into this block.
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: change.assetIDs, options: nil)
                switch change.action {
                case .delete:
                    PHAssetChangeRequest.deleteAssets(assets)
                case .addToAlbum(let title):
                    let request = editableAlbum(titled: title).flatMap { PHAssetCollectionChangeRequest(for: $0) }
                        ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    request.addAssets(assets)
                case .removeFromAlbum(let title):
                    if let album = editableAlbum(titled: title) {
                        PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets)
                    }
                case .setFavorite(let on):
                    assets.enumerateObjects { asset, _, _ in PHAssetChangeRequest(for: asset).isFavorite = on }
                case .deleteAlbum, .restore:
                    break // Handled above, and by `restore`.
                }
            }
            return ChangeReport(changeID: change.id, outcome: .applied, assetCount: found)
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return ChangeReport(changeID: change.id, outcome: .declined, assetCount: 0)
        } catch {
            return ChangeReport(changeID: change.id, outcome: .failed, assetCount: 0, detail: error.localizedDescription)
        }
    }

    /// Deletes a regular album, as Photos does: its photos stay in the library. iOS asks the user first.
    private static func deleteAlbum(titled title: String, change: LibraryChange) async -> ChangeReport {
        guard let album = editableAlbum(titled: title) else {
            return ChangeReport(changeID: change.id, outcome: .failed, assetCount: 0,
                                detail: "There's no album named “\(title)” on the iPhone that can be deleted.")
        }
        let identifier = album.localIdentifier
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
                PHAssetCollectionChangeRequest.deleteAssetCollections(albums)
            }
            return ChangeReport(changeID: change.id, outcome: .applied, assetCount: 0)
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return ChangeReport(changeID: change.id, outcome: .declined, assetCount: 0)
        } catch {
            return ChangeReport(changeID: change.id, outcome: .failed, assetCount: 0, detail: error.localizedDescription)
        }
    }

    /// Puts a photo or video back in the library from the Mac's backup: its original files, its date,
    /// place and favorite, and the albums it was in that are still here. Returns its new identifier.
    /// The files are moved into the library.
    static func restore(_ asset: RestoreAsset, files: [(RestoreAsset.File, URL)]) async throws -> String {
        final class Created: @unchecked Sendable { var identifier: String? }
        let created = Created()
        let metadata = asset.metadata
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            for (file, url) in files {
                guard let type = PHAssetResourceType(file.key.kind) else { continue }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.originalFilename
                options.shouldMoveFile = true
                request.addResource(with: type, fileURL: url, options: options)
            }
            request.creationDate = metadata.creationDate
            request.isFavorite = metadata.isFavorite
            if let place = metadata.location {
                request.location = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), altitude: place.altitude,
                    horizontalAccuracy: 0, verticalAccuracy: 0, timestamp: metadata.creationDate ?? .now
                )
            }
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            created.identifier = placeholder.localIdentifier
            for title in metadata.albums {
                guard let album = editableAlbum(titled: title) else { continue }
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
        guard let identifier = created.identifier else { throw RestoreError.notCreated }
        return identifier
    }

    enum RestoreError: LocalizedError {
        case notCreated
        var errorDescription: String? { "Photos didn't add it back." }
    }

    /// A regular album the user made (not a smart or shared album) with this title.
    private static func editableAlbum(titled title: String) -> PHAssetCollection? {
        var match: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { album, _, stop in
            if album.localizedTitle == title, album.canPerform(.addContent) {
                match = album
                stop.pointee = true
            }
        }
        return match
    }

    fileprivate static func albumMembership() -> [String: [String]] {
        var membership: [String: [String]] = [:]
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { album, _, _ in
            guard let title = album.localizedTitle else { return }
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                membership[asset.localIdentifier, default: []].append(title)
            }
        }
        return membership
    }
}

/// The library list, kept up to date as Photos changes. The first list asks Photos about every asset's
/// files, which takes a while on a big library; after that, each change re-reads only the assets it
/// touched. Before, every change (a favorite, a photo added from the Mac) read the whole library
/// again. Album membership is read each time: it's quick, and adding to an album doesn't change the asset.
final class LibraryList: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    static let shared = LibraryList()
    /// Posted after a change to the library has been taken in, so the list is current.
    static let changed = Notification.Name("LibraryListChanged")

    private let lock = NSLock()
    private var fetch: PHFetchResult<PHAsset>?
    /// Each asset's entry by identifier, without its albums.
    private var entries: [String: ManifestEntry] = [:]
    private var observing = false

    func manifest(progress: @escaping (Double) -> Void = { _ in }) -> [ManifestEntry] {
        lock.lock()
        defer { lock.unlock() }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        let albums = PhotoLibrary.albumMembership()
        progress(0.1)
        let fetch: PHFetchResult<PHAsset>
        if let current = self.fetch {
            fetch = current
        } else {
            fetch = PhotoLibrary.fetchAll()
            var entries: [String: ManifestEntry] = [:]
            let count = max(fetch.count, 1)
            fetch.enumerateObjects { asset, index, _ in
                entries[asset.localIdentifier] = PhotoLibrary.entry(for: asset, albums: [])
                if index % 200 == 0 { progress(0.1 + 0.9 * Double(index) / Double(count)) }
            }
            self.fetch = fetch
            self.entries = entries
        }
        var list: [ManifestEntry] = []
        list.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            guard var entry = self.entries[asset.localIdentifier] else { return }
            entry.metadata.albums = albums[asset.localIdentifier] ?? []
            list.append(entry)
        }
        return list
    }

    func photoLibraryDidChange(_ change: PHChange) {
        lock.lock()
        if let fetch, let details = change.changeDetails(for: fetch) {
            if details.hasIncrementalChanges {
                for asset in details.removedObjects { entries[asset.localIdentifier] = nil }
                for asset in details.insertedObjects + details.changedObjects {
                    entries[asset.localIdentifier] = PhotoLibrary.entry(for: asset, albums: [])
                }
                self.fetch = details.fetchResultAfterChanges
            } else {
                // Too much changed to say what: read everything next time.
                self.fetch = nil
                entries = [:]
            }
        }
        lock.unlock()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

extension PHAssetResourceType {
    /// The type to add a restored file as. Only originals are sent back.
    init?(_ kind: ResourceKind) {
        switch kind {
        case .photo: self = .photo
        case .video: self = .video
        case .alternatePhoto: self = .alternatePhoto
        case .pairedVideo: self = .pairedVideo
        default: return nil
        }
    }
}

extension ResourceKind {
    init?(_ type: PHAssetResourceType) {
        switch type {
        case .photo: self = .photo
        case .video: self = .video
        case .alternatePhoto: self = .alternatePhoto
        case .pairedVideo: self = .pairedVideo
        case .fullSizePhoto: self = .fullSizePhoto
        case .fullSizeVideo: self = .fullSizeVideo
        case .fullSizePairedVideo: self = .fullSizePairedVideo
        case .adjustmentData: self = .adjustmentData
        default: return nil   // proxies and adjustment bases are derivable or temporary
        }
    }
}
