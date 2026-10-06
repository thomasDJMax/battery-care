import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var charge: NativeChargeController
    @State private var selectedChargeLimit: Double
    @Environment(\.staticRendering) private var staticRendering

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
        self.monitor = coordinator.monitor
        self.charge = coordinator.charge
        let draft = coordinator.settings.limit
        self._selectedChargeLimit = State(initialValue: Self.validLimit(draft))
    }

    var body: some View {
        ZStack {
            AppBackground(settings: settings)
            VStack(spacing: 0) {
                header
                contentArea
                if let message = coordinator.banner {
                    banner(message)
                }
            }
        }
        .onChange(of: coordinator.selectedTab) { tab in
            if tab == .charging { selectedChargeLimit = Self.validLimit(settings.limit) }
        }
        .foregroundStyle(Palette.text)
        .preferredColorScheme(.dark)
        .frame(minWidth: 790, idealWidth: 860, minHeight: 550, idealHeight: 600)
    }

    @ViewBuilder
    private var contentArea: some View {
        if staticRendering {
            GeometryReader { geometry in
                pageContent
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .clipped()
            }
        } else {
            ScrollView { pageContent }
                .scrollIndicators(.hidden)
        }
    }

    private var pageContent: some View {
        page
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 21)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                IconTile(symbol: "gearshape.fill", color: Palette.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppIdentity.displayName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.text)
                    Text(coordinator.selectedTab.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer()
                Text("电池养护控制台")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            }
            tabStrip
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.098, green: 0.094, blue: 0.090))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .frame(width: 609, height: 25)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置页面")
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let selected = coordinator.selectedTab == tab
        return Button {
            coordinator.selectedTab = tab
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Palette.text)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(selected ? Palette.green : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .trailing) {
                    if !selected && tab != .about {
                        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 14)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var page: some View {
        switch coordinator.selectedTab {
        case .general: generalPage
        case .dashboard: DashboardContent(coordinator: coordinator, compact: false)
        case .charging: chargingPage
        case .automation: automationPage
        case .advanced: advancedPage
        case .about: aboutPage
        }
    }

    private var generalPage: some View {
        VStack(spacing: 15) {
            SettingsCard(title: "界面材质", subtitle: "选择菜单浮层和设置窗口的透明与虚化程度。", symbol: "square.on.square", color: Palette.pink) {
                VStack(alignment: .leading, spacing: 10) {
                    SegmentedChoice(choices: [(.solid, "清晰实体"), (.glass, "毛玻璃"), (.soft, "高斯柔化")], selection: $settings.material)
                    HStack(spacing: 10) {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.purple)
                        Text(materialCaption)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCard(title: "启动", subtitle: "让电池保护在登录后自动开始工作。", symbol: "power.circle.fill", color: Palette.blue) {
                SettingRow(symbol: "arrow.up.right.square.fill", color: Palette.blue, title: "登录时启动 \(AppIdentity.displayName)", subtitle: "登录当前账户后自动显示菜单栏图标", isOn: loginBinding)
            }
            SettingsCard(title: "菜单栏实时读数", subtitle: "在电量、当前系统功率或两者同时显示之间切换。", symbol: "gauge.with.dots.needle.67percent", color: Palette.green) {
                VStack(alignment: .leading, spacing: 11) {
                    SegmentedChoice(choices: [(.battery, "实时电量"), (.power, "实时功率"), (.both, "电量与功率")], selection: $settings.readout)
                    separator
                    SettingRow(symbol: "paintpalette.fill", color: Palette.purple, title: "用颜色显示电池状态", subtitle: "充电、接通电源、低电量使用不同颜色", isOn: $settings.useColors)
                }
            }
        }
    }

    private var materialCaption: String {
        switch settings.material {
        case .solid: return "清晰的不透明界面"
        case .glass: return "平衡透明度与清晰度"
        case .soft: return "更柔和的背景虚化效果"
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { coordinator.loginEnabled }, set: { coordinator.setLogin($0) })
    }

    private var chargingPage: some View {
        VStack(spacing: 15) {
            chargeLimitCard
            SettingsCard(title: "系统充电管理", subtitle: "查看此 Mac 实际提供的控制能力。", symbol: "bolt.shield.fill", color: Palette.blue) {
                VStack(alignment: .leading, spacing: 13) {
                    infoRow("当前状态", value: coordinator.chargeStatus, color: Palette.green)
                    infoRow("系统充电上限", value: systemLimitText, color: charge.isSupported ? Palette.green : Palette.secondary)
                    Text("暂停充电、主动放电与电池校准由系统和硬件管理，当前版本不提供这些操作。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SmallButton(title: "打开系统电池设置", symbol: "arrow.up.right") { coordinator.openSystemBattery() }
                        Spacer()
                        SmallButton(title: "刷新状态", symbol: "arrow.clockwise", color: Palette.blue) {
                            charge.refresh()
                            monitor.refresh()
                        }
                    }
                }
            }
        }
    }

    private var chargeLimitCard: some View {
        SettingsCard(title: "充电上限", subtitle: "选定目标后，将上限应用到系统。", symbol: "battery.100percent", color: Palette.green) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("目标上限").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text("\(Int(selectedChargeLimit))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.green)
                }
                chargeSlider
                HStack {
                    Text("80%"); Spacer(); Text("85%"); Spacer(); Text("90%"); Spacer(); Text("95%"); Spacer(); Text("100%")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                Text(chargeCapabilityCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    applyLimitButton
                    Spacer()
                    if charge.isSupported && charge.isEnabled {
                        SmallButton(title: "恢复系统默认管理", symbol: "arrow.uturn.backward", color: Palette.blue) {
                            coordinator.restoreSystemManagement()
                        }.disabled(coordinator.temporaryFull)
                    }
                }
            }
        }
    }

    private var applyLimitButton: some View {
        SmallButton(title: "应用系统充电上限", symbol: "checkmark.circle.fill") {
            settings.limit = Self.validLimit(selectedChargeLimit)
            coordinator.applyLimit()
        }
        .disabled(!charge.isSupported || !monitor.snapshot.hasBattery || coordinator.temporaryFull)
        .opacity(charge.isSupported && monitor.snapshot.hasBattery && !coordinator.temporaryFull ? 1 : 0.45)
    }

    private var chargeCapabilityCaption: String {
        if coordinator.temporaryFull { return "临时充满进行中。请在快捷养护中恢复原设置，再调整上限。" }
        if !monitor.snapshot.hasBattery { return "此 Mac 未检测到内置电池。" }
        if charge.isSupported { return "支持 80%、85%、90%、95% 与 100%。调整滑块后点击应用，系统设置才会改变。" }
        return "此 Mac 当前未提供可用的系统充电上限接口，请前往系统电池设置管理充电。"
    }

    private var systemLimitText: String {
        guard charge.isSupported else { return "当前系统不支持" }
        if charge.isEnabled, let limit = charge.currentLimit { return "\(limit)% · 已开启" }
        return "系统默认管理"
    }

    private var automationPage: some View {
        VStack(spacing: 15) {
            temperatureReminderCard
            SettingsCard(title: "电量提醒", subtitle: "达到目标电量或电量不足时发送本机通知。", symbol: "bell.badge.fill", color: Palette.orange) {
                VStack(spacing: 12) {
                    SettingRow(symbol: "battery.100percent", color: Palette.green, title: "达到上限时提醒", subtitle: "电源已连接且电量达到 \(Int(settings.limit))% 时提醒", isOn: notificationBinding(\AppSettings.limitReminder))
                    separator
                    SettingRow(symbol: "battery.25percent", color: Palette.orange, title: "低电量提醒", subtitle: "使用电池供电时提醒连接电源", isOn: notificationBinding(\AppSettings.lowBatteryReminder))
                    HStack {
                        Text("低电量阈值").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                        lowBatterySlider.frame(maxWidth: 220)
                        Text("\(Int(settings.lowBatteryThreshold))%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.orange)
                            .frame(width: 40, alignment: .trailing)
                        Spacer()
                    }
                }
            }
            dailyReminderCard
            SettingsCard(title: "通知权限", subtitle: "首次开启提醒时，macOS 会请求通知权限。", symbol: "app.badge.fill", color: Palette.purple) {
                HStack {
                    Text(coordinator.notificationStatus)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(coordinator.notificationStatus == "已允许" ? Palette.green : Palette.secondary)
                    Spacer()
                    SmallButton(title: "刷新权限状态", symbol: "arrow.clockwise", color: Palette.purple) {
                        coordinator.updateNotificationStatus()
                    }
                    SmallButton(title: "通知设置", symbol: "arrow.up.right", color: Palette.blue) {
                        coordinator.openSystemNotifications()
                    }
                }
            }
        }
    }

    private var temperatureReminderCard: some View {
        TimelineView(.periodic(from: Date(), by: 5)) { context in
        let state = coordinator.protectionState.at(context.date)
        SettingsCard(title: "高温提醒", subtitle: "达到自定提醒值时通知，只提醒，不改变充电状态。", symbol: "thermometer.medium", color: Palette.orange) {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(symbol: "bell.badge.fill", color: Palette.orange, title: "开启高温提醒",
                           subtitle: state.reminderStatusText,
                           isOn: Binding(get: { settings.highTemperatureReminder },
                                         set: { coordinator.setHighTemperatureReminder($0) }))
                separator
                HStack(spacing: 14) {
                    Text("提醒阈值").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                    if staticRendering {
                        staticSlider(value: settings.highTemperatureThreshold, range: 35...55, color: Palette.orange).frame(maxWidth: 280)
                    } else {
                        Slider(value: $settings.highTemperatureThreshold, in: 35...55, step: 1)
                            .tint(Palette.orange).frame(maxWidth: 280).accessibilityLabel("高温提醒阈值")
                    }
                    Text(state.thresholdText).font(.system(size: 16, weight: .bold)).monospacedDigit().foregroundStyle(Palette.orange)
                    Spacer(minLength: 0)
                    Text("当前 \(state.temperatureText)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                }
                Text("连续两次读取达到提醒值后通知；降温后可再次提醒，两次通知至少间隔 10 分钟。仅在应用运行且 Mac 唤醒时监测。")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                if state.reminderNeedsPermission {
                    SmallButton(title: "打开通知设置", symbol: "arrow.up.right", color: Palette.orange) { coordinator.openSystemNotifications() }
                }
                if let message = state.feedbackText, settings.highTemperatureReminder {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        }
    }

    private var dailyReminderCard: some View {
        SettingsCard(title: "每日养护提醒", subtitle: "每天在选定时间提示查看电池状态。", symbol: "calendar.badge.clock", color: Palette.blue) {
            VStack(alignment: .leading, spacing: 13) {
                SettingRow(symbol: "clock.fill", color: Palette.blue, title: "开启每日提醒", subtitle: "\(AppIdentity.displayName) 运行时，按本机当前时间提醒", isOn: notificationBinding(\AppSettings.scheduleEnabled))
                separator
                HStack(spacing: 8) {
                    Text("提醒时间").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                    Spacer()
                    if staticRendering {
                        Text(String(format: "%02d : %02d", settings.scheduleHour, settings.scheduleMinute))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.text)
                            .frame(width: 160, height: 22)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    } else {
                        Picker("小时", selection: $settings.scheduleHour) {
                            ForEach(0..<24, id: \.self) { hour in Text(String(format: "%02d", hour)).tag(hour) }
                        }
                        .labelsHidden().frame(width: 72)
                        Text(":").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                        Picker("分钟", selection: $settings.scheduleMinute) {
                            ForEach(0..<60, id: \.self) { minute in Text(String(format: "%02d", minute)).tag(minute) }
                        }
                        .labelsHidden().frame(width: 72)
                    }
                }
                .disabled(!settings.scheduleEnabled)
                .opacity(settings.scheduleEnabled ? 1 : 0.5)
            }
        }
    }

    @ViewBuilder
    private var chargeSlider: some View {
        if staticRendering {
            staticSlider(value: selectedChargeLimit, range: 80...100, color: Palette.green)
        } else {
            Slider(value: $selectedChargeLimit, in: 80...100, step: 5)
                .tint(Palette.green)
                .disabled(coordinator.temporaryFull)
                .accessibilityLabel("目标充电上限")
                .accessibilityValue("\(Int(selectedChargeLimit)) 百分比")
        }
    }

    @ViewBuilder
    private var lowBatterySlider: some View {
        if staticRendering {
            staticSlider(value: settings.lowBatteryThreshold, range: 5...40, color: Palette.orange)
        } else {
            Slider(value: $settings.lowBatteryThreshold, in: 5...40, step: 5)
                .tint(Palette.orange)
                .accessibilityLabel("低电量提醒阈值")
        }
    }

    private func staticSlider(value: Double, range: ClosedRange<Double>, color: Color) -> some View {
        let fraction = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16)).frame(height: 4)
                Capsule().fill(color).frame(width: geometry.size.width * fraction, height: 4)
                Circle().fill(Color.white.opacity(0.94))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .offset(x: max(0, geometry.size.width - 14) * fraction)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 20)
    }

    private func notificationBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: keyPath] }, set: { enabled in
            settings[keyPath: keyPath] = enabled
            if enabled { coordinator.requestNotifications() }
        })
    }

    private var advancedPage: some View {
        VStack(spacing: 15) {
            SettingsCard(title: "数据刷新", subtitle: "设置电池读数与 App 活动的刷新频率。", symbol: "arrow.clockwise.circle.fill", color: Palette.blue) {
                VStack(alignment: .leading, spacing: 12) {
                    SegmentedChoice(choices: [(2.0, "2 秒"), (5.0, "5 秒"), (10.0, "10 秒"), (30.0, "30 秒")], selection: $settings.refreshInterval)
                    HStack {
                        Text("最近更新：\(monitor.snapshot.updatedAt.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.secondary)
                        Spacer()
                        SmallButton(title: "立即刷新", symbol: "arrow.clockwise", color: Palette.blue) {
                            monitor.refresh()
                            charge.refresh()
                        }
                    }
                }
            }
            SettingsCard(title: "本机能力", subtitle: "各项功能以当前 Mac 和系统提供的数据为准。", symbol: "cpu.fill", color: Palette.purple) {
                VStack(alignment: .leading, spacing: 11) {
                    infoRow("内置电池", value: monitor.snapshot.hasBattery ? "已检测到" : "未检测到", color: monitor.snapshot.hasBattery ? Palette.green : Palette.secondary)
                    infoRow("系统充电上限", value: systemLimitText, color: charge.isSupported ? Palette.green : Palette.secondary)
                    infoRow("通知权限", value: coordinator.notificationStatus, color: coordinator.notificationStatus == "已允许" ? Palette.green : Palette.secondary)
                    separator
                    Text("传感器未提供的项目显示为 —。App 活动按 CPU 使用率显示，该百分比不代表耗电占比。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsCard(title: "恢复默认偏好", subtitle: "重置界面、菜单栏读数、提醒与刷新频率。", symbol: "arrow.counterclockwise", color: Palette.orange) {
                HStack {
                    Text("系统充电设置与登录项保留当前状态。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Spacer()
                    SmallButton(title: "恢复默认偏好", symbol: "arrow.counterclockwise", color: Palette.orange) {
                        settings.reset()
                        coordinator.banner = "界面偏好、提醒与刷新设置已恢复默认。"
                    }
                }
            }
        }
    }

    private var aboutPage: some View {
        VStack(spacing: 15) {
            SettingsCard(title: "关于 \(AppIdentity.displayName)", subtitle: "按照提供的截图重新制作的本地 macOS 应用。", symbol: "leaf.fill", color: Palette.green) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        BrandText(size: 28)
                        Text("1.0").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary)
                    }
                    Text("实时查看电量、温度、电池健康与功率，在系统支持时设置原生充电上限。")
                        .font(.system(size: 13)).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    separator
                    infoRow("界面", value: "SwiftUI · macOS 菜单栏应用", color: Palette.secondary)
                    infoRow("电池数据", value: "IOKit / 系统电源信息", color: Palette.secondary)
                    infoRow("数据保存", value: "本机偏好设置", color: Palette.secondary)
                }
            }
            SettingsCard(title: "系统兼容性", subtitle: "充电控制取决于 macOS 当前提供的原生能力。", symbol: "desktopcomputer", color: Palette.blue) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("原生充电上限通过可用时的 PowerUI 接口完成。该接口可能随系统版本变化；接口不可用时，可打开系统电池设置。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SmallButton(title: "打开系统电池设置", symbol: "arrow.up.right", color: Palette.blue) { coordinator.openSystemBattery() }
                }
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Palette.line).frame(height: 1)
    }

    private func infoRow(_ title: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 15) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            Spacer(minLength: 10)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle.fill").foregroundStyle(Palette.blue)
            Text(message).font(.system(size: 12)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { coordinator.banner = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 23, height: 23)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private static func validLimit(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(100, max(80, (value / 5).rounded() * 5))
    }
}
