import AppKit
import ScreenMaskKit
import SwiftUI

extension MaskColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// Converted through sRGB explicitly. A Color from the system picker can be
    /// in any space, and reading its components without converting first gives
    /// values that don't match what was on screen.
    init(_ color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent)
        )
    }
}
