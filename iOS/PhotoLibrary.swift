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

    /// One entry per asset, oldest first. No file data is read here.
    /// `progress` gets 0...1 as assets are read.
    static func scan(progress: @escaping (Double) -> Void = { _ in }) -> [ManifestEntry] {
        let albums = albumMembership()
        progress(0.1)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        let assets = PHAsset.fetchAssets(with: options)

        var entries: [ManifestEntry] = []
        entries.reserveCapacity(assets.count)
        let count = max(assets.count, 1)
        assets.enumerateObjects { asset, index, _ in
            if let entry = entry(for: asset, albums: albums[asset.localIdentifier] ?? []) {
                entries.append(entry)
            }
            if index % 200 == 0 { progress(0.1 + 0.9 * Double(index) / Double(count)) }
        }
        return entries
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

    private static func entry(for asset: PHAsset, albums: [String]) -> ManifestEntry? {
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
                }
            }
            return ChangeReport(changeID: change.id, outcome: .applied, assetCount: found)
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return ChangeReport(changeID: change.id, outcome: .declined, assetCount: 0)
        } catch {
            return ChangeReport(changeID: change.id, outcome: .failed, assetCount: 0, detail: error.localizedDescription)
        }
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

    private static func albumMembership() -> [String: [String]] {
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
