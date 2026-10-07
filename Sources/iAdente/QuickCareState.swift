import Foundation

// Shared by the menu and action guards, so a disabled action cannot bypass its
// requirements through another entry point. Values come from system readings.
struct QuickCareState {
    let snapshot: BatterySnapshot
    let isSupported: Bool
    let hasKnownState: Bool
    let isEnabled: Bool
    let currentLimit: Int?
    let temporaryFull: Bool
    let restoreDescription: String
    var pendingTemporaryStatus: String? = nil

    var hasBattery: Bool { snapshot.hasBattery }
    var canApplyPreset: Bool { hasBattery && isSupported && !temporaryFull }
    var canRestoreSystem: Bool { canApplyPreset && (isEnabled || !hasKnownState) }
    var canToggleTemporary: Bool { temporaryFull || temporaryBlockReason == nil }
    func isPresetActive(_ limit: Int) -> Bool {
        !temporaryFull && hasKnownState && isEnabled && currentLimit == limit
    }
    var statusText: String {
        if temporaryFull, let pendingTemporaryStatus { return pendingTemporaryStatus }
        if temporaryFull { return "临时 100%" }
        if !hasBattery { return "无内置电池" }
        if !isSupported { return "仅监测" }
        if !hasKnownState { return "状态待确认" }
        if isEnabled, let limit = currentLimit { return "上限 \(limit)%" }
        return "系统默认"
    }
    var presetCaption: String {
        if temporaryFull { return "先恢复原设置，再调整上限" }
        if !hasBattery { return "未检测到内置电池" }
        if !isSupported { return "请在系统设置中管理充电" }
        return snapshot.isPluggedIn ? "点击后应用到系统" : "点击应用，下次接通电源时生效"
    }
    var temporaryButtonTitle: String {
        if temporaryFull { return hasKnownState ? "恢复原设置" : "重试恢复" }
        if !hasBattery || !isSupported { return "不可用" }
        if snapshot.percentage == 100 { return "已充满" }
        if !snapshot.isPluggedIn { return "需接电" }
        if snapshot.percentage == nil || !hasKnownState { return "读取中" }
        return "开始"
    }
    var temporarySubtitle: String {
        if temporaryFull, pendingTemporaryStatus != nil { return "请求待确认，原设置已保留" }
        if temporaryFull {
            return hasKnownState ? "充满后自动恢复\(restoreDescription)" : "状态待确认，原设置已保留"
        }
        return temporaryBlockReason ?? "充满后自动恢复原设置"
    }
    var temporaryBlockReason: String? {
        if temporaryFull { return "临时充满已在进行，请先恢复原设置。" }
        if !hasBattery { return "此 Mac 未检测到内置电池。" }
        if !isSupported { return "此 Mac 暂不支持程序内充电控制。" }
        guard let percentage = snapshot.percentage else { return "正在读取电量，请稍后再试。" }
        if percentage >= 100 { return "电池已达到 100%，无需临时补满。" }
        if !snapshot.isPluggedIn { return "连接电源后可临时补满。" }
        if !hasKnownState { return "原充电设置尚未读到，请刷新后再试。" }
        return nil
    }
}
