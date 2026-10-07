import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(\.staticRendering) private var staticRendering
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var charge: NativeChargeController
    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator; settings = coordinator.settings
        monitor = coordinator.monitor; charge = coordinator.charge
    }
    var body: some View {
        VStack(spacing: 0) {
            if staticRendering {
                GeometryReader { geometry in
                    DashboardContent(coordinator: coordinator, compact: true)
                        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .clipped()
                }
            } else {
                ScrollView {
                    DashboardContent(coordinator: coordinator, compact: true)
                        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)
                }.scrollIndicators(.hidden)
            }
            footer
        }.frame(width: 410)
            .background(AppBackground(settings: settings))
            .preferredColorScheme(.dark)

    }
    private var footer: some View {
        HStack(spacing: 9) {
            BrandText(size: 17)
            Text("实时电池养护").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text.opacity(0.80))
            Spacer()
            footerButton("arrow.clockwise", label: "刷新电池读数") { monitor.refresh(); coordinator.refreshChargeState() }
            footerButton("gearshape.fill", label: "打开设置") { coordinator.openSettings() }
            footerButton("power", label: "退出 \(AppIdentity.displayName)") { NSApplication.shared.terminate(nil) }
        }.padding(.horizontal, 14).frame(height: 40)
            .background(Color.black.opacity(0.16))
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
    private func footerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.text).frame(width: 26, height: 23)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct DashboardContent: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var charge: NativeChargeController
    let compact: Bool
    @State private var showBatteryDetails = false
    @State private var showControlInfo = false
    @State private var chargeDraft: Double
    init(coordinator: AppCoordinator, compact: Bool) {
        self.coordinator = coordinator; self.compact = compact
        settings = coordinator.settings; monitor = coordinator.monitor; charge = coordinator.charge
        _chargeDraft = State(initialValue: Double(ChargeLimitOptions(coordinator.charge.availableLimits).nearest(to: coordinator.settings.limit) ?? coordinator.charge.currentLimit ?? 100))
    }
    private var snapshot: BatterySnapshot { monitor.snapshot }
    var body: some View {
        VStack(spacing: 10) {
            statusHeader
            chargeCard
            statsPanel
            powerPanel
            quickCarePanel
            appsPanel
            protectionPanel
            HStack(spacing: 9) {
                navigationButton("info.circle", "电池详情") { showBatteryDetails = true }
                navigationButton("slider.horizontal.3", "充电设置") { coordinator.openSettings(.charging) }
            }
        }.frame(maxWidth: compact ? 382 : 700)
            .sheet(isPresented: $showBatteryDetails) { BatteryDetailsView(coordinator: coordinator) }
            .sheet(isPresented: $showControlInfo) { ControlInfoView(coordinator: coordinator) }
            .onChange(of: settings.limit) { chargeDraft = $0 }
            .onChange(of: charge.currentLimit) { if let limit = $0 { chargeDraft = Double(limit) } }
            .onReceive(NotificationCenter.default.publisher(for: .iadenteDashboardClosed)) { _ in
                chargeDraft = Double(charge.currentLimit ?? Int(settings.limit))
                if compact { showBatteryDetails = false; showControlInfo = false }
            }
    }
    private var statusHeader: some View {
        VStack(spacing: 13) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.hasBattery ? (snapshot.isPluggedIn ? "电源已连接" : "电池供电中") : "未检测到电池")
                        .font(.system(size: 21, weight: .heavy)).foregroundStyle(Palette.text)
                    Text(snapshot.statusText).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.text.opacity(0.8))
                }
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Image(systemName: "thermometer.medium").font(.system(size: 14))
                    Text(snapshot.temperature.map { String(format: "%.1f°C", $0) } ?? "—°C")
                        .font(.system(size: 13, weight: .bold)).monospacedDigit()
                }.foregroundStyle(Palette.green).help(snapshot.temperature != nil ? "电池实时温度" : "系统未提供有效温度时显示 —")
                Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 25)
                Text(snapshot.percentage.map { "\($0)%" } ?? "—%")
                    .font(.system(size: 29, weight: .heavy)).monospacedDigit().foregroundStyle(Palette.text)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
        }.padding(.bottom, 1)
    }
    private var chargeCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: snapshot.isPluggedIn ? "powerplug.fill" : "battery.100percent")
                    .font(.system(size: 23, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 39, height: 39)
                    .background(Palette.green.opacity(0.17), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.chargeStatus).font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.text)
                    Text(adapterText).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(snapshot.percentage.map { "\($0)%" } ?? "—%")
                    .font(.system(size: 24, weight: .heavy)).foregroundStyle(Palette.green).monospacedDigit()
                Text("实时电量").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                Spacer()
                Text("选择上限").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.secondary)
                Text("\(coordinator.temporaryFull ? 100 : Int(chargeDraft))%").font(.system(size: 22, weight: .heavy)).foregroundStyle(Palette.green).monospacedDigit()
            }
            ChargeLimitControl(value: Binding(get: { coordinator.temporaryFull ? 100 : chargeDraft },
                                              set: { if !coordinator.temporaryFull { chargeDraft = $0 } }),
                               limits: charge.availableLimits, isEnabled: coordinator.canAdjustChargeLimit) { limit in
                coordinator.applySelectedLimit(limit)
                if charge.hasKnownState, let actual = charge.currentLimit { chargeDraft = Double(actual) }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(charge.hasKnownState ? Palette.green : Palette.orange).frame(width: 6, height: 6)
                    Text("系统当前：\(coordinator.systemChargeLimitText)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.text)
                }
                if coordinator.temporaryFull {
                    Text(coordinator.capCaption)
                } else if let message = charge.message {
                    Text(message)
                }
                if !snapshot.isPluggedIn { Text("接通电源后按系统上限管理充电") }
            }
            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14)
            .background(LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.16), Color(red: 0.075, green: 0.085, blue: 0.09)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [.white.opacity(0.13), Palette.green.opacity(0.22)], startPoint: .leading, endPoint: .trailing), lineWidth: 1))
    }
    private var adapterText: String {
        guard snapshot.isPluggedIn else { return "适配器未连接" }
        if let volts = snapshot.adapterVoltage, let amps = snapshot.adapterAmperage { return String(format: "适配器 %.2fV @ %.2fA", volts, amps) }
        return "已连接电源适配器"
    }
    private var statsPanel: some View {
        Panel {
            HStack(spacing: 0) {
                statistic(snapshot.health.map { "\($0)%" } ?? "—", label: "电池健康", color: Palette.green)
                    .help("按最大容量与设计容量估算")
                Rectangle().fill(Palette.line).frame(width: 1, height: 35)
                statistic(snapshot.cycles.map { "\($0)" } ?? "—", label: "循环次数", color: Palette.purple)
                Rectangle().fill(Palette.line).frame(width: 1, height: 35)
                statistic(remainingText, label: "剩余时间", color: Palette.orange, small: true)
            }
        }
    }
    private var remainingText: String {
        if snapshot.isPluggedIn && !snapshot.isCharging { return "未在充电" }
        guard let minutes = snapshot.timeRemainingMinutes, minutes > 0 else { return "正在估算" }
        return minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes)分钟"
    }
    private func statistic(_ value: String, label: String, color: Color, small: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: small ? 13 : 18, weight: .bold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.text.opacity(0.84))
        }.frame(maxWidth: .infinity)
    }
    private var powerPanel: some View {
        Panel {
            VStack(spacing: 12) {
                panelTitle("point.3.connected.trianglepath.dotted", "实时功率分流", detail: !snapshot.hasBattery ? "未检测到电池" : (snapshot.isPluggedIn ? "电源适配器" : "电池供电"))
                PowerFlowDiagram(snapshot: snapshot).frame(height: 174)
            }
        }
    }
    private var appsPanel: some View {
        Panel {
            VStack(spacing: 12) {
                panelTitle("waveform.path.ecg", "当前耗电 App", detail: "CPU 使用率参考")
                if monitor.apps.isEmpty {
                    Text("正在读取应用活动…").font(.system(size: 12)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, minHeight: 65)
                } else {
                    ForEach(Array(monitor.apps.prefix(3).enumerated()), id: \.element.id) { index, app in
                        AppUsageRow(app: app, rank: index + 1, maxCPU: max(1, monitor.apps.map(\.cpuPercent).max() ?? 1))
                    }
                }
            }
        }
    }
    private var quickCarePanel: some View {
        QuickCareCard(state: coordinator.quickCareState, feedback: coordinator.banner,
                      onPreset: coordinator.applyQuickLimit,
                      onTemporary: {
                          if coordinator.temporaryFull { coordinator.cancelTemporaryFull() }
                          else { coordinator.startTemporaryFull() }
                      },
                      onDefault: coordinator.restoreSystemManagement,
                      onSystemSettings: coordinator.openSystemBattery,
                      onDismissFeedback: { coordinator.banner = nil })
    }
    private var protectionPanel: some View {
        TimelineView(.periodic(from: Date(), by: 5)) { context in
            ProtectionCard(state: coordinator.protectionState.at(context.date),
                           reminderEnabled: Binding(get: { settings.highTemperatureReminder },
                                                    set: { coordinator.setHighTemperatureReminder($0) }),
                           onReminderSettings: { coordinator.openSettings(.automation) },
                           onChargeSettings: { coordinator.openSettings(.charging) },
                           onNotificationSettings: coordinator.openSystemNotifications)
        }
    }
    private func panelTitle(_ symbol: String, _ title: String, detail: String, detailColor: Color = Palette.secondary) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.text)
            Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.text)
            Spacer(minLength: 4)
            Text(detail).font(.system(size: 10, weight: .semibold)).foregroundStyle(detailColor)
        }
    }
    private func navigationButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }.font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.text).padding(.horizontal, 12).frame(height: 35)
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.14), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

