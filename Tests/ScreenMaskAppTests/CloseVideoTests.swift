import AVFoundation
import Foundation
import Testing

@testable import ScreenMask
import ScreenMaskKit

/// Minimal real clip; AppModel refuses anything without a video track.
private func writeClip(to url: URL) async throws {
    let size = CGSize(width: 320, height: 180)
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
    _ = writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let pool = adaptor.pixelBufferPool!

    for frame in 0..<30 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0xFF, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        _ = adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await withCheckedContinuation { c in writer.finishWriting { c.resume() } }
}

@MainActor
@Test("Closing a video keeps its saved masks")
func closingDoesNotDestroySavedMasks() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("close-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let videoURL = directory.appendingPathComponent("clip.mov")
    try await writeClip(to: videoURL)

    let documents = MaskDocumentStore(directory: directory.appendingPathComponent("masks"))
    let model = AppModel(documents: documents)

    await model.open(videoURL)
    #expect(model.hasVideo, "fixture should have opened")

    model.addRegion(rect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))
    #expect(model.regions.count == 1)

    model.closeVideo()

    // The empty state is reached...
    #expect(!model.hasVideo)
    #expect(model.regions.isEmpty)
    #expect(model.duration == 0)
    #expect(model.selection == nil)

    // ...without taking the masks on disk with it. Clearing `regions` while the
    // URL is still set would schedule a save of an empty list, which deletes the
    // document. That save is debounced, so wait past the window before checking —
    // asserting immediately would pass even with the bug present.
    try await Task.sleep(for: .milliseconds(800))

    let saved = documents.load(for: videoURL)
    #expect(saved?.count == 1, "closing destroyed the saved masks")

    // And reopening restores them.
    await model.open(videoURL)
    #expect(model.regions.count == 1, "masks did not come back on reopen")
}
