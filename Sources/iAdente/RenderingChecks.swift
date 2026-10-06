import AppKit
import SwiftUI

// Developer-only view rendering. These PNGs contain only this application's
// own views. No desktop, other windows, or screen-capture permissions are used.
@MainActor
func renderApplicationViews(to directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let coordinator = AppCoordinator(renderingOnly: true)
    let deadline = Date().addingTimeInterval(3)
    while !coordinator.monitor.snapshot.hasBattery && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .top).environment(\.staticRendering, true).environment(\.colorScheme, .dark))
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 2
        if let image = renderer.cgImage,
           let bitmap = Optional(NSBitmapImageRep(cgImage: image)),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
    }
    for tab in SettingsTab.allCases {
        coordinator.selectedTab = tab
        try render(SettingsView(coordinator: coordinator), size: NSSize(width: 860, height: 600), name: "settings-\(tab.id).png")
    }
    try render(DashboardView(coordinator: coordinator), size: NSSize(width: 410, height: 720), name: "menu-dashboard.png")
    try render(DashboardContent(coordinator: coordinator, compact: true).padding(14).background(AppBackground(settings: coordinator.settings)), size: NSSize(width: 410, height: 1060), name: "dashboard-full.png")
    print("Rendered all 6 tabs and the menu dashboard with real telemetry to \(directory)")
}

// Only the changed power card: real readings, then isolated layout examples.
// These examples never change the battery's actual charging or power state.
@MainActor
func renderPowerFlowViews(to directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let monitor = BatteryMonitor()
    let deadline = Date().addingTimeInterval(3)
    while !monitor.snapshot.hasBattery && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    var charging = BatterySnapshot.preview
    charging.percentage = 55; charging.isCharging = true
    charging.adapterPower = 60; charging.systemPower = 36; charging.batteryPower = 24
    var discharging = BatterySnapshot.preview
    discharging.percentage = 65; discharging.isPluggedIn = false
    discharging.adapterPower = nil; discharging.systemPower = 21; discharging.batteryPower = -21
    var missing = BatterySnapshot.preview
    missing.adapterPower = nil; missing.systemPower = nil; missing.batteryPower = nil

    for (name, sample, caption, width) in [
        ("power-current.png", monitor.snapshot, "当前实测", CGFloat(382)),
        ("power-charging.png", charging, "充电状态示意", CGFloat(382)),
        ("power-battery.png", discharging, "电池供电示意", CGFloat(382)),
        ("power-missing.png", missing, "缺失读数示意", CGFloat(382)),
        ("power-wide.png", charging, "宽窗口布局示意", CGFloat(700))
    ] {
        let content = VStack(spacing: 12) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("实时功率分流").font(.system(size: 14, weight: .bold))
                Spacer()
                Text(caption).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.foregroundStyle(Palette.text)
            PowerFlowDiagram(snapshot: sample).frame(height: 174)
        }.padding(14).frame(width: width).background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 16))
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "iAdente.PowerFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to render \(name)"])
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
    print("Rendered live power flow plus charging, battery, unavailable and wide layout examples.")
}

@MainActor
func renderQuickCareViews(to directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let monitor = BatteryMonitor()
    let charge = NativeChargeController()
    let deadline = Date().addingTimeInterval(3)
    while !monitor.snapshot.hasBattery && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let current = QuickCareState(snapshot: monitor.snapshot, isSupported: charge.isSupported,
                                hasKnownState: charge.hasKnownState, isEnabled: charge.isEnabled,
                                currentLimit: charge.currentLimit, temporaryFull: false,
                                restoreDescription: "系统默认管理")
    var plugged = BatterySnapshot.preview
    plugged.percentage = 62; plugged.isCharging = true
    var unplugged = plugged
    unplugged.isPluggedIn = false; unplugged.isCharging = false
    var missing = plugged
    missing.percentage = nil
    let states: [(String, QuickCareState, String?)] = [
        ("care-current.png", current, nil),
        ("care-80.png", QuickCareState(snapshot: plugged, isSupported: true, hasKnownState: true, isEnabled: true, currentLimit: 80, temporaryFull: false, restoreDescription: "80% 上限"), "系统充电上限已设为 80%"),
        ("care-temporary.png", QuickCareState(snapshot: plugged, isSupported: true, hasKnownState: true, isEnabled: true, currentLimit: 100, temporaryFull: true, restoreDescription: "80% 上限"), "临时充至 100% 已开启，完成后恢复原来的充电设置。"),
        ("care-retry.png", QuickCareState(snapshot: plugged, isSupported: true, hasKnownState: false, isEnabled: false, currentLimit: nil, temporaryFull: true, restoreDescription: "80% 上限"), "暂时未能确认系统充电状态，原设置已保留，请稍后重试。"),
        ("care-unplugged.png", QuickCareState(snapshot: unplugged, isSupported: true, hasKnownState: true, isEnabled: false, currentLimit: 100, temporaryFull: false, restoreDescription: "系统默认管理"), nil),
        ("care-unknown.png", QuickCareState(snapshot: missing, isSupported: true, hasKnownState: false, isEnabled: false, currentLimit: nil, temporaryFull: false, restoreDescription: "系统默认管理"), nil),
        ("care-unsupported.png", QuickCareState(snapshot: plugged, isSupported: false, hasKnownState: false, isEnabled: false, currentLimit: nil, temporaryFull: false, restoreDescription: "系统默认管理"), nil)
    ]
    for (name, state, feedback) in states {
        let content = QuickCareCard(state: state, feedback: feedback,
                                    onPreset: { _ in }, onTemporary: {}, onDefault: {},
                                    onSystemSettings: {}, onDismissFeedback: {})
            .padding(14).frame(width: 410).background(Color(white: 0.22))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BatteryCare.Rendering", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to render \(name)"])
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
    print("Rendered quick care: live, 80%, temporary full, restore retry, unplugged, unknown and unsupported. No actions executed.")
}

