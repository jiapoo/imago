import Foundation
import ImageIO
import PhotoBackupKit
import Vision

/// Finds near-identical photos (the same scene shot several times) with Vision, using the backed-up
/// files. Only photos taken within a minute of each other are compared, which keeps it fast.
enum SimilarPhotos {
    /// Feature-print distance under which two photos count as the same shot. Tuned for revision 2
    /// prints, where unrelated photos are usually above 0.6 and retakes below 0.4.
    static let threshold: Float = 0.45

    static func find(
        in assets: [PhoneAsset], files: [String: URL], progress: @escaping @MainActor (Double) -> Void
    ) async -> [Cleanup.Group] {
        let runs = Cleanup.moments(assets)
        let total = max(runs.reduce(0) { $0 + $1.count }, 1)
        var done = 0
        var groups: [Cleanup.Group] = []

        for run in runs {
            if Task.isCancelled { break }
            var prints: [String: VNFeaturePrintObservation] = [:]
            var scores: [String: Double] = [:]
            for asset in run {
                guard let url = files[asset.id], let result = analyze(url) else { continue }
                prints[asset.id] = result.print
                if let score = result.score { scores[asset.id] = score }
            }
            groups += Cleanup.cluster(run, threshold: threshold, scores: scores) { a, b in
                guard let pa = prints[a.id], let pb = prints[b.id] else { return nil }
                var distance: Float = 0
                return (try? pa.computeDistance(&distance, to: pb)) == nil ? nil : distance
            }
            done += run.count
            let fraction = Double(done) / Double(total)
            await progress(fraction)
        }
        return groups.sorted { ($0.keep.metadata.creationDate ?? .distantPast) > ($1.keep.metadata.creationDate ?? .distantPast) }
    }

    /// A feature print and, where available, an aesthetics score for picking the best shot.
    private static func analyze(_ url: URL) -> (print: VNFeaturePrintObservation, score: Double?)? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        let printRequest = VNGenerateImageFeaturePrintRequest()
        let scoreRequest = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([printRequest, scoreRequest])
        guard let print = printRequest.results?.first else { return nil }
        let score = scoreRequest.results?.first.map { Double($0.overallScore) }
        return (print, score)
    }
}
