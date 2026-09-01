import Foundation
import Testing

@testable import ScreenMaskKit

private func makeStore() throws -> (MaskDocumentStore, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("screenmask-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (MaskDocumentStore(directory: directory), directory)
}

private func sampleRegions() -> [MaskRegion] {
    [
        MaskRegion(
            rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            start: 1.5, end: 4.25, style: .solid, name: "Email"
        ),
        MaskRegion(
            rect: CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25),
            start: 10, end: 12, style: .pixelate(scale: 0.22), name: "API key"
        ),
    ]
}

@Test("Masks survive a save and load round trip")
func roundTripPreservesEverything() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let video = URL(fileURLWithPath: "/tmp/demo.mov")
    let original = sampleRegions()
    try store.save(original, for: video)

    let loaded = try #require(store.load(for: video))
    #expect(loaded == original, "regions changed across the round trip")
    // Identity has to survive too, or selection breaks after a relaunch.
    #expect(loaded.map(\.id) == original.map(\.id))
}

@Test("Both mask styles round trip")
func stylesRoundTrip() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let video = URL(fileURLWithPath: "/tmp/styles.mov")
    try store.save(sampleRegions(), for: video)
    let loaded = try #require(store.load(for: video))

    #expect(loaded[0].style == .solid)
    #expect(loaded[1].style == .pixelate(scale: 0.22))
}

@Test("Each video keeps its own masks")
func videosAreKeyedSeparately() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = URL(fileURLWithPath: "/tmp/one.mov")
    let second = URL(fileURLWithPath: "/tmp/two.mov")

    try store.save([sampleRegions()[0]], for: first)
    try store.save(sampleRegions(), for: second)

    #expect(store.load(for: first)?.count == 1)
    #expect(store.load(for: second)?.count == 2)
    #expect(store.load(for: URL(fileURLWithPath: "/tmp/never-seen.mov")) == nil)
}

@Test("Equivalent paths resolve to the same document")
func pathsAreStandardizedBeforeHashing() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try store.save(sampleRegions(), for: URL(fileURLWithPath: "/tmp/clips/demo.mov"))
    let messy = URL(fileURLWithPath: "/tmp/clips/../clips/./demo.mov")
    #expect(store.load(for: messy)?.count == 2)
}

@Test("Clearing all masks removes the document rather than storing an empty one")
func emptyRegionsDeleteTheDocument() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let video = URL(fileURLWithPath: "/tmp/demo.mov")
    try store.save(sampleRegions(), for: video)
    #expect(FileManager.default.fileExists(atPath: store.documentURL(for: video).path))

    try store.save([], for: video)
    #expect(!FileManager.default.fileExists(atPath: store.documentURL(for: video).path))
    #expect(store.load(for: video) == nil)
}

@Test("A corrupt or future document is ignored instead of blocking the video")
func unreadableDocumentsAreIgnored() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let video = URL(fileURLWithPath: "/tmp/demo.mov")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("this is not json".utf8).write(to: store.documentURL(for: video))
    #expect(store.load(for: video) == nil)

    let future = MaskDocument(
        version: MaskDocument.currentVersion + 1,
        sourcePath: "/tmp/demo.mov",
        regions: sampleRegions()
    )
    try JSONEncoder().encode(future).write(to: store.documentURL(for: video))
    #expect(store.load(for: video) == nil, "a newer format must not be half-read")
}

@Test("Restored regions are fitted to the video that's actually on disk")
func clampingToDuration() throws {
    let region = MaskRegion(
        rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), start: 2, end: 30, style: .solid)

    let fitted = try #require(region.clamped(toDuration: 10))
    #expect(fitted.start == 2)
    #expect(fitted.end == 10, "end should be pulled back to the new duration")

    // Starts after the video now ends — it could never show, so drop it.
    #expect(region.clamped(toDuration: 1) == nil)
    #expect(region.clamped(toDuration: 0) == nil)

    let untouched = try #require(region.clamped(toDuration: 60))
    #expect(untouched == region)
}