struct AppUsageRow: View {
    let app: AppUsage
    let rank: Int
    let maxCPU: Double
    private var color: Color { [Palette.orange, Palette.blue, Palette.purple][min(2, rank - 1)] }
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.fill").resizable().foregroundStyle(Palette.text) }
            }.frame(width: 24, height: 24)
            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    Text("\(rank)").font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                    Text(app.name).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f%%", app.cpuPercent)).font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.text.opacity(0.8)).monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(color).frame(width: max(2, geometry.size.width * min(1, app.cpuPercent / maxCPU)))
                    }
                }.frame(height: 3)
            }
        }
    }
}

struct ChargeSlider: View {
    @Binding var value: Double
    let limits: [Int]
    let onCommit: (Int) -> Void
    private var options: ChargeLimitOptions { ChargeLimitOptions(limits) }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let range = options.range
            let selected = min(range.upperBound, max(range.lowerBound, value))
            let offset = CGFloat((selected - range.lowerBound) / (range.upperBound - range.lowerBound)) * max(0, width - 16)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.gradient).frame(height: 10).shadow(color: Palette.green.opacity(0.25), radius: 8)
                HStack(spacing: 0) {
                    ForEach(0..<11) { _ in Spacer(); Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 5) }
                    Spacer()
                }
                Capsule().fill(.white.opacity(0.75)).frame(width: 3, height: 20).offset(x: offset + 6.5)
                Circle().fill(Color.white).frame(width: 13, height: 13).overlay(Circle().stroke(Palette.green.opacity(0.65), lineWidth: 2.5)).offset(x: offset + 1.5)
            }.frame(height: 20).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let percent = range.lowerBound + min(1, max(0, (gesture.location.x - 8) / max(1, width - 16))) * (range.upperBound - range.lowerBound)
                    if let limit = options.nearest(to: percent) { value = Double(limit) }
                }.onEnded { gesture in
                    let percent = range.lowerBound + min(1, max(0, (gesture.location.x - 8) / max(1, width - 16))) * (range.upperBound - range.lowerBound)
                    if let limit = options.nearest(to: percent) { value = Double(limit); onCommit(limit) }
                })
                .accessibilityElement().accessibilityLabel("充电上限").accessibilityValue("\(Int(value))%")
                .accessibilityAdjustableAction { direction in
                    let next: Int?
                    switch direction {
                    case .increment: next = options.adjacent(to: value, increasing: true)
                    case .decrement: next = options.adjacent(to: value, increasing: false)
                    default: next = nil
                    }
                    if let next { value = Double(next); onCommit(next) }
                }
        }.frame(height: 20)
    }
}

