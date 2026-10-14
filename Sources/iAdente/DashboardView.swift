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
                        .padding(18)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .clipped()
                }
            } else {
                ScrollView {
                    DashboardContent(coordinator: coordinator, compact: true).padding(18)
                }.scrollIndicators(.automatic)
            }
            footer
        }.frame(width: 410)
            .background(AppBackground(settings: settings))
            .environment(\.interfaceMaterial, settings.material)
            .preferredColorScheme(.dark)
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: AppIdentity.brandSymbol).font(.system(size: 12)).foregroundStyle(Palette.green)
            BrandText(size: 12)
            Spacer()
            footerButton("arrow.clockwise", label: monitor.isRefreshing ? "正在刷新电池读数" : "刷新电池读数", enabled: !monitor.isRefreshing) { monitor.refresh(); coordinator.refreshChargeState() }
            footerButton("gearshape", label: "打开设置") { coordinator.openSettings() }
            footerButton("power", label: "退出 \(AppIdentity.displayName)") { NSApplication.shared.terminate(nil) }
        }.padding(.horizontal, 18).frame(height: 44)
            .liquidSurface(settings: settings, cornerRadius: 0)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
    private func footerButton(_ symbol: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.secondary).frame(width: 28, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label).disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

struct DashboardContent: View {
    @Environment(\.staticRendering) private var staticRendering
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
        VStack(spacing: 16) {
            if compact {
                overviewCard
                statsPanel
                chargeCard
                quickCarePanel
                powerPanel
                appsPanel
                protectionPanel
                detailActions
            } else {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 16) {
                        overviewCard
                        statsPanel
                        powerPanel
                        appsPanel
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        chargeCard
                        quickCarePanel
                        protectionPanel
                        detailActions
                    }.frame(maxWidth: .infinity)
                }
            }
        }.frame(maxWidth: compact ? 374 : 840, alignment: .top)
            .environment(\.interfaceMaterial, settings.material)
            .sheet(isPresented: $showBatteryDetails) { BatteryDetailsView(coordinator: coordinator) }
            .sheet(isPresented: $showControlInfo) { ControlInfoView(coordinator: coordinator) }
            .onChange(of: settings.limit) { chargeDraft = $0 }
            .onChange(of: charge.currentLimit) { if let limit = $0 { chargeDraft = Double(limit) } }
            .onReceive(NotificationCenter.default.publisher(for: .iadenteDashboardClosed)) { _ in
                chargeDraft = Double(charge.currentLimit ?? Int(settings.limit))
                if compact { showBatteryDetails = false; showControlInfo = false }
            }
    }
    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("当前电量").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: snapshot.isPluggedIn ? "powerplug" : "battery.75percent")
                    Text(snapshot.hasBattery ? (snapshot.isPluggedIn ? "外接电源" : "电池供电") : "无电池")
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .liquidSurface(settings: settings, cornerRadius: 100)
            }
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(snapshot.percentage.map(String.init) ?? "—")
                        .font(.system(size: 54, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 24, weight: .regular)).foregroundStyle(Palette.secondary)
                }.foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                BatteryGauge(percentage: snapshot.percentage, charging: snapshot.isCharging)
                    .frame(width: 94, height: 48)
            }
            HStack(spacing: 6) {
                Circle().fill(snapshot.hasBattery ? Palette.green : Palette.orange).frame(width: 5, height: 5)
                Text(snapshot.statusText).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
                Spacer(minLength: 4)
                Image(systemName: "thermometer.medium").font(.system(size: 11))
                Text(snapshot.temperature.map { String(format: "%.1f°C", $0) } ?? "—°C")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
            }.foregroundStyle(Palette.secondary)
                .help(snapshot.temperature == nil ? "系统未提供有效温度读数" : "电池实时温度")
            Rectangle().fill(Palette.line).frame(height: 1)
            updateLine
        }.padding(20)
            .liquidSurface(settings: settings, cornerRadius: 18, prominence: true)
    }
    @ViewBuilder private var updateLine: some View {
        if staticRendering { updateStamp(at: Date()) }
        else {
            TimelineView(.periodic(from: Date(), by: 5)) { context in updateStamp(at: context.date) }
        }
    }
    private func updateStamp(at date: Date) -> some View {
        let stale = date.timeIntervalSince(snapshot.updatedAt) > 120
        return HStack(spacing: 5) {
            Image(systemName: monitor.isRefreshing ? "arrow.clockwise" : (stale ? "clock.badge.exclamationmark" : "clock"))
            Text(monitor.isRefreshing ? "正在更新…" : (stale ? "读数待更新" : "更新于 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"))
            Spacer()
            Text("自动更新")
        }.font(.system(size: 10)).foregroundStyle(stale ? Palette.orange : Palette.tertiary)
            .accessibilityElement(children: .combine)
    }
    private var chargeCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .firstTextBaseline) {
                    Text("充电上限").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                    Spacer()
                    Text("\(coordinator.temporaryFull ? 100 : Int(chargeDraft))%")
                        .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(coordinator.temporaryFull ? Palette.orange : Palette.green)
                }
                ChargeLimitControl(value: Binding(get: { coordinator.temporaryFull ? 100 : chargeDraft },
                                                  set: { if !coordinator.temporaryFull { chargeDraft = $0 } }),
                                   limits: charge.availableLimits, isEnabled: coordinator.canAdjustChargeLimit) { limit in
                    coordinator.applySelectedLimit(limit)
                    if charge.hasKnownState, let actual = charge.currentLimit { chargeDraft = Double(actual) }
                }
                Rectangle().fill(Palette.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(charge.hasKnownState ? Palette.green : Palette.orange).frame(width: 4, height: 4)
                        Text("系统当前：\(coordinator.systemChargeLimitText)")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                    }
                    if coordinator.temporaryFull { Text(coordinator.capCaption) }
                    else if let message = charge.message { Text(message) }
                    if !snapshot.isPluggedIn { Text("接通电源后按此上限管理充电") }
                }.font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var statsPanel: some View {
        Panel {
            HStack(spacing: 0) {
                statistic(snapshot.health.map { "\($0)%" } ?? "—", label: "电池健康")
                    .help("按最大容量与设计容量估算")
                Rectangle().fill(Palette.line).frame(width: 1, height: 30)
                statistic(snapshot.cycles.map(String.init) ?? "—", label: "循环次数")
                Rectangle().fill(Palette.line).frame(width: 1, height: 30)
                statistic(remainingText, label: snapshot.isCharging ? "充满预计" : (snapshot.isPluggedIn ? "充电状态" : "续航预计"), small: true)
            }
        }
    }
    private var remainingText: String {
        guard snapshot.hasBattery else { return "—" }
        if snapshot.isPluggedIn && !snapshot.isCharging { return "未在充电" }
        guard let minutes = snapshot.timeRemainingMinutes, minutes > 0 else { return "正在估算" }
        return minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes)分钟"
    }
    private func statistic(_ value: String, label: String, small: Bool = false) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: small ? 12 : 20, weight: .medium, design: .rounded)).foregroundStyle(Palette.text).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.tertiary)
        }.frame(maxWidth: .infinity)
    }
    private var powerPanel: some View {
        Panel {
            VStack(spacing: 15) {
                panelTitle("实时功率", detail: !snapshot.hasBattery ? "暂无读数" : (snapshot.isPluggedIn ? "外接电源" : "电池供电"))
                PowerFlowDiagram(snapshot: snapshot).frame(height: 174)
            }
        }
    }
    private var appsPanel: some View {
        Panel {
            VStack(spacing: 14) {
                panelTitle("应用活动", detail: "CPU 使用率")
                    .help("按应用进程的 CPU 使用率排序，仅作活动参考，不代表实际耗电份额")
                if let message = monitor.appActivityMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    ForEach(Array(monitor.apps.prefix(3).enumerated()), id: \.element.id) { index, app in
                        AppUsageRow(app: app, rank: index + 1, maxCPU: max(1, monitor.apps.map(\.cpuPercent).max() ?? 1))
                    }
                }
                if let updatedAt = monitor.appsUpdatedAt {
                    Text("更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(Palette.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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
    @ViewBuilder private var protectionPanel: some View {
        if staticRendering { protectionCard(at: Date()) }
        else { TimelineView(.periodic(from: Date(), by: 5)) { context in protectionCard(at: context.date) } }
    }
    private func protectionCard(at date: Date) -> some View {
        ProtectionCard(state: coordinator.protectionState.at(date),
                       reminderEnabled: Binding(get: { settings.highTemperatureReminder },
                                                set: { coordinator.setHighTemperatureReminder($0) }),
                       onReminderSettings: { coordinator.openSettings(.automation) },
                       onChargeSettings: { coordinator.openSettings(.charging) },
                       onNotificationSettings: coordinator.openSystemNotifications)
    }
    private func panelTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            Spacer()
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.tertiary)
        }
    }
    private var detailActions: some View {
        HStack(spacing: 10) {
            navigationButton("info.circle", "电池详情") { showBatteryDetails = true }
            navigationButton("slider.horizontal.3", "充电设置") { coordinator.openSettings(.charging) }
        }
    }
    private func navigationButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(Palette.tertiary)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9))
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 13).frame(height: 39)
                .liquidSurface(settings: settings, cornerRadius: 10)
        }.buttonStyle(.plain)
    }
}

