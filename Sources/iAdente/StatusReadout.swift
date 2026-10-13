import AppKit

@MainActor
enum StatusReadout {
    static let batterySize = NSSize(width: 24, height: 16)
    static let batteryGreen = NSColor(calibratedRed: 0.18, green: 0.84, blue: 0.50, alpha: 1)

    /// Unknown capacity keeps an empty outline instead of suggesting a full
    /// battery. A template image lets the menu bar choose contrasting ink.
    static func batteryImage(percentage: Int?, powerConnected: Bool, useColors: Bool) -> NSImage {
        let color = useColors ? batteryGreen : NSColor.black
        let image = NSImage(size: batterySize)
        image.lockFocus()
        color.setStroke()
        let body = NSBezierPath(roundedRect: NSRect(x: 0.8, y: 2, width: 20.2, height: 12), xRadius: 2.6, yRadius: 2.6)
        body.lineWidth = 1.3
        body.stroke()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 5, width: 1.6, height: 6), xRadius: 0.7, yRadius: 0.7).fill()
        if let percentage, percentage > 0 {
            let width = 16.2 * CGFloat(min(100, percentage)) / 100
            NSBezierPath(roundedRect: NSRect(x: 2.8, y: 4, width: width, height: 8), xRadius: min(1, width / 2), yRadius: 1).fill()
        }
        if powerConnected {
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 13.2, y: 13))
            bolt.line(to: NSPoint(x: 8.4, y: 7))
            bolt.line(to: NSPoint(x: 11, y: 7))
            bolt.line(to: NSPoint(x: 9.8, y: 3))
            bolt.line(to: NSPoint(x: 15.7, y: 9.2))
            bolt.line(to: NSPoint(x: 12.6, y: 9.2))
            bolt.close()
            if useColors {
                NSColor.white.setFill()
                bolt.fill()
            } else {
                // Opaque white would become menu-bar ink in a template, too.
                // Knock out the bolt and retain its outer outline.
                color.setStroke()
                bolt.lineWidth = 1
                bolt.stroke()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                color.setFill()
                bolt.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        image.unlockFocus()
        image.isTemplate = !useColors
        let capacity = percentage.map { "\(min(100, max(0, $0)))%" } ?? "电量未知"
        image.accessibilityDescription = powerConnected ? "电源已连接，\(capacity)" : "电池，\(capacity)"
        return image
    }

    /// A non-template image retains charging green through menu bar vibrancy.
    /// Normal, non-charging text keeps native title contrast.
    static func chargingImage(text: String, percentage: Int?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: batteryGreen]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let textX = batterySize.width + 5
        let size = NSSize(width: ceil(textSize.width) + textX, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        batteryImage(percentage: percentage, powerConnected: true, useColors: true)
            .draw(in: NSRect(x: 0, y: 1, width: batterySize.width, height: batterySize.height))
        string.draw(at: NSPoint(x: textX, y: floor((size.height - textSize.height) / 2)))
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "正在充电，\(text)"
        return image
    }
}
