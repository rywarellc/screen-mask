import AVFoundation
import AppKit
import CoreImage
import Observation
import SwiftUI
import ScreenMaskKit

enum KeyCode {
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
}

@MainActor
@Observable
final class AppModel {
    var url: URL?
    var duration: Double = 0
    var currentTime: Double = 0
    var videoSize: CGSize = CGSize(width: 16, height: 9)
    var isPlaying = false

    var regions: [MaskRegion] = [] {
        didSet {
            store.regions = regions
            scheduleSave()
        }
    }
    var selection: MaskRegion.ID?

    /// Armed by the eyedropper button; the next click on the video samples.
    var isPickingColor = false
    var isExporting = false
    var exportProgress: Double = 0
    var errorMessage: String?

    let player = AVPlayer()
    let store = RegionStore()

    private var asset: AVURLAsset?
    private var composition: AVVideoComposition?
    private var timeObserver: Any?
    private var lastRefresh = Date.distantPast
    private let ciContext = CIContext()
    private var frameDuration = CMTime(value: 1, timescale: 30)
    private let documents: MaskDocumentStore
    private var saveTask: Task<Void, Never>?
    private var isClosing = false
    private var terminationObserver: NSObjectProtocol?
    // Read from deinit, which is nonisolated; only ever written on the main actor.
    nonisolated(unsafe) private var keyMonitor: Any?

