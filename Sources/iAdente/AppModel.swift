import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications
import NativeCharge

enum InterfaceMaterial: String, CaseIterable { case solid, glass, soft }
enum MenuReadout: String, CaseIterable { case battery, power, both }
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用", dashboard = "仪表盘", charging = "充电管理", automation = "计划与自动化", advanced = "高级", about = "关于"
    var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var material: InterfaceMaterial { didSet { defaults.set(material.rawValue, forKey: "material") } }
    @Published var readout: MenuReadout { didSet { defaults.set(readout.rawValue, forKey: "readout") } }
    @Published var useColors: Bool { didSet { defaults.set(useColors, forKey: "useColors") } }
    @Published var limit: Double { didSet { defaults.set(limit, forKey: "chargeLimit") } }
    @Published var limitReminder: Bool { didSet { defaults.set(limitReminder, forKey: "limitReminder") } }
    @Published var lowBatteryReminder: Bool { didSet { defaults.set(lowBatteryReminder, forKey: "lowBatteryReminder") } }
    @Published var highTemperatureReminder: Bool { didSet { defaults.set(highTemperatureReminder, forKey: "highTemperatureReminder") } }
    @Published var highTemperatureThreshold: Double { didSet { defaults.set(highTemperatureThreshold, forKey: "highTemperatureThreshold") } }
    @Published var lowBatteryThreshold: Double { didSet { defaults.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") } }
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var scheduleEnabled: Bool { didSet { defaults.set(scheduleEnabled, forKey: "scheduleEnabled") } }
    @Published var scheduleHour: Int { didSet { defaults.set(scheduleHour, forKey: "scheduleHour") } }
    @Published var scheduleMinute: Int { didSet { defaults.set(scheduleMinute, forKey: "scheduleMinute") } }
    init(preview: Bool = false) {
        defaults = preview ? UserDefaults(suiteName: "cn.local.iadente.preview")! : .standard
        material = InterfaceMaterial(rawValue: defaults.string(forKey: "material") ?? "glass") ?? .glass
        readout = MenuReadout(rawValue: defaults.string(forKey: "readout") ?? "both") ?? .both
        useColors = defaults.object(forKey: "useColors") as? Bool ?? true
        limit = defaults.object(forKey: "chargeLimit") as? Double ?? 100
        limitReminder = defaults.bool(forKey: "limitReminder")
        lowBatteryReminder = defaults.bool(forKey: "lowBatteryReminder")
        highTemperatureReminder = defaults.bool(forKey: "highTemperatureReminder")
        let temperatureThreshold = defaults.object(forKey: "highTemperatureThreshold") as? Double ?? 40
        highTemperatureThreshold = temperatureThreshold.isFinite ? min(55, max(35, temperatureThreshold.rounded())) : 40
        lowBatteryThreshold = defaults.object(forKey: "lowBatteryThreshold") as? Double ?? 20
        refreshInterval = defaults.object(forKey: "refreshInterval") as? Double ?? 5
        scheduleEnabled = defaults.bool(forKey: "scheduleEnabled")
        scheduleHour = defaults.object(forKey: "scheduleHour") as? Int ?? 9
        scheduleMinute = defaults.object(forKey: "scheduleMinute") as? Int ?? 0
    }
    func reset() {
        material = .glass; readout = .both; useColors = true
        limitReminder = false; lowBatteryReminder = false
        highTemperatureReminder = false; highTemperatureThreshold = 40
        lowBatteryThreshold = 20; refreshInterval = 5
        scheduleEnabled = false; scheduleHour = 9; scheduleMinute = 0
    }
}

@MainActor
final class NativeChargeController: ObservableObject {
    @Published private(set) var isSupported = false
    @Published private(set) var isEnabled = false
    @Published private(set) var currentLimit: Int? = nil
    @Published private(set) var hasKnownState = false
    @Published private(set) var message: String? = nil
    let preview: Bool
    init(preview: Bool = false) {
        self.preview = preview
        if preview { isSupported = true; currentLimit = 100; isEnabled = false; hasKnownState = true }
        else { refresh() }
    }
    func refresh() {
        guard !preview else { return }
        isSupported = IAChargeSupported() == 1
        let value = Int(IAChargeCurrentLimit())
        currentLimit = value >= 80 && value <= 100 ? value : nil
        let enabled = IAChargeEnabled()
        isEnabled = enabled == 1
        hasKnownState = isSupported && currentLimit != nil && enabled >= 0
    }
    @discardableResult
    func apply(limit: Int) -> Bool {
        guard !preview else { message = "预览模式不更改系统设置"; return false }
        guard isSupported, [80, 85, 90, 95, 100].contains(limit) else {
            message = "此 Mac 不支持程序内设置充电上限，请使用系统电池设置。"; return false
        }
        var buffer = [CChar](repeating: 0, count: 512)
        let ok = IAChargeSetLimit(Int32(limit), &buffer, Int32(buffer.count)) == 1
        message = ok ? "系统充电上限已设为 \(limit)%" : "设置失败：\(String(cString: buffer))"
        refresh()
        return ok
    }
    @discardableResult
    func disable() -> Bool {
        guard !preview else { return false }
        var buffer = [CChar](repeating: 0, count: 512)
        let ok = IAChargeDisable(&buffer, Int32(buffer.count)) == 1
        message = ok ? "已交还系统默认充电管理" : "设置失败：\(String(cString: buffer))"
        refresh()
        return ok
    }
}

@MainActor
final class AppCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    let settings: AppSettings
    let monitor: BatteryMonitor
    let charge: NativeChargeController
    @Published var selectedTab: SettingsTab = .general
    @Published var banner: String? = nil
    @Published var loginEnabled = false
    @Published var temporaryFull = false
    @Published var notificationStatus = "未开启"
    @Published private(set) var notificationCanDeliver = false
    @Published private(set) var notificationDeliveryDescription = "需允许通知"
    @Published private(set) var temperatureNotificationMessage: String? = nil
    @Published var showBatteryDetails = false
    @Published var showControlInfo = false
    var openSettingsHandler: (() -> Void)?
    var closePopoverHandler: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()
    private var previousLimitNotice = false
    private var previousLowNotice = false
    private var lastScheduleDay: Date? = nil
    private var temporaryStarted: Date? = nil
    private var temporaryRestoreLimit: Int? = nil
    private var temporaryRestoreEnabled = false
    private var lastRestoreAttempt: Date? = nil
    private var temperatureGate = TemperatureReminderGate()
    private var notificationSoundAllowed = false
    private var isRequestingNotificationPermission = false
    private var temperaturePermissionRequestGeneration = 0
    private var pendingTemperatureNoticeID: UUID? = nil
    private var pendingTemperatureNoticeSampledAt: Date? = nil
    private let renderingOnly: Bool
    private let preview: Bool

    init(preview: Bool = false, renderingOnly: Bool = false) {
        self.preview = preview
        self.renderingOnly = renderingOnly
        settings = AppSettings(preview: preview)
        monitor = BatteryMonitor(preview: preview)
        charge = NativeChargeController(preview: preview)
        super.init()
        if !preview {
            loginEnabled = SMAppService.mainApp.status == .enabled
            updateNotificationStatus()
        }
        if !preview && !renderingOnly {
            temperatureGate = TemperatureReminderGate(lastNotifiedAt: UserDefaults.standard.object(forKey: "lastTemperatureNoticeAt") as? Date)
            let pending = UserDefaults.standard.integer(forKey: "temporaryRestoreLimit")
            // A temporarily unavailable sensor must not erase the recovery point.
            if [80, 85, 90, 95, 100].contains(pending), !charge.hasKnownState || (charge.isEnabled && charge.currentLimit == 100) {
                temporaryFull = true
                temporaryRestoreLimit = pending
                temporaryRestoreEnabled = UserDefaults.standard.bool(forKey: "temporaryRestoreEnabled")
                temporaryStarted = UserDefaults.standard.object(forKey: "temporaryStartedAt") as? Date ?? Date()
                settings.limit = Double(pending)
            } else {
                clearTemporaryState()
                if let limit = charge.currentLimit { settings.limit = Double(limit) }
            }
            monitor.setRefreshInterval(settings.refreshInterval)
            UNUserNotificationCenter.current().delegate = self
        }
        monitor.$snapshot.dropFirst().sink { [weak self] snapshot in self?.handle(snapshot) }.store(in: &subscriptions)
        settings.$refreshInterval.dropFirst().sink { [weak self] seconds in self?.monitor.setRefreshInterval(seconds) }.store(in: &subscriptions)
        settings.$highTemperatureReminder.removeDuplicates().dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.invalidatePendingTemperatureNotice()
            self.temperatureNotificationMessage = nil
            self.processTemperatureReminder(self.monitor.snapshot, enabled: enabled)
        }.store(in: &subscriptions)
        settings.$highTemperatureThreshold.removeDuplicates().dropFirst().sink { [weak self] threshold in
            guard let self else { return }
            self.invalidatePendingTemperatureNotice()
            self.temperatureNotificationMessage = nil
            self.processTemperatureReminder(self.monitor.snapshot, threshold: threshold)
        }.store(in: &subscriptions)
    }
    var chargeStatus: String {
        monitor.snapshot.statusText
    }
    var quickCareState: QuickCareState {
        QuickCareState(snapshot: monitor.snapshot, isSupported: charge.isSupported,
                       hasKnownState: charge.hasKnownState, isEnabled: charge.isEnabled,
                       currentLimit: charge.currentLimit, temporaryFull: temporaryFull,
                       restoreDescription: temporaryRestoreDescription)
    }
    private var temporaryRestoreDescription: String {
        temporaryRestoreEnabled ? "\(temporaryRestoreLimit ?? 100)% 上限" : "系统默认管理"
    }
    var protectionState: ProtectionState {
        ProtectionState(snapshot: monitor.snapshot, isChargeSupported: charge.isSupported,
                        hasKnownChargeState: charge.hasKnownState, isChargeEnabled: charge.isEnabled,
                        currentLimit: charge.currentLimit, temporaryFull: temporaryFull,
                        reminderEnabled: settings.highTemperatureReminder,
                        threshold: settings.highTemperatureThreshold,
                        notificationCanDeliver: notificationCanDeliver,
                        notificationDeliveryDescription: notificationDeliveryDescription,
                        feedbackText: temperatureNotificationMessage)
    }
    var capCaption: String {
        if temporaryFull { return "临时充至 100% · 完成后恢复\(temporaryRestoreDescription)" }
        if charge.isSupported {
            if charge.isEnabled, let limit = charge.currentLimit { return "达到 \(limit)% 后由系统暂停充电" }
            return "拖动选择上限，点击应用以同步到系统"
        }
        return "提醒上限 \(Int(settings.limit))% · 硬件控制由系统管理"
    }
    func openSettings(_ tab: SettingsTab = .general) {
        updateNotificationStatus()
        selectedTab = tab; closePopoverHandler?(); openSettingsHandler?()
    }
    func openSystemBattery() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") { NSWorkspace.shared.open(url) }
    }
    func openSystemNotifications() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
    }
    func setHighTemperatureReminder(_ enabled: Bool) {
        guard enabled != settings.highTemperatureReminder else { return }
        temperaturePermissionRequestGeneration += 1
        settings.highTemperatureReminder = enabled
        if enabled { requestNotifications(forTemperatureReminder: true) }
    }
    func refreshChargeState() {
        charge.refresh()
        // A known external change takes precedence over the old recovery point.
        // Unknown readings keep that point available for a later retry.
        if temporaryFull && charge.hasKnownState && (!charge.isEnabled || charge.currentLimit != 100) {
            clearTemporaryState()
            if let limit = charge.currentLimit { settings.limit = Double(limit) }
            banner = "系统充电设置已更改，临时充满已结束。"
        }
    }
    func applyLimit() {
        applyChargeLimit(Int(settings.limit))
    }
    func applyQuickLimit(_ limit: Int) {
        guard [80, 90].contains(limit) else { return }
        applyChargeLimit(limit)
    }
    private func applyChargeLimit(_ limit: Int) {
        guard !temporaryFull else { banner = "请先结束临时充满并恢复原设置，再调整充电上限。"; return }
        guard monitor.snapshot.hasBattery else { banner = "此 Mac 未检测到内置电池。"; return }
        charge.refresh()
        if charge.apply(limit: limit) { settings.limit = Double(limit); clearTemporaryState() }
        banner = charge.message
    }
    func startTemporaryFull() {
        guard !preview else { return }
        guard !temporaryFull else { banner = "临时充满已在进行，原充电设置已保留。"; return }
        charge.refresh()
        if let reason = quickCareState.temporaryBlockReason { banner = reason; return }
        guard let priorLimit = charge.currentLimit, [80, 85, 90, 95, 100].contains(priorLimit) else {
            banner = "原充电设置尚未读到，请刷新后再试。"; return
        }
        let priorEnabled = charge.isEnabled
        if charge.apply(limit: 100) {
            temporaryFull = true; temporaryStarted = Date()
            temporaryRestoreLimit = priorLimit; temporaryRestoreEnabled = priorEnabled
            UserDefaults.standard.set(priorLimit, forKey: "temporaryRestoreLimit")
            UserDefaults.standard.set(priorEnabled, forKey: "temporaryRestoreEnabled")
            UserDefaults.standard.set(temporaryStarted, forKey: "temporaryStartedAt")
            banner = "临时充至 100% 已开启，完成后恢复原来的充电设置。"
        } else { banner = charge.message }
    }
    func cancelTemporaryFull() { _ = restoreTemporaryFull() }
    @discardableResult
    func restoreTemporaryFull() -> Bool {
        guard temporaryFull, let limit = temporaryRestoreLimit else { return true }
        refreshChargeState()
        guard temporaryFull else { return false }
        guard charge.hasKnownState else {
            banner = "暂时未能确认系统充电状态，原设置已保留，请稍后重试。"
            return false
        }
        let restored = temporaryRestoreEnabled ? charge.apply(limit: limit) : charge.disable()
        if restored {
            settings.limit = Double(temporaryRestoreEnabled ? limit : (charge.currentLimit ?? 100))
            clearTemporaryState()
        }
        banner = charge.message
        return restored
    }
    func restoreSystemManagement() {
        guard !temporaryFull else { banner = "请先结束临时充满并恢复原设置，再切换系统管理。"; return }
        guard monitor.snapshot.hasBattery else { banner = "此 Mac 未检测到内置电池。"; return }
        if charge.disable() {
            if let limit = charge.currentLimit { settings.limit = Double(limit) }
            clearTemporaryState()
        }
        banner = charge.message
    }
    private func clearTemporaryState() {
        temporaryFull = false; temporaryStarted = nil; temporaryRestoreLimit = nil
        lastRestoreAttempt = nil
        guard !preview else { return }
        for key in ["temporaryRestoreLimit", "temporaryRestoreEnabled", "temporaryStartedAt"] { UserDefaults.standard.removeObject(forKey: key) }
    }
    func setLogin(_ enabled: Bool) {
        guard !preview else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { banner = "请在系统设置 → 通用 → 登录项中允许 \(AppIdentity.displayName)。" }
        } catch { banner = "无法更改登录项：\(error.localizedDescription)" }
    }
    func requestNotifications(forTemperatureReminder: Bool = false) {
        guard !preview && !renderingOnly else { return }
        let generation = temperaturePermissionRequestGeneration
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.receiveNotificationSettings(info)
                if forTemperatureReminder && (!self.settings.highTemperatureReminder || generation != self.temperaturePermissionRequestGeneration) { return }
                guard self.settings.limitReminder || self.settings.lowBatteryReminder || self.settings.highTemperatureReminder || self.settings.scheduleEnabled else { return }
                if info.authorizationStatus == .notDetermined {
                    self.askNotificationAuthorization()
                } else if !self.notificationCanDeliver {
                    self.banner = "请在系统设置 → 通知中允许 \(AppIdentity.displayName) 发送提醒。"
                }
            }
        }
    }
    private func askNotificationAuthorization() {
        guard !isRequestingNotificationPermission else { return }
        isRequestingNotificationPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRequestingNotificationPermission = false
                if !granted { self.banner = error.map { "通知设置失败：\($0.localizedDescription)" } ?? "请在系统设置 → 通知中允许 \(AppIdentity.displayName) 发送提醒。" }
                self.updateNotificationStatus()
            }
        }
    }
    func updateNotificationStatus() {
        guard !preview else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] info in
            DispatchQueue.main.async { self?.receiveNotificationSettings(info) }
        }
    }
    private func receiveNotificationSettings(_ info: UNNotificationSettings) {
        let allowed = info.authorizationStatus == .authorized || info.authorizationStatus == .provisional
        notificationSoundAllowed = allowed && info.soundSetting == .enabled
        let alerts = allowed && info.alertSetting == .enabled && info.authorizationStatus != .provisional
        let center = allowed && info.notificationCenterSetting == .enabled
        notificationCanDeliver = alerts || center || notificationSoundAllowed
        if !allowed {
            notificationStatus = info.authorizationStatus == .denied ? "未允许" : "未开启"
            notificationDeliveryDescription = "需允许通知"
        } else {
            notificationStatus = notificationCanDeliver ? "已允许" : "通知已关闭"
            notificationDeliveryDescription = alerts ? "通知已允许" : (center ? "仅通知中心" : (notificationSoundAllowed ? "仅声音提醒" : "通知已关闭"))
        }
    }
    private func processTemperatureReminder(_ snapshot: BatterySnapshot, enabled: Bool? = nil, threshold: Double? = nil) {
        guard !renderingOnly else { return }
        let value = threshold ?? settings.highTemperatureThreshold
        guard let candidate = temperatureGate.consider(snapshot: snapshot, threshold: value,
                                                       enabled: enabled ?? settings.highTemperatureReminder,
                                                       canNotify: notificationCanDeliver && !preview, now: Date()) else { return }
        pendingTemperatureNoticeID = candidate.id
        pendingTemperatureNoticeSampledAt = snapshot.updatedAt
        // Confirm permission just before submitting; System Settings can change
        // while this menu app continues running in the background.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] info in
            DispatchQueue.main.async {
                guard let self, self.pendingTemperatureNoticeID == candidate.id else { return }
                self.receiveNotificationSettings(info)
                guard self.isTemperatureNoticeStillCurrent(threshold: value) else {
                    self.pendingTemperatureNoticeID = nil
                    self.pendingTemperatureNoticeSampledAt = nil
                    _ = self.temperatureGate.complete(candidate, succeeded: false, now: Date())
                    return
                }
                if self.notificationCanDeliver {
                    self.submitTemperatureNotification(candidate, threshold: value)
                } else {
                    self.pendingTemperatureNoticeID = nil
                    self.pendingTemperatureNoticeSampledAt = nil
                    _ = self.temperatureGate.complete(candidate, succeeded: false, now: Date())
                    self.temperatureNotificationMessage = "通知未获允许，请检查系统通知设置。"
                }
            }
        }
    }
    private func invalidatePendingTemperatureNotice() {
        guard let id = pendingTemperatureNoticeID else { return }
        pendingTemperatureNoticeID = nil
        pendingTemperatureNoticeSampledAt = nil
        if !preview && !renderingOnly {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["temperature-\(id.uuidString)"])
        }
    }
    private func isTemperatureNoticeStillCurrent(threshold: Double) -> Bool {
        let now = Date()
        let sample = monitor.snapshot
        guard settings.highTemperatureReminder, let sampledAt = pendingTemperatureNoticeSampledAt,
              (-5...120).contains(now.timeIntervalSince(sampledAt)), sample.hasBattery,
              (-5...120).contains(now.timeIntervalSince(sample.updatedAt)),
              let temperature = sample.temperature.flatMap(BatteryTemperature.celsius) else { return false }
        return temperature >= threshold
    }
    private func submitTemperatureNotification(_ candidate: TemperatureNoticeCandidate, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "电池温度提醒"
        content.body = String(format: "检测到电池温度 %.1f°C，已达到设定的 %.0f°C 提醒值。", candidate.temperature, threshold)
        if notificationSoundAllowed { content.sound = .default }
        let request = UNNotificationRequest(identifier: "temperature-\(candidate.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pendingTemperatureNoticeID == candidate.id else { return }
                self.pendingTemperatureNoticeID = nil
                self.pendingTemperatureNoticeSampledAt = nil
                let now = Date()
                if self.temperatureGate.complete(candidate, succeeded: error == nil, now: now) {
                    UserDefaults.standard.set(now, forKey: "lastTemperatureNoticeAt")
                    self.temperatureNotificationMessage = "上次温度提醒：\(now.formatted(date: .omitted, time: .shortened))"
                } else if error != nil && self.settings.highTemperatureReminder {
                    self.temperatureNotificationMessage = "提醒发送失败，请检查通知设置；稍后会重试。"
                }
            }
        }
    }
    private func notify(title: String, text: String) {
        banner = text
        guard !preview else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = text; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    private func handle(_ snapshot: BatterySnapshot) {
        guard !renderingOnly else { return }
        processTemperatureReminder(snapshot)
        if temporaryFull { refreshChargeState() }
        if let percentage = snapshot.percentage {
            let limitReached = snapshot.isPluggedIn && percentage >= Int(settings.limit)
            if settings.limitReminder && limitReached && !previousLimitNotice { notify(title: "电量已达到上限", text: "当前电量 \(percentage)%，设定上限 \(Int(settings.limit))%。") }
            previousLimitNotice = limitReached
            let low = !snapshot.isPluggedIn && percentage <= Int(settings.lowBatteryThreshold)
            if settings.lowBatteryReminder && low && !previousLowNotice { notify(title: "低电量提醒", text: "电量剩余 \(percentage)%，请连接电源。") }
            previousLowNotice = low
            if temporaryFull && percentage >= 100, let started = temporaryStarted, Date().timeIntervalSince(started) > 30,
               lastRestoreAttempt == nil || Date().timeIntervalSince(lastRestoreAttempt!) > 30 {
                lastRestoreAttempt = Date()
                if restoreTemporaryFull() { notify(title: "临时充满已完成", text: "已恢复原来的系统充电设置。") }
            }
        }
        if settings.scheduleEnabled {
            let calendar = Calendar.current
            let parts = calendar.dateComponents([.hour, .minute], from: Date())
            let today = calendar.startOfDay(for: Date())
            if parts.hour == settings.scheduleHour && parts.minute == settings.scheduleMinute && lastScheduleDay != today {
                lastScheduleDay = today
                notify(title: "每日电池养护提醒", text: "查看电池状态、连接电源和充电上限，保持良好的电池习惯。")
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }
}
