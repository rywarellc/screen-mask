import CoreImage
import Foundation
import Testing

@testable import ScreenMaskKit

private let context = CIContext(options: [.useSoftwareRenderer: true])

/// Same four-quadrant fixture as the compositing tests, laid out in Core Image
/// space so a top-left-origin sample has an unambiguous expected answer.
private func quadrantImage() -> CIImage {
    func fill(_ color: CIColor, _ rect: CGRect) -> CIImage {
        CIImage(color: color).cropped(to: rect)
    }
    return fill(CIColor(red: 1, green: 0, blue: 0), CGRect(x: 0, y: 100, width: 200, height: 100))
        .composited(over: fill(CIColor(red: 0, green: 1, blue: 0), CGRect(x: 200, y: 100, width: 200, height: 100)))
        .composited(over: fill(CIColor(red: 0, green: 0, blue: 1), CGRect(x: 0, y: 0, width: 200, height: 100)))
        .composited(over: fill(CIColor(red: 1, green: 1, blue: 1), CGRect(x: 200, y: 0, width: 200, height: 100)))
        .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
}

private func isNear(_ color: MaskColor, _ r: Double, _ g: Double, _ b: Double) -> Bool {
    abs(color.red - r) < 0.08 && abs(color.green - g) < 0.08 && abs(color.blue - b) < 0.08
}

@Test("Sampling uses the same top-left origin the UI draws in")
func samplingMatchesTheUIsCoordinateSpace() throws {
    let image = quadrantImage()

    // Top-left of the picture is red; if the vertical flip were wrong this
    // would come back blue, which is the whole point of the test.
    let topLeft = try #require(
        MaskCompositor.color(from: image, atNormalized: CGPoint(x: 0.25, y: 0.25), context: context))
    #expect(isNear(topLeft, 1, 0, 0), "expected red, got \(topLeft)")

    let bottomLeft = try #require(
        MaskCompositor.color(from: image, atNormalized: CGPoint(x: 0.25, y: 0.75), context: context))
    #expect(isNear(bottomLeft, 0, 0, 1), "expected blue, got \(bottomLeft)")

    let topRight = try #require(
        MaskCompositor.color(from: image, atNormalized: CGPoint(x: 0.75, y: 0.25), context: context))
    #expect(isNear(topRight, 0, 1, 0), "expected green, got \(topRight)")

    let bottomRight = try #require(
        MaskCompositor.color(from: image, atNormalized: CGPoint(x: 0.75, y: 0.75), context: context))
    #expect(isNear(bottomRight, 1, 1, 1), "expected white, got \(bottomRight)")
}

@Test("Points on the edge are clamped rather than rejected")
func samplingClampsToTheFrame() {
    let image = quadrantImage()
    #expect(MaskCompositor.color(from: image, atNormalized: CGPoint(x: 0, y: 0), context: context) != nil)
    #expect(MaskCompositor.color(from: image, atNormalized: CGPoint(x: 1, y: 1), context: context) != nil)
    #expect(MaskCompositor.color(from: image, atNormalized: CGPoint(x: -0.5, y: 2), context: context) != nil)
}

@Test("A sampled colour paints back as the same colour")
func sampledColourSurvivesTheRoundTrip() throws {
    let image = quadrantImage()
    // Sample the green quadrant, then fill the red one with it.
    let sampled = try #require(
        MaskCompositor.color(from: image, atNormalized: CGPoint(x: 0.75, y: 0.25), context: context))

    let region = MaskRegion(
        rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
        start: 0, end: 10,
        style: .solid(color: sampled)
    )
    let output = MaskCompositor.apply(regions: [region], to: image, at: 1)

    let painted = try #require(
        MaskCompositor.color(from: output, atNormalized: CGPoint(x: 0.25, y: 0.25), context: context))
    #expect(isNear(painted, sampled.red, sampled.green, sampled.blue),
            "sampled \(sampled) but painted \(painted)")
}

@Test("Solid masks paint the colour they were given, not always black")
func solidHonoursItsColour() throws {
    let orange = MaskColor(red: 1, green: 0.5, blue: 0)
    let region = MaskRegion(
        rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
        start: 0, end: 10,
        style: .solid(color: orange)
    )
    let output = MaskCompositor.apply(regions: [region], to: quadrantImage(), at: 1)
    let painted = try #require(
        MaskCompositor.color(from: output, atNormalized: CGPoint(x: 0.25, y: 0.25), context: context))
    #expect(isNear(painted, 1, 0.5, 0), "expected orange, got \(painted)")
}

@Test("Colour components are clamped to a valid range")
func colourComponentsAreClamped() {
    let color = MaskColor(red: 5, green: -2, blue: 0.5)
    #expect(color.red == 1)
    #expect(color.green == 0)
    #expect(color.blue == 0.5)
}