    init(documents: MaskDocumentStore = .defaultStore()) {
        self.documents = documents
        // A debounced save can still be pending when the user quits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    var hasVideo: Bool { asset != nil }
    var aspectRatio: Double {
        videoSize.height > 0 ? videoSize.width / videoSize.height : 16.0 / 9.0
    }
    var selectedRegion: MaskRegion? {
        guard let selection else { return nil }
        return regions.first { $0.id == selection }
    }

    // MARK: - Loading

    func open(_ url: URL) async {
        flushSave()
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw MaskCompositorError.noVideoTrack
            }
            let (natural, transform, minFrameDuration) = try await track.load(
                .naturalSize, .preferredTransform, .minFrameDuration)
            let duration = try await asset.load(.duration)
            let composition = try await MaskCompositor.makeVideoComposition(for: asset, store: store)

            self.asset = asset
            self.url = url
            self.composition = composition
            // A rotated recording reports its pre-transform natural size, and
            // the transform can flip an axis negative — hence the abs().
            let oriented = natural.applying(transform)
            self.videoSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            self.duration = max(duration.seconds, 0)
            // Falls back to 30fps for assets that don't report a frame duration.
            self.frameDuration = minFrameDuration.isValid && minFrameDuration.seconds > 0
                ? minFrameDuration
                : CMTime(value: 1, timescale: 30)
            self.selection = nil
            self.currentTime = 0
            // Assigned after `duration` is known so restored regions can be
            // clamped, and after `url` so the didSet save targets the right file.
            self.regions = (documents.load(for: url) ?? [])
                .compactMap { $0.clamped(toDuration: self.duration) }

            self.isPickingColor = false

            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            player.replaceCurrentItem(with: item)
            observeTime()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func observeTime() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
            }
        }
    }

    /// Returns to the empty state, ready for another video.
    ///
    /// Order matters: the current masks are flushed to disk *before* `url` is
    /// cleared, and `regions` is emptied only after. Emptying regions while the
    /// URL is still set would schedule a save of an empty list, which deletes the
    /// document — silently destroying the masks for a video the user only meant
    /// to close. `isClosing` guards the same hazard a second way.
    func closeVideo() {
        flushSave()
        isClosing = true
        defer { isClosing = false }

        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        url = nil
        asset = nil
        composition = nil
        regions = []
        selection = nil
        duration = 0
        currentTime = 0
        isPlaying = false
        isPickingColor = false
        videoSize = CGSize(width: 16, height: 9)
    }

    // MARK: - Transport

    func togglePlayback() {
        guard hasVideo else { return }
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying.toggle()
    }

    /// Handles a key event, returning whether it was consumed.
    ///
    /// Driven by an AppKit event monitor rather than SwiftUI's `onKeyPress`,
    /// which only fires while that exact view holds focus. In practice focus
    /// sits on the scrubber or the mask list — and a focused slider eats the
    /// arrow keys itself — so the keys did nothing.
    ///
    /// Text editing still wins, so arrows move the caret when renaming a mask.
    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == KeyCode.leftArrow || keyCode == KeyCode.rightArrow else { return false }
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }

        // NSApp is an implicitly-unwrapped optional and is nil when no
        // NSApplication exists, so bind it rather than dotting straight through.
        if let app = NSApp,
           let responder = app.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }
        return stepFrame(keyCode == KeyCode.rightArrow ? 1 : -1)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent isn't Sendable, so only the two Sendable fields cross into
            // the isolated call; the event itself never leaves this closure.
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                self?.handleKeyDown(keyCode: keyCode, modifiers: modifiers) ?? false
            }
            return consumed ? nil : event
        }
    }

    /// Steps whole frames while paused.
    ///
    /// Deliberately not `AVPlayerItem.step(byCount:)`: measured against a 30fps
    /// clip that steps by sync samples, jumping 0.25s at a time rather than one
    /// frame. An exact-tolerance seek of one frame duration lands on real frame
    /// boundaries. CMTime arithmetic keeps repeated steps from drifting.
    ///
    /// Returns whether it moved, so the key handler can leave the event alone
    /// when it didn't — at either end of the clip, or during playback.
    @discardableResult
    func stepFrame(_ count: Int) -> Bool {
        guard hasVideo, !isPlaying, count != 0 else { return false }

        // Based on the model's clock, not the player's: during a seek that
        // hasn't landed the two disagree, and stepping from the player's value
        // would move relative to a position the user isn't looking at.
        // Quantising to the frame timescale also snaps to frame boundaries.
        let current = CMTime(seconds: currentTime, preferredTimescale: frameDuration.timescale)
        let target = CMTimeAdd(current, CMTimeMultiply(frameDuration, multiplier: Int32(clamping: count)))
        let end = CMTime(seconds: duration, preferredTimescale: frameDuration.timescale)
        let clamped = min(max(target, .zero), end)
        guard clamped != current else { return false }

        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = min(max(clamped.seconds, 0), duration)
        return true
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Nudges the playhead so a paused preview redraws with the current regions.
    ///
    /// Throttled: a drag emits events far faster than a 4K frame can be re-rendered,
    /// and an unthrottled exact seek per event stutters badly. The live rectangle
    /// outline still tracks the cursor at full rate; only the masked pixels lag.
    /// Gesture end passes `force` so the final position always lands.
    func refreshPreview(force: Bool = false) {
        guard hasVideo, !isPlaying else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastRefresh) >= 0.1 else { return }
        lastRefresh = now
        player.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Regions

    func addRegion(rect: CGRect) {
        let region = MaskRegion(
            rect: rect,
            start: 0,
            end: duration,
            name: "Mask \(regions.count + 1)"
        )
        regions.append(region)
        selection = region.id
        refreshPreview(force: true)
    }

    /// `force: false` is for continuous drags, where the throttle should apply.
    /// Discrete edits — a button, a slider release — always refresh immediately.
    func update(_ id: MaskRegion.ID, force: Bool = true, _ change: (inout MaskRegion) -> Void) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        change(&regions[index])
        refreshPreview(force: force)
    }

    func delete(_ id: MaskRegion.ID) {
        isPickingColor = false
        regions.removeAll { $0.id == id }
        if selection == id { selection = nil }
        refreshPreview(force: true)
    }

    func deleteSelected() {
        if let selection { delete(selection) }
    }

    // MARK: - Eyedropper

    /// Samples the *original* frame rather than the composited one, so clicking
    /// inside an existing mask reads what's underneath instead of the mask itself.
    func pickColor(atNormalized point: CGPoint) async {
        defer { isPickingColor = false }
        guard let asset, let selection else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let (frame, _) = try await generator.image(
                at: CMTime(seconds: currentTime, preferredTimescale: 600)
            )
            guard let color = MaskCompositor.color(
                from: CIImage(cgImage: frame),
                atNormalized: point,
                context: ciContext
            ) else { return }
            update(selection) { $0.style = .solid(color: color) }
        } catch {
            errorMessage = "Couldn't sample that pixel: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    /// Coalesces the rapid edits a drag produces into one write.
    private func scheduleSave() {
        guard !isClosing, let url else { return }
        let snapshot = regions
        let documents = self.documents
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? documents.save(snapshot, for: url)
        }
    }

    /// Writes immediately, for the moments a debounce would lose: quitting, and
    /// switching to another video.
    func flushSave() {
        guard let url else { return }
        saveTask?.cancel()
        saveTask = nil
        try? documents.save(regions, for: url)
    }

    // MARK: - Export

    func export(to destination: URL) async {
        guard let asset, let composition else { return }
        flushSave()
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        do {
            try await MaskCompositor.export(
                asset: asset,
                composition: composition,
                to: destination
            ) { fraction in
                Task { @MainActor in self.exportProgress = fraction }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
    let whole = Int(seconds)
    let tenths = Int((seconds - Double(whole)) * 10)
    return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
}
