import AppKit

@MainActor
enum StatusReadout {
    static let batterySize = NSSize(width: 24, height: 16)
    static let batteryGreen = NSColor(calibratedRed: 0.18, green: 0.84, blue: 0.50, alpha: 1)

    /// The bolt is drawn inside the battery body so it stays recognizable at
    /// menu bar size, including when the battery is full on external power.
    static func powerConnectedBattery(color: NSColor) -> NSImage {
        let image = NSImage(size: batterySize)
        image.lockFocus()
        // Draw the original vector geometry at a larger logical size, keeping
        // the battery outline and bolt crisp on Retina displays.
        NSGraphicsContext.saveGraphicsState()
        let scale = NSAffineTransform()
        scale.scale(by: 4.0 / 3.0)
        scale.concat()
        color.setStroke()
        let body = NSBezierPath(roundedRect: NSRect(x: 0.6, y: 1.1, width: 15.1, height: 9.8), xRadius: 2, yRadius: 2)
        body.lineWidth = 1.1
        body.stroke()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2.1, y: 2.5, width: 12.1, height: 7), xRadius: 0.8, yRadius: 0.8).fill()
        NSBezierPath(roundedRect: NSRect(x: 16.3, y: 4, width: 1.5, height: 4), xRadius: 0.6, yRadius: 0.6).fill()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: 9.3, y: 10.0))
        bolt.line(to: NSPoint(x: 5.8, y: 5.4))
        bolt.line(to: NSPoint(x: 8.0, y: 5.4))
        bolt.line(to: NSPoint(x: 6.8, y: 2.0))
        bolt.line(to: NSPoint(x: 11.1, y: 6.7))
        bolt.line(to: NSPoint(x: 8.9, y: 6.7))
        bolt.close()
        NSColor.white.setFill()
        bolt.fill()
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "电池已连接电源，内部闪电标志"
        return image
    }

    /// A non-template image retains the requested charging green through menu
    /// bar vibrancy. The normal readout continues to use native title contrast.
    static func chargingImage(text: String) -> NSImage {
        let green = batteryGreen
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: green]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let textX = batterySize.width + 5
        let size = NSSize(width: ceil(textSize.width) + textX, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let battery = powerConnectedBattery(color: green)
        battery.draw(in: NSRect(x: 0, y: 1, width: batterySize.width, height: batterySize.height))
        string.draw(at: NSPoint(x: textX, y: floor((size.height - textSize.height) / 2)))
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "正在充电，\(text)"
        return image
    }
}
