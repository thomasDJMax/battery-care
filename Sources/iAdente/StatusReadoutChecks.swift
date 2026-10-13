import AppKit

@MainActor
func runStatusReadoutChecks() {
    func inkPixels(_ image: NSImage) -> Int {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { preconditionFailure("Missing battery raster") }
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 }
            }
        }
        return count
    }
    let empty = StatusReadout.batteryImage(percentage: 0, powerConnected: false, useColors: true)
    let quarter = StatusReadout.batteryImage(percentage: 25, powerConnected: false, useColors: true)
    let full = StatusReadout.batteryImage(percentage: 100, powerConnected: false, useColors: true)
    precondition(inkPixels(empty) < inkPixels(quarter) && inkPixels(quarter) < inkPixels(full), "The icon must show increasing actual capacity")
    precondition(inkPixels(StatusReadout.batteryImage(percentage: nil, powerConnected: false, useColors: true)) == inkPixels(empty), "Unknown capacity cannot suggest full charge")
    precondition(inkPixels(StatusReadout.batteryImage(percentage: -1, powerConnected: false, useColors: true)) == inkPixels(empty))
    precondition(inkPixels(StatusReadout.batteryImage(percentage: 101, powerConnected: false, useColors: true)) == inkPixels(full))
    precondition(!quarter.isTemplate)
    precondition(StatusReadout.batteryImage(percentage: 25, powerConnected: true, useColors: false).isTemplate)
    precondition(!StatusReadout.chargingImage(text: "25% · 12.0W", percentage: 25).isTemplate)
    print("Status icon checks passed: actual capacity, unknown/invalid bounds, green and native contrast.")
}

@MainActor
func renderStatusReadoutViews(to directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let image = NSImage(size: NSSize(width: 560, height: 220))
    image.lockFocus()
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 560, height: 220).fill()
    let percentages: [Int?] = [nil, 0, 25, 50, 75, 100]
    for (index, percentage) in percentages.enumerated() {
        let x = CGFloat(index) * 90 + 10
        let label = percentage.map { "\($0)%" } ?? "未知"
        (label as NSString).draw(at: NSPoint(x: x, y: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white])
        StatusReadout.batteryImage(percentage: percentage, powerConnected: false, useColors: true)
            .draw(in: NSRect(x: x, y: 125, width: 72, height: 48))
        StatusReadout.batteryImage(percentage: percentage, powerConnected: true, useColors: true)
            .draw(in: NSRect(x: x, y: 65, width: 72, height: 48))
        // Draw the template's alpha on a light row to check its bolt knockout.
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        NSRect(x: x, y: 5, width: 72, height: 48).fill()
        StatusReadout.batteryImage(percentage: percentage, powerConnected: true, useColors: false)
            .draw(in: NSRect(x: x, y: 5, width: 72, height: 48))
    }
    image.unlockFocus()
    guard let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data),
          let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "BatteryCare.StatusRender", code: 1) }
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("status-capacity-matrix.png"))
    print("Rendered status icons: unknown, 0, 25, 50, 75 and 100 percent, with color and template contrast.")
}
