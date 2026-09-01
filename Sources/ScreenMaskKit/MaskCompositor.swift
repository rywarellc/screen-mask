import AVFoundation
import CoreImage
import Foundation

public enum MaskCompositorError: LocalizedError {
    case noVideoTrack
    case exportUnavailable

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "That file doesn't contain a video track."
        case .exportUnavailable: return "Couldn't create an export session for this video."
        }
    }
}

public enum MaskCompositor {
    /// Converts a normalized top-left rect into Core Image's bottom-left pixel space.
    public static func pixelRect(_ normalized: CGRect, in extent: CGRect) -> CGRect? {
        guard extent.width > 0, extent.height > 0,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite
        else { return nil }
        let x = extent.minX + normalized.minX * extent.width
        let w = normalized.width * extent.width
        let h = normalized.height * extent.height
        let y = extent.maxY - (normalized.maxY * extent.height)
        let r = CGRect(x: x, y: y, width: w, height: h).integral
        guard r.width >= 1, r.height >= 1 else { return nil }
        return r.intersection(extent).isNull ? nil : r.intersection(extent)
    }

    /// Composites every region active at `time` over the frame.
    public static func apply(regions: [MaskRegion], to source: CIImage, at time: Double) -> CIImage {
        let extent = source.extent
        var output = source

        for region in regions where region.isActive(at: time) {
            guard let rect = pixelRect(region.rect, in: extent) else { continue }

            switch region.style {
            case .solid:
                output = CIImage(color: CIColor.black)
                    .cropped(to: rect)
                    .composited(over: output)

            case .pixelate(let scale):
                // Clamp first so blocks at the region's edge aren't sampled from
                // transparent space outside the frame.
                let blockSize = max(2.0, min(rect.width, rect.height) * scale)
                let blocky = source
                    .clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY),
                        kCIInputScaleKey: blockSize,
                    ])
                    .cropped(to: rect)
                output = blocky.composited(over: output)
            }
        }
        return output
    }

    /// Builds the composition once; it reads live from `store` on every frame.
    public static func makeVideoComposition(
        for asset: AVAsset,
        store: RegionStore
    ) async throws -> AVMutableVideoComposition {
        try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let output = apply(
                regions: store.regions,
                to: request.sourceImage,
                at: request.compositionTime.seconds
            )
            request.finish(with: output, context: nil)
        }
    }

    public static func export(
        asset: AVAsset,
        composition: AVVideoComposition,
        to url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw MaskCompositorError.exportUnavailable
        }
        session.videoComposition = composition

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // AVAssetExportSession isn't Sendable, but Apple's guidance is to observe
        // `states` while `export` runs. The box carries it across the task boundary
        // without loosening anything else.
        let box = UncheckedBox(session)
        let progressTask = Task {
            for await state in box.value.states(updateInterval: 0.25) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }
        try await box.value.export(to: url, as: .mov)
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
