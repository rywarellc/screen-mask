import Foundation
import CoreGraphics

/// How a region is obscured.
public enum MaskStyle: Equatable, Hashable, Sendable {
    /// Mosaic. `scale` is the block size as a fraction of the region's shorter side.
    case pixelate(scale: Double)
    /// Opaque fill. Not recoverable — use this for anything you actually publish.
    case solid

    public var label: String {
        switch self {
        case .pixelate: return "Pixelate"
        case .solid: return "Solid"
        }
    }
}

/// Written to disk by hand rather than by synthesis: the persisted shape stays
/// readable and stable even if cases are added later.
extension MaskStyle: Codable {
    private enum Kind: String, Codable { case pixelate, solid }
    private enum CodingKeys: String, CodingKey { case kind, scale }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid:
            try container.encode(Kind.solid, forKey: .kind)
        case .pixelate(let scale):
            try container.encode(Kind.pixelate, forKey: .kind)
            try container.encode(scale, forKey: .scale)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .solid:
            self = .solid
        case .pixelate:
            self = .pixelate(scale: try container.decodeIfPresent(Double.self, forKey: .scale) ?? 0.10)
        }
    }
}

/// A rectangle that hides part of the frame for a slice of the timeline.
///
/// `rect` is normalized (0...1) against the video's own pixel extent with a
/// top-left origin, so it survives window resizing and never depends on the
/// preview's scale.
public struct MaskRegion: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var rect: CGRect
    public var start: Double
    public var end: Double
    public var style: MaskStyle
    public var name: String

    public init(
        id: UUID = UUID(),
        rect: CGRect,
        start: Double,
        end: Double,
        style: MaskStyle = .pixelate(scale: 0.10),
        name: String = "Mask"
    ) {
        self.id = id
        self.rect = rect
        self.start = start
        self.end = end
        self.style = style
        self.name = name
    }

    public func isActive(at t: Double) -> Bool {
        t >= start && t <= end
    }
}

/// Regions shared between the UI and the Core Image handler.
///
/// The composition's frame handler runs off the main thread on every frame, so
/// it can't touch SwiftUI state directly. Funnelling reads through a lock lets
/// the video composition be built exactly once: dragging a box mutates this
/// store and the preview updates on the next frame, with no recomposition.
public final class RegionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MaskRegion] = []

    public init() {}

    public var regions: [MaskRegion] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