@MainActor
func runQuickCareChecks() {
    func state(_ sample: BatterySnapshot, supported: Bool = true, known: Bool = true,
               enabled: Bool = true, limit: Int? = 80, temporary: Bool = false) -> QuickCareState {
        QuickCareState(snapshot: sample, isSupported: supported, hasKnownState: known,
                       isEnabled: enabled, currentLimit: limit, temporaryFull: temporary,
                       restoreDescription: "80% 上限")
    }
    var sample = BatterySnapshot.preview
    sample.percentage = 60
    let ready = state(sample)
    precondition(ready.canToggleTemporary && ready.isPresetActive(80) && !ready.isPresetActive(90))
    let temporary = state(sample, limit: 100, temporary: true)
    precondition(temporary.canToggleTemporary && !temporary.canApplyPreset && !temporary.canRestoreSystem)
    precondition(!temporary.isPresetActive(80) && !temporary.isPresetActive(90))
    sample.isPluggedIn = false
    let unplugged = state(sample)
    precondition(!unplugged.canToggleTemporary && unplugged.canApplyPreset && unplugged.canRestoreSystem)
    sample.isPluggedIn = true; sample.percentage = 100
    precondition(!state(sample).canToggleTemporary)
    sample.percentage = nil
    precondition(!state(sample).canToggleTemporary)
    sample.percentage = 60
    precondition(!state(sample, known: false, limit: nil).canToggleTemporary)
    let unsupported = state(sample, supported: false, known: false, limit: nil)
    precondition(!unsupported.canApplyPreset && !unsupported.canToggleTemporary && !unsupported.canRestoreSystem)
    sample.hasBattery = false
    precondition(!state(sample).canApplyPreset && !state(sample).canToggleTemporary)
    // Exercise shared coordinator guards using an isolated preview store. These
    // calls must keep a live recovery session intact and execute no native writes.
    let coordinator = AppCoordinator(preview: true)
    coordinator.temporaryFull = true
    let previous = coordinator.settings.limit
    coordinator.applyQuickLimit(80)
    precondition(coordinator.temporaryFull && coordinator.settings.limit == previous && coordinator.banner != nil)
    coordinator.banner = nil
    coordinator.applyLimit()
    precondition(coordinator.temporaryFull && coordinator.banner != nil)
    coordinator.banner = nil
    coordinator.restoreSystemManagement()
    precondition(coordinator.temporaryFull && coordinator.banner != nil)
    print("Quick care checks passed: real cap selection, start requirements and protected recovery session. No native writes.")
}

@MainActor
func renderProtectionViews(to directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let monitor = BatteryMonitor()
    let charge = NativeChargeController()
    let settings = AppSettings()
    let deadline = Date().addingTimeInterval(3)
    while !monitor.snapshot.hasBattery && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    func state(_ sample: BatterySnapshot, enabled: Bool = true, canNotify: Bool = true,
               delivery: String = "通知已允许", known: Bool = true, temporary: Bool = false,
               feedback: String? = nil) -> ProtectionState {
        ProtectionState(snapshot: sample, isChargeSupported: true, hasKnownChargeState: known,
                        isChargeEnabled: true, currentLimit: known ? 80 : nil, temporaryFull: temporary,
                        reminderEnabled: enabled, threshold: 40, notificationCanDeliver: canNotify,
                        notificationDeliveryDescription: delivery, feedbackText: feedback)
    }
    var normal = BatterySnapshot.preview
    normal.temperature = 32.4
    var hot = normal; hot.temperature = 43.2
    var missing = normal; missing.temperature = nil
    var stale = normal; stale.updatedAt = Date().addingTimeInterval(-180)
    let current = ProtectionState(snapshot: monitor.snapshot, isChargeSupported: charge.isSupported,
                                  hasKnownChargeState: charge.hasKnownState, isChargeEnabled: charge.isEnabled,
                                  currentLimit: charge.currentLimit, temporaryFull: false,
                                  reminderEnabled: settings.highTemperatureReminder,
                                  threshold: settings.highTemperatureThreshold, notificationCanDeliver: false,
                                  notificationDeliveryDescription: "需允许通知", feedbackText: nil)
    let cases: [(String, ProtectionState, CGFloat)] = [
        ("protection-current.png", current, 410),
        ("protection-monitoring.png", state(normal), 410),
        ("protection-high.png", state(hot), 410),
        ("protection-missing.png", state(missing, known: false), 410),
        ("protection-permission.png", state(normal, canNotify: false), 410),
        ("protection-center.png", state(normal, delivery: "仅通知中心"), 410),
        ("protection-temporary.png", state(normal, enabled: false, known: false, temporary: true), 410),
        ("protection-stale.png", state(stale), 410),
        ("protection-failure.png", state(hot, feedback: "提醒发送失败，请检查通知设置；稍后会重试。"), 410),
        ("protection-wide.png", state(normal), 728)
    ]
    for (name, sample, width) in cases {
        let content = ProtectionCard(state: sample, reminderEnabled: .constant(sample.reminderEnabled),
                                     onReminderSettings: {}, onChargeSettings: {}, onNotificationSettings: {})
            .padding(14).frame(width: width).background(Color(white: 0.22))
            .environment(\.staticRendering, true).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BatteryCare.Rendering", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to render \(name)"])
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
    print("Rendered protection states with empty callbacks. No notifications, permission prompts or charging writes.")
}
