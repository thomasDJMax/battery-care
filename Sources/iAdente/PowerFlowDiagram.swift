import SwiftUI

/// Three independent readings: input, system load, and battery charge/discharge.
/// Missing measurements remain missing; no power-balance values are invented.
struct PowerFlowDiagram: View {
    let snapshot: BatterySnapshot

    private var batterySuppliesPower: Bool {
        snapshot.hasBattery && !snapshot.isPluggedIn && !snapshot.isCharging
    }
    private var batteryColor: Color {
        if snapshot.isCharging { return Palette.green }
        if batterySuppliesPower { return Palette.purple }
        return Palette.secondary
    }
    private var batteryState: String {
        if !snapshot.hasBattery { return "未检测到电池" }
        if snapshot.isCharging { return "正在充电" }
        if batterySuppliesPower { return "正在供电" }
        // A power magnitude alone cannot establish direction while connected.
        if let watts = snapshot.batteryPower, abs(watts) > 0.5 { return "电池活动 · 未充电" }
        return (snapshot.percentage ?? 0) >= 100 ? "已充满 · 未充电" : "未充电"
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let nodeWidth = min(160, max(1, (width - 54) / 2))
            let upperY: CGFloat = 37
            let lowerY: CGFloat = 132
            ZStack {
                // The junction supplies the system and branches to the battery.
                Path { path in
                    path.move(to: CGPoint(x: nodeWidth, y: upperY))
                    path.addLine(to: CGPoint(x: width / 2, y: upperY))
                }
                .stroke(snapshot.isPluggedIn ? Palette.green.opacity(0.7) : Palette.line,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                Path { path in
                    path.move(to: CGPoint(x: width / 2, y: upperY))
                    path.addLine(to: CGPoint(x: width - nodeWidth, y: upperY))
                }
                .stroke(snapshot.isPluggedIn || batterySuppliesPower ? Palette.green.opacity(0.7) : Palette.line,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                if snapshot.isPluggedIn || batterySuppliesPower {
                    flowArrow("chevron.right", color: Palette.green)
                        .position(x: width - nodeWidth - 6, y: upperY)
                }

                Path { path in
                    path.move(to: CGPoint(x: width / 2, y: upperY))
                    path.addLine(to: CGPoint(x: width / 2, y: lowerY - 37))
                }
                .stroke(batteryColor.opacity(snapshot.isCharging || batterySuppliesPower ? 0.9 : 0.3),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

                Circle().fill(snapshot.isPluggedIn ? Palette.green : batteryColor)
                    .frame(width: 4, height: 4).position(x: width / 2, y: upperY)

                if snapshot.isCharging {
                    flowArrow("chevron.down", color: Palette.green)
                        .position(x: width / 2, y: lowerY - 41)
                } else if batterySuppliesPower {
                    flowArrow("chevron.up", color: Palette.purple)
                        .position(x: width / 2, y: upperY + 7)
                }

                powerNode("powerplug.fill", title: "适配器", value: snapshot.adapterPower,
                          state: snapshot.isPluggedIn ? "已接通电源" : "未连接", color: snapshot.isPluggedIn ? Palette.green : Palette.secondary,
                          width: nodeWidth, connected: snapshot.isPluggedIn)
                    .position(x: nodeWidth / 2, y: upperY)
                powerNode("laptopcomputer", title: "系统使用", value: snapshot.systemPower,
                          state: snapshot.systemPowerSource == .batteryDischargeEstimate ? "放电功率估算" : "实时负载", color: Palette.green, width: nodeWidth)
                    .position(x: width - nodeWidth / 2, y: upperY)
                powerNode(snapshot.isCharging ? "battery.100percent.bolt" : "battery.100percent", title: "电池",
                          value: snapshot.batteryPower.map { abs($0) }, state: batteryState, color: batteryColor,
                          width: min(160, width), connected: snapshot.hasBattery)
                    .position(x: width / 2, y: lowerY)
            }
            .frame(width: width, height: 174)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("适配器、系统使用和电池三路功率")
    }

    private func flowArrow(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func powerNode(_ symbol: String, title: String, value: Double?, state: String, color: Color,
                           width: CGFloat, connected: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
            }
            Text(connected ? value.wattsText : "— W")
                .font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(connected && value != nil ? color : Palette.secondary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(state).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).frame(width: width, height: 74, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.line, lineWidth: 0.8))
        .help(connected && value == nil ? "系统暂未提供这一路的功率读数" : "\(title) · \(state)")
        .accessibilityElement(children: .combine)
    }
}
