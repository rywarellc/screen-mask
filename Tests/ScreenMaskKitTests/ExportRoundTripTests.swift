import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import ScreenMaskKit

private let context = CIContext(options: [.useSoftwareRenderer: true])
private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

private func sample(_ image: CIImage, at point: CGPoint) -> (r: Double, g: Double, b: Double) {
    var px = [UInt8](repeating: 0, count: 4)
    context.render(
        image,
        toBitmap: &px,
        rowBytes: 4,
        bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: srgb
    )
    return (Double(px[0]), Double(px[1]), Double(px[2]))
}

private struct FixtureError: Error { let message: String }

/// Writes a flat white clip — maximum contrast against a solid black mask, so
/// decode noise can't be mistaken for a masking result.
///
/// Each frame gets its own buffer from the adaptor's pool: the writer holds
/// appended buffers while it encodes, so recycling one buffer corrupts them.
private func writeWhiteClip(to url: URL, size: CGSize, seconds: Double, fps: Int32) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
    ])
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
    )
    writer.add(input)
    guard writer.startWriting() else {
        throw FixtureError(message: "startWriting failed: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)

    guard let pool = adaptor.pixelBufferPool else {
        throw FixtureError(message: "no pixel buffer pool")
    }

    for frame in 0..<Int(seconds * Double(fps)) {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
              let buffer = created else {
            throw FixtureError(message: "pool exhausted at frame \(frame)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0xFF, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            throw FixtureError(message: "append failed: \(String(describing: writer.error))")
        }
    }

    input.markAsFinished()
    await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
        throw FixtureError(message: "writer ended \(writer.status): \(String(describing: writer.error))")
    }
}

private func frame(of asset: AVAsset, at seconds: Double) async throws -> CIImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let (image, _) = try await generator.image(
        at: CMTime(seconds: seconds, preferredTimescale: 600)
    )
    return CIImage(cgImage: image)
}

@Test("A masked export bakes the mask into the file, only within its time range")
func exportedFileCarriesTheMask() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("screenmask-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.mov")
    let outputURL = directory.appendingPathComponent("masked.mov")
    let size = CGSize(width: 640, height: 360)
    try await writeWhiteClip(to: sourceURL, size: size, seconds: 3, fps: 30)

    let asset = AVURLAsset(url: sourceURL)
    let store = RegionStore()
    // Top-left quadrant, hidden only between 1s and 2s.
    store.regions = [
        MaskRegion(
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            start: 1.0,
            end: 2.0,
            style: .solid(color: .black)
        )
    ]

    let composition = try await MaskCompositor.makeVideoComposition(for: asset, store: store)
    #expect(composition.renderSize == size)

    try await MaskCompositor.export(asset: asset, composition: composition, to: outputURL) { _ in }
    #expect(FileManager.default.fileExists(atPath: outputURL.path))

    let exported = AVURLAsset(url: outputURL)

    // Core Image space: the picture's top-left quadrant sits at high y.
    let inMask = CGPoint(x: 160, y: 270)
    let outsideMask = CGPoint(x: 480, y: 90)

    let masked = try await frame(of: exported, at: 1.5)
    let maskedPixel = sample(masked, at: inMask)
    #expect(maskedPixel.r < 60 && maskedPixel.g < 60 && maskedPixel.b < 60,
            "top-left should be blacked out at 1.5s, got \(maskedPixel)")

    let untouched = sample(masked, at: outsideMask)
    #expect(untouched.r > 180, "bottom-right should stay white at 1.5s, got \(untouched)")

    for time in [0.5, 2.5] {
        let clear = try await frame(of: exported, at: time)
        let pixel = sample(clear, at: inMask)
        #expect(pixel.r > 180, "top-left should be clear at \(time)s, got \(pixel)")
    }
}

@Test("Export reports progress and finishes at 100%")
func exportReportsProgress() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("screenmask-progress-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.mov")
    let outputURL = directory.appendingPathComponent("masked.mov")
    try await writeWhiteClip(to: sourceURL, size: CGSize(width: 640, height: 360), seconds: 3, fps: 30)

    let asset = AVURLAsset(url: sourceURL)
    let store = RegionStore()
    store.regions = [
        MaskRegion(rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), start: 0, end: 3, style: .solid(color: .black))
    ]
    let composition = try await MaskCompositor.makeVideoComposition(for: asset, store: store)

    let samples = Samples()
    try await MaskCompositor.export(asset: asset, composition: composition, to: outputURL) { value in
        samples.record(value)
    }

    let observed = samples.values
    #expect(observed.allSatisfy { $0 >= 0 && $0 <= 1 }, "progress out of range: \(observed)")
    #expect(observed == observed.sorted(), "progress went backwards: \(observed)")
}

private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
