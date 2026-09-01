import SwiftUI
import ScreenMaskKit

enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The corner that stays put while this one is dragged.
    func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return Corner.bottomRight.point(in: rect)
        case .topRight: return Corner.bottomLeft.point(in: rect)
        case .bottomLeft: return Corner.topRight.point(in: rect)
        case .bottomRight: return Corner.topLeft.point(in: rect)
        }
    }
}

private enum DragState {
    case creating(anchor: CGPoint, current: CGPoint)
    case moving(id: UUID, original: CGRect, from: CGPoint, current: CGPoint)
    case resizing(id: UUID, anchor: CGPoint, current: CGPoint)
}

private let handleSize: CGFloat = 10
private let minimumSide: CGFloat = 8

/// Draw, select, move and resize mask rectangles directly on the video.
///
/// The parent locks this view to the video's aspect ratio, so `size` is exactly
/// the displayed video rect and normalizing is a plain divide — no letterbox math.
struct RegionOverlay: View {
    @Bindable var model: AppModel
    let size: CGSize

    @State private var drag: DragState?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())

            ForEach(model.regions) { region in
                let rect = viewRect(region.rect)
                let isSelected = model.selection == region.id
                let isActive = region.isActive(at: model.currentTime)

                Rectangle()
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(isActive ? 0.85 : 0.35),
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isActive ? [] : [4, 3])
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                if isSelected {
                    ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, corner in
                        let point = corner.point(in: rect)
                        Rectangle()
                            .fill(Color.white)
                            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                            .frame(width: handleSize, height: handleSize)
                            .offset(x: point.x - handleSize / 2, y: point.y - handleSize / 2)
                            .allowsHitTesting(false)
                    }
                }
            }

            if case .creating(let anchor, let current) = drag {
                let rect = CGRect(anchor: anchor, corner: current)
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drag == nil { begin(at: value.startLocation) }
                    advance(to: value.location)
                }
                .onEnded { value in
                    advance(to: value.location)
                    commit()
                }
        )
    }

    // MARK: - Geometry

    private func viewRect(_ normalized: CGRect) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func normalized(_ rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let clamped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clamped.isNull else { return .zero }
        return CGRect(
            x: clamped.minX / size.width,
            y: clamped.minY / size.height,
            width: clamped.width / size.width,
            height: clamped.height / size.height
        )
    }

    // MARK: - Gesture phases

    /// One gesture handles create/move/resize; the mode is decided by what's
    /// under the initial press, which stays predictable as boxes overlap.
    private func begin(at point: CGPoint) {
        if let selection = model.selection,
           let region = model.regions.first(where: { $0.id == selection }) {
            let rect = viewRect(region.rect)
            for corner in Corner.allCases {
                let hit = CGRect(
                    origin: CGPoint(
                        x: corner.point(in: rect).x - handleSize,
                        y: corner.point(in: rect).y - handleSize
                    ),
                    size: CGSize(width: handleSize * 2, height: handleSize * 2)
                )
                if hit.contains(point) {
                    drag = .resizing(id: selection, anchor: corner.anchor(in: rect), current: point)
                    return
                }
            }
        }

        // Topmost first: later regions are drawn on top.
        if let region = model.regions.reversed().first(where: { viewRect($0.rect).contains(point) }) {
            model.selection = region.id
            drag = .moving(id: region.id, original: viewRect(region.rect), from: point, current: point)
            return
        }

        model.selection = nil
        drag = .creating(anchor: point, current: point)
    }

    private func advance(to point: CGPoint) {
        switch drag {
        case .creating(let anchor, _):
            drag = .creating(anchor: anchor, current: point)
        case .moving(let id, let original, let from, _):
            drag = .moving(id: id, original: original, from: from, current: point)
            let moved = original.offsetBy(dx: point.x - from.x, dy: point.y - from.y)
            model.update(id, force: false) { $0.rect = normalized(clampToBounds(moved)) }
        case .resizing(let id, let anchor, _):
            drag = .resizing(id: id, anchor: anchor, current: point)
            model.update(id, force: false) { $0.rect = normalized(CGRect(anchor: anchor, corner: point)) }
        case nil:
            break
        }
    }

    private func commit() {
        if case .creating(let anchor, let current) = drag {
            let rect = CGRect(anchor: anchor, corner: current)
            if rect.width >= minimumSide, rect.height >= minimumSide {
                model.addRegion(rect: normalized(rect))
            }
        }
        drag = nil
        model.refreshPreview(force: true)
    }

    /// Keeps a dragged box fully on screen rather than letting it clip at an edge.
    private func clampToBounds(_ rect: CGRect) -> CGRect {
        var r = rect
        r.origin.x = min(max(0, r.minX), max(0, size.width - r.width))
        r.origin.y = min(max(0, r.minY), max(0, size.height - r.height))
        return r
    }
}

private extension CGRect {
    init(anchor: CGPoint, corner: CGPoint) {
        self.init(
            x: min(anchor.x, corner.x),
            y: min(anchor.y, corner.y),
            width: abs(corner.x - anchor.x),
            height: abs(corner.y - anchor.y)
        )
    }
}
