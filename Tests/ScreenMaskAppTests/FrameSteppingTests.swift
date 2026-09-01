import AVFoundation
import Foundation
import Testing

@testable import ScreenMask
import ScreenMaskKit

/// The fixture is 30 frames at 30fps, so one frame is 1/30s.
@MainActor
private func openFixture() async throws -> (AppModel, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("step-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let videoURL = directory.appendingPathComponent("clip.mov")
    try await writeClip(to: videoURL)

    let model = AppModel(documents: MaskDocumentStore(directory: directory.appendingPathComponent("masks")))
    await model.open(videoURL)

    // Stepping needs a ready item; polling beats an arbitrary sleep.
    for _ in 0..<250 where model.player.currentItem?.status != .readyToPlay {
        try await Task.sleep(for: .milliseconds(20))
    }
    return (model, directory)
}

/// Waits for the model's clock to move off `from`, so the test doesn't depend on
/// how quickly AVFoundation completes a step.
@MainActor
private func awaitTimeChange(_ model: AppModel, from: Double) async throws -> Double {
    for _ in 0..<150 where model.currentTime == from {
        try await Task.sleep(for: .milliseconds(20))
    }
    return model.currentTime
}

@MainActor
@Test("Stepping moves exactly one frame, forward and back")
func steppingMovesOneFrame() async throws {
    let (model, directory) = try await openFixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    // The fixture is 30fps, so a frame is ~0.0333s. The upper bound is what
    // matters: AVPlayerItem.step(byCount:) jumps 0.25s on this clip, and this
    // test is what caught that.
    let oneFrame = 1.0 / 30.0
    var previous = model.currentTime

    for index in 0..<3 {
        #expect(model.stepFrame(1), "step \(index) should succeed")
        let now = try await awaitTimeChange(model, from: previous)
        let delta = now - previous
        #expect(delta > oneFrame * 0.5 && delta < oneFrame * 1.5,
                "step \(index) moved \(delta)s, expected about \(oneFrame)s")
        previous = now
    }

    #expect(model.stepFrame(-1), "should step backward too")
    let back = try await awaitTimeChange(model, from: previous)
    let delta = previous - back
    #expect(delta > oneFrame * 0.5 && delta < oneFrame * 1.5,
            "backward step moved \(delta)s, expected about \(oneFrame)s")
}

@MainActor
@Test("Stepping stops at the ends of the clip")
func steppingClampsAtTheEnds() async throws {
    let (model, directory) = try await openFixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(model.currentTime == 0)
    #expect(model.stepFrame(-1) == false, "already at the start")

    model.seek(to: model.duration)
    #expect(model.stepFrame(1) == false, "already at the end")
    #expect(model.stepFrame(-1), "but can still come back")
}

@MainActor
@Test("Stepping is refused while playing, with no video, and for zero frames")
func steppingIsRefusedWhenItShouldNotApply() async throws {
    let empty = AppModel(documents: MaskDocumentStore(directory: FileManager.default.temporaryDirectory))
    #expect(empty.stepFrame(1) == false, "no video loaded")

    let (model, directory) = try await openFixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(model.stepFrame(0) == false, "zero frames is not a step")

    model.togglePlayback()
    #expect(model.isPlaying)
    #expect(model.stepFrame(1) == false, "stepping only applies while paused")

    model.togglePlayback()
    #expect(!model.isPlaying)
    #expect(model.stepFrame(1), "should step again once paused")
}
