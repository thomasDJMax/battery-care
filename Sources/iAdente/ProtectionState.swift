import Foundation

// Presentation uses actual readings; a missing system value is never "off".
struct ProtectionState {
    let snapshot: BatterySnapshot
    let isChargeSupported: Bool
    let hasKnownChargeState: Bool
    let isChargeEnabled: Bool
    let currentLimit: Int?
    let temporaryFull: Bool
    let reminderEnabled: Bool
    let threshold: Double
    let notificationCanDeliver: Bool
    let notificationDeliveryDescription: String
    let feedbackText: String?
    var pendingTemporaryStatus: String? = nil
    var now = Date()
    func at(_ date: Date) -> ProtectionState { var state = self; state.now = date; return state }

    var hasBattery: Bool { snapshot.hasBattery }
    private var temperature: Double? {
        guard hasBattery, now.timeIntervalSince(snapshot.updatedAt) >= -5,
              now.timeIntervalSince(snapshot.updatedAt) <= 120 else { return nil }
        return snapshot.temperature.flatMap(BatteryTemperature.celsius)
    }
    var temperatureAvailable: Bool { temperature != nil }
    var temperatureText: String { temperature.map { String(format: "%.1f°C", $0) } ?? "—°C" }
    var thresholdText: String { String(format: "%.0f°C", threshold) }
    var reminderNeedsPermission: Bool { reminderEnabled && !notificationCanDeliver }
    var reminderIsWarning: Bool { reminderEnabled && temperature.map { $0 >= threshold } == true }
    var reminderStatusText: String {
        if !reminderEnabled { return "未开启" }
        if !hasBattery { return "无内置电池" }
        if !temperatureAvailable { return "等待读数" }
        if !notificationCanDeliver { return "需允许通知" }
        if reminderIsWarning { return "达到提醒温度" }
        return notificationDeliveryDescription == "通知已允许" ? "监测中" : notificationDeliveryDescription
    }
    var capIsTemporary: Bool { temporaryFull }
    var capIsActive: Bool {
        hasBattery && isChargeSupported && hasKnownChargeState && isChargeEnabled && !temporaryFull
    }
    var capStatusText: String {
        if temporaryFull, let pendingTemporaryStatus { return pendingTemporaryStatus }
        if temporaryFull { return hasKnownChargeState ? "临时 100%" : "恢复点已保留" }
        if !hasBattery { return "无内置电池" }
        if !isChargeSupported { return "当前不支持" }
        if !hasKnownChargeState { return "状态待确认" }
        if isChargeEnabled, let limit = currentLimit { return "\(limit)% 已应用" }
        return "系统管理"
    }
    var capDetailText: String {
        if temporaryFull, pendingTemporaryStatus != nil { return "请求待确认，原设置已保留" }
        if temporaryFull { return hasKnownChargeState ? "充满后恢复原设置" : "状态待确认，请刷新后查看" }
        if !hasBattery { return "未检测到内置电池" }
        if !isChargeSupported { return "请在系统电池设置中管理充电" }
        if !hasKnownChargeState { return "未能确认实际系统上限" }
        return isChargeEnabled ? "由系统按此上限管理充电" : "使用 macOS 默认充电管理"
    }
}