struct BatteryGauge: View {
    let percentage: Int?
    let charging: Bool
    var body: some View {
        GeometryReader { geometry in
            let bodyWidth = geometry.size.width - 7
            let fraction = CGFloat(min(100, max(0, percentage ?? 0))) / 100
            let levelColor = BatteryLevelPalette.color(for: percentage)
            let filledWidth = max(0, (bodyWidth - 10) * fraction)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9).stroke(levelColor.opacity(0.38), lineWidth: 2)
                    .frame(width: bodyWidth)
                RoundedRectangle(cornerRadius: 5)
                    .fill(levelColor)
                    .frame(width: filledWidth, height: geometry.size.height - 10)
                    .padding(.leading, 5)
                RoundedRectangle(cornerRadius: 2).fill(levelColor.opacity(0.5))
                    .frame(width: 4, height: 17).offset(x: bodyWidth + 3)
                if charging {
                    let bolt = Image(systemName: "bolt.fill").font(.system(size: 24, weight: .semibold))
                    bolt.foregroundStyle(levelColor)
                        .frame(width: bodyWidth, height: geometry.size.height)
                        .overlay {
                            bolt.foregroundStyle(Color.black.opacity(0.8))
                                .frame(width: bodyWidth, height: geometry.size.height)
                                .mask(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 5)
                                        .frame(width: filledWidth, height: geometry.size.height - 10)
                                        .padding(.leading, 5)
                                }
                        }
                }
            }.frame(height: geometry.size.height)
        }.accessibilityHidden(true)
    }
}

struct AppUsageRow: View {
    let app: AppUsage
    let rank: Int
    let maxCPU: Double
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon { Image(nsImage: icon).resizable() }
                else { Image(systemName: "app.fill").resizable().foregroundStyle(Palette.secondary) }
            }.frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(app.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f%%", app.cpuPercent)).font(.system(size: 10)).foregroundStyle(Palette.secondary).monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.surfaceRaised)
                        Capsule().fill(Palette.green.opacity(0.75)).frame(width: max(0, geometry.size.width * min(1, app.cpuPercent / maxCPU)))
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
                Capsule().fill(Palette.surfaceRaised).frame(height: 5)
                Capsule().fill(Palette.green.opacity(0.9)).frame(width: offset + 8, height: 5)
                Circle().fill(Palette.text).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Palette.green.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1).offset(x: offset + 1)
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
        }.padding(24).frame(width: 420).foregroundStyle(Palette.text)
            .liquidSurface(settings: coordinator.settings, cornerRadius: 0)
            .preferredColorScheme(.dark)
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
        }.padding(24).frame(width: 380).foregroundStyle(Palette.text)
            .liquidSurface(settings: coordinator.settings, cornerRadius: 0)
            .preferredColorScheme(.dark)
    }
}
