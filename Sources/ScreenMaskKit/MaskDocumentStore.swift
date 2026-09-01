import CryptoKit
import Foundation

/// The on-disk shape of a video's masks.
///
/// `version` is checked on read so a document written by a newer build is
/// ignored rather than half-understood.
public struct MaskDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Recorded for debugging only; lookup is by hashed path, not by this field.
    public var sourcePath: String
    public var regions: [MaskRegion]

    public init(version: Int = MaskDocument.currentVersion, sourcePath: String, regions: [MaskRegion]) {
        self.version = version
        self.sourcePath = sourcePath
        self.regions = regions
    }
}

/// Remembers each video's masks between launches.
///
/// Documents live in Application Support keyed by a hash of the video's path,
/// rather than as sidecar files, so masking a video never leaves anything behind
/// next to the original. Moving or renaming the video starts it fresh.
public struct MaskDocumentStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/ScreenMask/Masks`
    public static func defaultStore() -> MaskDocumentStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return MaskDocumentStore(
            directory: base.appendingPathComponent("ScreenMask/Masks", isDirectory: true)
        )
    }

    func documentURL(for videoURL: URL) -> URL {
        let path = videoURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }

    /// Returns nil when nothing is stored for this video, and also when the
    /// document is unreadable — a corrupt file shouldn't block opening a video.
    public func load(for videoURL: URL) -> [MaskRegion]? {
        let url = documentURL(for: videoURL)
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(MaskDocument.self, from: data),
              document.version <= MaskDocument.currentVersion
        else { return nil }
        return document.regions
    }

    /// Saving no regions removes the document instead of leaving an empty one.
    public func save(_ regions: [MaskRegion], for videoURL: URL) throws {
        let url = documentURL(for: videoURL)
        guard !regions.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let document = MaskDocument(
            sourcePath: videoURL.standardizedFileURL.path,
            regions: regions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    public func clear(for videoURL: URL) throws {
        try? FileManager.default.removeItem(at: documentURL(for: videoURL))
    }
}

extension MaskRegion {
    /// Fits a restored region to the video actually on disk now, dropping any
    /// that fall past the end — the file may have been replaced with a shorter one.
    public func clamped(toDuration duration: Double) -> MaskRegion? {
        guard duration > 0, start <= duration else { return nil }
        var copy = self
        copy.start = max(0, start)
        copy.end = min(max(end, copy.start), duration)
        return copy
    }
}
