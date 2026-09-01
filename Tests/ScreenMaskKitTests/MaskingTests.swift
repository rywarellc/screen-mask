import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import ScreenMaskKit

// MARK: - Helpers

private let ciContext = CIContext(options: [.useSoftwareRenderer: true])
private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// Reads one pixel in Core Image space (origin bottom-left).
private func sample(_ image: CIImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
    var px = [UInt8](repeating: 0, count: 4)
    ciContext.render(
        image,
        toBitmap: &px,
        rowBytes: 4,
        bounds: CGRect(x: x, y: y, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: srgb
    )
    return (Double(px[0]), Double(px[1]), Double(px[2]))
}

private func solid(_ color: CIColor, _ rect: CGRect) -> CIImage {
    CIImage(color: color).cropped(to: rect)
}

/// 400x200, one flat colour per quadrant, laid out in Core Image coordinates so
/// the expected result of a top-left-origin mask is unambiguous.
private func quadrantImage() -> CIImage {
    let topLeft = solid(CIColor(red: 1, green: 0, blue: 0), CGRect(x: 0, y: 100, width: 200, height: 100))
    let topRight = solid(CIColor(red: 0, green: 1, blue: 0), CGRect(x: 200, y: 100, width: 200, height: 100))
    let bottomLeft = solid(CIColor(red: 0, green: 0, blue: 1), CGRect(x: 0, y: 0, width: 200, height: 100))
    let bottomRight = solid(CIColor(red: 1, green: 1, blue: 1), CGRect(x: 200, y: 0, width: 200, height: 100))
    return topLeft
        .composited(over: topRight)
        .composited(over: bottomLeft)
        .composited(over: bottomRight)
        .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
}

private func isDark(_ c: (r: Double, g: Double, b: Double)) -> Bool {
    c.r < 40 && c.g < 40 && c.b < 40
}

// MARK: - Coordinate mapping

@Test("Normalized top-left rects map to bottom-left pixel space")
func pixelRectFlipsVertically() throws {
    let extent = CGRect(x: 0, y: 0, width: 400, height: 200)

    // Top-left quadrant of the picture sits at high y in Core Image space.
    let topLeft = try #require(MaskCompositor.pixelRect(
        CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: extent))
    #expect(topLeft == CGRect(x: 0, y: 100, width: 200, height: 100))

    let bottomRight = try #require(MaskCompositor.pixelRect(
        CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), in: extent))
    #expect(bottomRight == CGRect(x: 200, y: 0, width: 200, height: 100))

    // A band across the middle stays centred after the flip.
    let middle = try #require(MaskCompositor.pixelRect(
        CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), in: extent))
    #expect(middle == CGRect(x: 100, y: 50, width: 200, height: 100))
}

@Test("Degenerate rects are rejected rather than producing empty draws")
func pixelRectRejectsDegenerateInput() {
    let extent = CGRect(x: 0, y: 0, width: 400, height: 200)
    #expect(MaskCompositor.pixelRect(CGRect(x: 0, y: 0, width: 0, height: 0.5), in: extent) == nil)
    #expect(MaskCompositor.pixelRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: .zero) == nil)
}

// MARK: - Compositing

@Test("A solid mask covers the picture's top-left, not the bottom-left")
func solidMaskLandsOnTheCorrectQuadrant() {
    let region = MaskRegion(
        rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
        start: 0,
        end: 10,
        style: .solid(color: .black)
    )
    let output = MaskCompositor.apply(regions: [region], to: quadrantImage(), at: 5)

    #expect(isDark(sample(output, x: 100, y: 150)), "top-left should be masked")

    let bottomLeft = sample(output, x: 100, y: 50)
    #expect(bottomLeft.b > 200 && bottomLeft.r < 40, "bottom-left should still be blue")

    let topRight = sample(output, x: 300, y: 150)
    #expect(topRight.g > 200 && topRight.r < 40, "top-right should still be green")
}

@Test("Masks only apply inside their own time range")
func masksRespectTimeRange() {
    let region = MaskRegion(
        rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
        start: 2,
        end: 4,
        style: .solid(color: .black)
    )
    let source = quadrantImage()

    for t in [0.0, 1.9, 4.1, 9.0] {
        let out = MaskCompositor.apply(regions: [region], to: source, at: t)
        let c = sample(out, x: 100, y: 150)
        #expect(c.r > 200, "expected unmasked red at t=\(t)")
    }

    for t in [2.0, 3.0, 4.0] {
        let out = MaskCompositor.apply(regions: [region], to: source, at: t)
        #expect(isDark(sample(out, x: 100, y: 150)), "expected mask at t=\(t)")
    }
}

@Test("Several regions with different windows coexist")
func multipleRegionsWithDistinctWindows() {
    let early = MaskRegion(
        rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), start: 0, end: 2, style: .solid(color: .black))
    let late = MaskRegion(
        rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), start: 8, end: 10, style: .solid(color: .black))
    let source = quadrantImage()

    let atOne = MaskCompositor.apply(regions: [early, late], to: source, at: 1)
    #expect(isDark(sample(atOne, x: 100, y: 150)), "early mask active")
    #expect(sample(atOne, x: 300, y: 150).g > 200, "late mask not yet active")

    let atNine = MaskCompositor.apply(regions: [early, late], to: source, at: 9)
    #expect(sample(atNine, x: 100, y: 150).r > 200, "early mask expired")
    #expect(isDark(sample(atNine, x: 300, y: 150)), "late mask active")

    let atFive = MaskCompositor.apply(regions: [early, late], to: source, at: 5)
    #expect(sample(atFive, x: 100, y: 150).r > 200)
    #expect(sample(atFive, x: 300, y: 150).g > 200)
}

@Test("Pixelation destroys fine detail inside the region and nowhere else")
func pixelationFlattensDetailOnlyInsideItsRegion() throws {
    // A 2px checkerboard is the cleanest way to measure lost detail: count how
    // often colour changes along a scanline before and after masking.
    let checker = try #require(CIFilter(name: "CICheckerboardGenerator", parameters: [
        kCIInputCenterKey: CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 1, green: 0, blue: 0),
        "inputColor1": CIColor(red: 0, green: 1, blue: 0),
        "inputWidth": 2.0,
        "inputSharpness": 1.0,
    ])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200)))

    let region = MaskRegion(
        rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        start: 0,
        end: 10,
        style: .pixelate(scale: 0.4)
    )
    let output = MaskCompositor.apply(regions: [region], to: checker, at: 1)

    // y = 100 runs through the region (Core Image y 50...150); y = 10 misses it.
    let insideBefore = transitions(in: checker, y: 100)
    let insideAfter = transitions(in: output, y: 100)
    let outsideAfter = transitions(in: output, y: 10)

    #expect(insideBefore > 15, "checkerboard should start with lots of detail")
    #expect(insideAfter < insideBefore / 3, "mosaic should flatten detail, got \(insideAfter)")
    #expect(outsideAfter > 15, "detail outside the region must survive, got \(outsideAfter)")
}

/// Colour changes along a horizontal scanline, sampled inside the region's x range.
private func transitions(in image: CIImage, y: Int) -> Int {
    var count = 0
    var previous: (r: Double, g: Double, b: Double)?
    for x in stride(from: 110, to: 190, by: 1) {
        let c = sample(image, x: x, y: y)
        if let previous, abs(previous.r - c.r) > 40 || abs(previous.g - c.g) > 40 {
            count += 1
        }
        previous = c
    }
    return count
}