struct BatteryDetailsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var monitor: BatteryMonitor
    @Environment(\.dismiss) private var dismiss
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; monitor = coordinator.monitor }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("电池详情").font(.system(size: 20, weight: .bold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            let snapshot = monitor.snapshot
            detail("当前状态", snapshot.statusText)
            detail("当前电量", snapshot.percentage.map { "\($0)%" } ?? "未提供")
            detail("电池健康（容量估算）", snapshot.health.map { "\($0)%" } ?? "未提供")
            detail("循环次数", snapshot.cycles.map(String.init) ?? "未提供")
            detail("当前容量", snapshot.currentCapacity.map { "\($0) mAh" } ?? "未提供")
            detail("满充容量", snapshot.maxCapacity.map { "\($0) mAh" } ?? "未提供")
            detail("设计容量", snapshot.designCapacity.map { "\($0) mAh" } ?? "未提供")
            detail("电池电压", snapshot.batteryVoltage.map { String(format: "%.2f V", $0) } ?? "未提供")
            detail("电池温度", snapshot.temperature.map { String(format: "%.1f°C", $0) } ?? "硬件未提供读数")
            detail("系统实时功率", snapshot.systemPower.wattsText)
            detail("更新时间", snapshot.updatedAt.formatted(date: .omitted, time: .standard))
            Text("电池健康由容量数据估算。功率字段取决于机型；系统未提供的读数显示为空。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }.padding(24).frame(width: 420).foregroundStyle(Palette.text).background(Color(red: 0.19, green: 0.19, blue: 0.19)).preferredColorScheme(.dark)
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Palette.secondary); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 12))
    }
}

struct ControlInfoView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconTile(symbol: "shield.lefthalf.filled", color: Palette.green, size: 40)
            Text("这台 Mac 的充电控制").font(.system(size: 20, weight: .bold))
            Text(coordinator.charge.isSupported ? "系统可用上限：\(ChargeLimitOptions(coordinator.charge.availableLimits).caption)。拖动滑块后松手，或点击加减按钮，即可应用到 macOS。系统优化充电可能延后充满。" : "这台 Mac 未提供兼容的程序内充电上限接口，请在系统电池设置中管理充电。")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("当前 macOS 限制第三方直接暂停充电、强制使用电池和睡眠暂停。高温保护与容量校准由系统维护。")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                SmallButton(title: "系统电池设置", symbol: "arrow.up.forward.square") { coordinator.openSystemBattery() }
                Spacer()
                SmallButton(title: "完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 380).foregroundStyle(Palette.text).background(Color(red: 0.19, green: 0.19, blue: 0.19)).preferredColorScheme(.dark)
    }
}
