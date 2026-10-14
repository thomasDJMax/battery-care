import AppKit
import SwiftUI

enum BatteryLevelPalette {
    /// Capacity bands follow the reference image, independently of charging.
    /// Missing capacity uses a neutral outline instead of implying a level.
    static func nsColor(for percentage: Int?) -> NSColor {
        guard let percentage else {
            return NSColor(srgbRed: 0.64, green: 0.71, blue: 0.74, alpha: 1)
        }
        let rgb: (Double, Double, Double)
        switch min(100, max(0, percentage)) {
        case 0..<25: rgb = (235, 85, 69)
        case 25..<50: rgb = (243, 224, 152)
        case 50..<75: rgb = (248, 216, 74)
        default: rgb = (104, 206, 103)
        }
        return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
    }

    static func color(for percentage: Int?) -> Color {
        Color(nsColor: nsColor(for: percentage))
    }
}
