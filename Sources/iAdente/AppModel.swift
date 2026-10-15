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
    @Published var limit: Double { didSet {
        let normalized = AppSettingBounds.limit(limit)
        if !limit.isFinite || limit != normalized { limit = normalized }
        defaults.set(normalized, forKey: "chargeLimit")
    } }
    @Published var limitReminder: Bool { didSet { defaults.set(limitReminder, forKey: "limitReminder") } }
    @Published var lowBatteryReminder: Bool { didSet { defaults.set(lowBatteryReminder, forKey: "lowBatteryReminder") } }
    @Published var highTemperatureReminder: Bool { didSet { defaults.set(highTemperatureReminder, forKey: "highTemperatureReminder") } }
    @Published var highTemperatureThreshold: Double { didSet {
        let normalized = AppSettingBounds.temperature(highTemperatureThreshold)
        if !highTemperatureThreshold.isFinite || highTemperatureThreshold != normalized { highTemperatureThreshold = normalized }
        defaults.set(normalized, forKey: "highTemperatureThreshold")
    } }
    @Published var lowBatteryThreshold: Double { didSet {
        let normalized = AppSettingBounds.lowBattery(lowBatteryThreshold)
        if !lowBatteryThreshold.isFinite || lowBatteryThreshold != normalized { lowBatteryThreshold = normalized }
        defaults.set(normalized, forKey: "lowBatteryThreshold")
    } }
    @Published var refreshInterval: Double { didSet {
        let normalized = AppSettingBounds.refresh(refreshInterval)
        if !refreshInterval.isFinite || refreshInterval != normalized { refreshInterval = normalized }
        defaults.set(normalized, forKey: "refreshInterval")
    } }
    @Published var scheduleEnabled: Bool { didSet { defaults.set(scheduleEnabled, forKey: "scheduleEnabled") } }
    @Published var scheduleHour: Int { didSet {
        let normalized = AppSettingBounds.hour(scheduleHour)
        if scheduleHour != normalized { scheduleHour = normalized }
        defaults.set(normalized, forKey: "scheduleHour")
    } }
    @Published var scheduleMinute: Int { didSet {
        let normalized = AppSettingBounds.minute(scheduleMinute)
        if scheduleMinute != normalized { scheduleMinute = normalized }
        defaults.set(normalized, forKey: "scheduleMinute")
    } }
    init(preview: Bool = false, store: UserDefaults? = nil) {
        defaults = store ?? (preview ? UserDefaults(suiteName: "cn.local.iadente.preview")! : .standard)
        material = InterfaceMaterial(rawValue: defaults.string(forKey: "material") ?? "glass") ?? .glass
        readout = MenuReadout(rawValue: defaults.string(forKey: "readout") ?? "both") ?? .both
        useColors = defaults.object(forKey: "useColors") as? Bool ?? true
        let storedLimit = defaults.object(forKey: "chargeLimit") as? Double ?? 100
        limit = storedLimit.isFinite && (1...100).contains(storedLimit) ? storedLimit.rounded() : 100
        limitReminder = defaults.bool(forKey: "limitReminder")
        lowBatteryReminder = defaults.bool(forKey: "lowBatteryReminder")
        highTemperatureReminder = defaults.bool(forKey: "highTemperatureReminder")
        let temperatureThreshold = defaults.object(forKey: "highTemperatureThreshold") as? Double ?? 40
        highTemperatureThreshold = temperatureThreshold.isFinite ? min(55, max(35, temperatureThreshold.rounded())) : 40
        lowBatteryThreshold = AppSettingBounds.lowBattery(defaults.object(forKey: "lowBatteryThreshold") as? Double ?? 20)
        refreshInterval = AppSettingBounds.refresh(defaults.object(forKey: "refreshInterval") as? Double ?? 5)
        scheduleEnabled = defaults.bool(forKey: "scheduleEnabled")
        scheduleHour = AppSettingBounds.hour(defaults.object(forKey: "scheduleHour") as? Int ?? 9)
        scheduleMinute = AppSettingBounds.minute(defaults.object(forKey: "scheduleMinute") as? Int ?? 0)
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
    @Published private(set) var availableLimits: [Int] = []
    @Published private(set) var isSupported = false
    @Published private(set) var isEnabled = false
    @Published private(set) var currentLimit: Int? = nil
    @Published private(set) var hasKnownState = false
    @Published private(set) var message: String? = nil
    @Published private(set) var operationConfirmed = false
    var readback: ChargeLimitReadback { ChargeLimitReadback(known: hasKnownState, enabled: isEnabled, limit: currentLimit) }
    let preview: Bool
    init(preview: Bool = false) {
        self.preview = preview
        if preview { availableLimits = [80, 85, 90, 95, 100]; isSupported = true; currentLimit = 100; isEnabled = false; hasKnownState = true }
        else { refresh() }
    }
    func refresh() {
        guard !preview else { return }
        var limits = [Int32](repeating: 0, count: 100)
        let count = Int(IAChargeCopyAvailableLimits(&limits, Int32(limits.count)))
        availableLimits = ChargeLimitOptions(limits.prefix(max(0, min(count, limits.count))).map(Int.init)).values
        isSupported = !availableLimits.isEmpty
        let value = Int(IAChargeCurrentLimit())
        currentLimit = availableLimits.contains(value) ? value : nil
        let enabled = IAChargeEnabled()
        isEnabled = enabled == 1
        hasKnownState = isSupported && currentLimit != nil && enabled >= 0
    }
    @discardableResult
    func apply(limit: Int) -> Bool {
        operationConfirmed = false
        guard !preview else { message = "预览模式不更改系统设置"; return false }
        guard isSupported, availableLimits.contains(limit) else {
            message = isSupported ? "系统不支持 \(limit)%；可用上限：\(ChargeLimitOptions(availableLimits).caption)。" : "此 Mac 不支持程序内设置充电上限，请使用系统电池设置。"; return false
        }
        var buffer = [CChar](repeating: 0, count: 512)
        let ok = IAChargeSetLimit(Int32(limit), &buffer, Int32(buffer.count)) == 1
        refresh()
        operationConfirmed = ok && readback.confirms(limit)
        if !ok { message = "设置失败：\(String(cString: buffer))" }
        else if !hasKnownState { message = "已提交 \(limit)% 上限，正在等待系统确认。" }
        else if !operationConfirmed { message = "已提交 \(limit)%；系统暂未确认生效，请刷新确认。" }
        else { message = "系统充电上限已设为 \(limit)%" }
        return ok
    }
    @discardableResult
    func disable() -> Bool {
        operationConfirmed = false
        guard !preview else { return false }
        var buffer = [CChar](repeating: 0, count: 512)
        let ok = IAChargeDisable(&buffer, Int32(buffer.count)) == 1
        refresh()
        operationConfirmed = ok && hasKnownState && !isEnabled
        message = !ok ? "设置失败：\(String(cString: buffer))" : (operationConfirmed ? "已交还系统默认充电管理" : "已提交恢复系统管理请求，等待系统确认。")
        return ok
    }
    func confirmSubmittedLimit(_ target: Int) -> Bool {
        guard readback.confirms(target) else { return false }
        operationConfirmed = true
        message = "系统充电上限已设为 \(target)%"
        return true
    }
    func confirmSubmittedSystemManagement() -> Bool {
        guard hasKnownState && !isEnabled else { return false }
        operationConfirmed = true
        message = "已交还系统默认充电管理"
        return true
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
    private var limitReminderGate = ReminderDeliveryGate()
    private var lowBatteryReminderGate = ReminderDeliveryGate()
    private var dailyReminderGate: DailyReminderDeliveryGate
    private var notificationPermissionRefresh = NotificationPermissionRefreshPolicy()
    private let temporaryStore = TemporaryChargeSessionStore()
    private var temporarySession: TemporaryChargeSession? = nil
    private var temporaryStarted: Date? { temporarySession?.startedAt }
    private var temporaryRestoreLimit: Int? { temporarySession?.originalLimit }
    private var temporaryRestoreEnabled: Bool? { temporarySession?.originalEnabled }
    private var temporaryAwaitingConfirmation: Bool { temporarySession?.awaitingFullConfirmation == true }
    private var temporaryRestorePending: Bool { temporarySession?.phase == .restoring }
    private var chargeActions = ChargeActionTracker()
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
        dailyReminderGate = DailyReminderDeliveryGate(defaults: preview || renderingOnly ? UserDefaults(suiteName: "cn.local.iadente.preview")! : .standard)
        settings = AppSettings(preview: preview)
        monitor = BatteryMonitor(preview: preview)
        charge = NativeChargeController(preview: preview)
        super.init()
        if !preview {
            refreshLoginStatus()
            updateNotificationStatus()
        }
        if !preview && !renderingOnly {
            temperatureGate = TemperatureReminderGate(lastNotifiedAt: UserDefaults.standard.object(forKey: "lastTemperatureNoticeAt") as? Date)
            let recovery = temporaryStore.load()
            banner = recovery.warning
            // Prepared or uncertain requests retain the recovery point across a restart.
            if let session = recovery.session,
               session.awaitingFullConfirmation || session.phase == .restoring || session.originalEnabled == nil || !charge.hasKnownState || charge.readback.confirms(100) {
                temporaryFull = true
                temporarySession = session
                settings.limit = Double(session.originalLimit)
            } else {
                if recovery.session != nil { clearTemporaryState() }
                if let limit = charge.currentLimit { settings.limit = Double(limit) }
            }
            monitor.setRefreshInterval(settings.refreshInterval)
            UNUserNotificationCenter.current().delegate = self
        }
        monitor.$snapshot.dropFirst().sink { [weak self] snapshot in self?.handle(snapshot) }.store(in: &subscriptions)
        settings.$refreshInterval.dropFirst().sink { [weak self] seconds in self?.monitor.setRefreshInterval(AppSettingBounds.refresh(seconds)) }.store(in: &subscriptions)
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
            self.processTemperatureReminder(self.monitor.snapshot, threshold: AppSettingBounds.temperature(threshold))
        }.store(in: &subscriptions)
        // @Published emits before storing the new value. Reevaluate on the next
        // main-queue turn so every gate sees the completed settings change.
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.processBatteryReminders(self.monitor.snapshot)
            }
        }.store(in: &subscriptions)
    }
    var chargeStatus: String {
        monitor.snapshot.statusText
    }
    var quickCareState: QuickCareState {
        QuickCareState(snapshot: monitor.snapshot, isSupported: charge.isSupported,
                       hasKnownState: charge.hasKnownState, isEnabled: charge.isEnabled,
                       currentLimit: charge.currentLimit, temporaryFull: temporaryFull,
                       restoreDescription: temporaryRestoreDescription,
                       pendingTemporaryStatus: pendingTemporaryStatus,
                       hasLegacyRecovery: temporarySession != nil && temporaryRestoreEnabled == nil)
    }
    private var pendingTemporaryStatus: String? {
        if temporaryFull && temporaryRestoreEnabled == nil { return "恢复方式待确认" }
        if temporaryRestorePending { return "恢复原设置中" }
        if temporaryAwaitingConfirmation { return "临时请求待确认" }
        return nil
    }
    private var temporaryRestoreDescription: String {
        guard let enabled = temporaryRestoreEnabled else { return "原设置（恢复方式待确认）" }
        return enabled ? "\(temporaryRestoreLimit ?? 100)% 上限" : "系统默认管理"
    }
    var protectionState: ProtectionState {
        ProtectionState(snapshot: monitor.snapshot, isChargeSupported: charge.isSupported,
                        hasKnownChargeState: charge.hasKnownState, isChargeEnabled: charge.isEnabled,
                        currentLimit: charge.currentLimit, temporaryFull: temporaryFull,
                        reminderEnabled: settings.highTemperatureReminder,
                        threshold: settings.highTemperatureThreshold,
                        notificationCanDeliver: notificationCanDeliver,
                        notificationDeliveryDescription: notificationDeliveryDescription,
                        feedbackText: temperatureNotificationMessage,
                        pendingTemporaryStatus: pendingTemporaryStatus)
    }
    var capCaption: String {
        if temporaryFull, let pendingTemporaryStatus { return "\(pendingTemporaryStatus) · 原设置已保留" }
        if temporaryFull { return "临时充至 100% · 完成后恢复\(temporaryRestoreDescription)" }
        if charge.isSupported {
            if !charge.hasKnownState { return "系统上限待确认，请刷新后重试" }
            if charge.isEnabled, let limit = charge.currentLimit { return "系统已应用 \(limit)% 上限" }
            return "系统默认管理 · 上限 \(charge.currentLimit ?? 100)%"
        }
        return "提醒上限 \(Int(settings.limit))% · 硬件控制由系统管理"
    }
    var systemChargeLimitText: String {
        guard charge.isSupported else { return "当前系统不支持" }
        guard charge.hasKnownState, let limit = charge.currentLimit else { return "状态待确认" }
        return charge.isEnabled ? "\(limit)% · 已应用" : "\(limit)% · 系统默认管理"
    }
    var canAdjustChargeLimit: Bool { monitor.snapshot.hasBattery && charge.isSupported && !temporaryFull }
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
        if !temporaryFull && charge.hasKnownState {
            if let actual = charge.currentLimit { settings.limit = Double(actual) }
            if let action = chargeActions.confirm(charge.readback) {
                switch action {
                case .limit(let target): _ = charge.confirmSubmittedLimit(target)
                case .systemManagement: _ = charge.confirmSubmittedSystemManagement()
                }
                banner = charge.message
            }
        }
        // A known external change takes precedence over the old recovery point.
        // Unknown readings keep that point available for a later retry.
        if temporaryFull && charge.hasKnownState && temporaryRestorePending {
            if temporarySession?.confirmsRestoration(charge.readback) == true {
                completeTemporaryRestoration()
            } else { banner = "恢复请求仍待系统确认，原恢复点已保留。" }
            return
        }
        if temporaryFull && temporaryAwaitingConfirmation {
            guard charge.readback.confirms(100) else { return }
            if var session = temporarySession {
                session.phase = .charging
                temporarySession = session
                persistTemporarySession(session)
            }
        }
        if temporaryFull && temporaryRestoreEnabled != nil && charge.hasKnownState && !charge.readback.confirms(100) {
            clearTemporaryState()
            if let limit = charge.currentLimit { settings.limit = Double(limit) }
            banner = "系统充电设置已更改，临时充满已结束。"
        }
    }
    func applyLimit() {
        guard settings.limit.isFinite, (1...100).contains(settings.limit) else { return }
        applyChargeLimit(Int(settings.limit.rounded()))
    }
    func applySelectedLimit(_ limit: Int) { applyChargeLimit(limit) }
    func applyQuickLimit(_ limit: Int) {
        guard [80, 90].contains(limit) else { return }
        applyChargeLimit(limit)
    }
    private func applyChargeLimit(_ limit: Int) {
        guard !renderingOnly else { banner = "仅渲染模式不更改系统充电设置。"; return }
        guard !temporaryFull else { banner = "请先结束临时充满并恢复原设置，再调整充电上限。"; return }
        guard monitor.snapshot.hasBattery else { banner = "此 Mac 未检测到内置电池。"; return }
        charge.refresh()
        if charge.apply(limit: limit) {
            chargeActions.submitted(.limit(limit), confirmed: charge.operationConfirmed)
            if charge.operationConfirmed {
                if let actual = charge.currentLimit { settings.limit = Double(actual) }
                clearTemporaryState()
            }
        }
        banner = charge.message
    }
    func startTemporaryFull() {
        guard !preview else { return }
        guard !renderingOnly else { banner = "仅渲染模式不更改系统充电设置。"; return }
        guard !temporaryFull else { banner = "临时充满已在进行，原充电设置已保留。"; return }
        guard chargeActions.pending == nil else { banner = "上一次充电设置仍待系统确认，请刷新确认后再临时充满。"; return }
        charge.refresh()
        if let reason = quickCareState.temporaryBlockReason { banner = reason; return }
        guard let priorLimit = charge.currentLimit, charge.availableLimits.contains(priorLimit) else {
            banner = "原充电设置尚未读到，请刷新后再试。"; return
        }
        let priorEnabled = charge.isEnabled
        var session = TemporaryChargeSession(originalLimit: priorLimit, originalEnabled: priorEnabled,
            startedAt: Date(), phase: .prepared)
        // Preserve a complete, verified recovery point before submitting 100%.
        do { try temporaryStore.save(session) }
        catch { banner = "无法保存原充电设置，尚未提交临时充满请求：\(error.localizedDescription)"; return }
        temporarySession = session
        temporaryFull = true
        if charge.apply(limit: 100) {
            chargeActions.clear()
            session.phase = charge.operationConfirmed ? .charging : .awaitingFullConfirmation
            temporarySession = session
            banner = charge.operationConfirmed ? "临时充至 100% 已开启，完成后恢复原来的充电设置。" : "临时 100% 请求已提交，等待系统确认；原设置已保留。"
            persistTemporarySession(session)
        } else {
            clearTemporaryState()
            banner = charge.message
        }
    }
    func cancelTemporaryFull() { _ = restoreTemporaryFull() }
    func acknowledgeLegacyRecovery() {
        guard !preview && !renderingOnly, temporaryFull,
              let session = temporarySession, session.originalEnabled == nil else { return }
        charge.refresh()
        guard charge.hasKnownState else {
            banner = "暂时未能确认当前系统设置，旧记录已保留；请刷新后重试。"
            return
        }
        do { try temporaryStore.acknowledgeLegacyRecovery(session, readback: charge.readback) }
        catch {
            banner = "未能结束旧恢复记录，记录和临时状态已保留，请稍后重试。"
            return
        }
        // Only release the UI lock after the exact old record is consumed.
        // This acknowledgement never submits a charging operation.
        temporarySession = nil
        temporaryFull = false
        lastRestoreAttempt = nil
        if let actual = charge.currentLimit { settings.limit = Double(actual) }
        banner = "旧临时记录已结束，保留当前系统充电设置。"
    }
    @discardableResult
    func restoreTemporaryFull(automatically: Bool = false) -> Bool {
        guard !renderingOnly else { banner = "仅渲染模式不更改系统充电设置。"; return false }
        guard temporaryFull, let limit = temporaryRestoreLimit else { return true }
        let wasRestorePending = temporaryRestorePending
        refreshChargeState()
        guard temporaryFull else { return wasRestorePending }
        guard charge.hasKnownState else {
            banner = "暂时未能确认系统充电状态，原设置已保留，请稍后重试。"
            return false
        }
        guard let enabled = temporaryRestoreEnabled, var session = temporarySession else {
            banner = "旧恢复记录缺少原管理方式，已保留原上限；请在系统电池设置中确认，未提交恢复操作。"
            return false
        }
        // A submitted restore whose state is already confirmed needs only record
        // cleanup. Retrying that cleanup must not submit another hardware write.
        if session.phase == .restoring && session.confirmsRestoration(charge.readback) {
            completeTemporaryRestoration()
            return !temporaryFull
        }
        let previousSession = session
        session.phase = .restoring
        session.automaticCompletionNoticePending = session.automaticCompletionNoticePending || automatically
        do { try temporaryStore.save(session) }
        catch { banner = "无法保存恢复请求状态，原设置已保留，请稍后重试。"; return false }
        temporarySession = session
        let accepted = enabled ? charge.apply(limit: limit) : charge.disable()
        let restored = accepted && session.confirmsRestoration(charge.readback)
        if restored {
            completeTemporaryRestoration()
        } else if !accepted {
            temporarySession = previousSession
            persistTemporarySession(previousSession)
        }
        if !restored { banner = !accepted ? charge.message : "恢复请求已提交，等待系统确认；原设置已保留。" }
        return restored
    }
    func restoreSystemManagement() {
        guard !renderingOnly else { banner = "仅渲染模式不更改系统充电设置。"; return }
        guard !temporaryFull else { banner = "请先结束临时充满并恢复原设置，再切换系统管理。"; return }
        guard monitor.snapshot.hasBattery else { banner = "此 Mac 未检测到内置电池。"; return }
        if charge.disable() {
            chargeActions.submitted(.systemManagement, confirmed: charge.operationConfirmed)
            if charge.operationConfirmed {
                if let limit = charge.currentLimit { settings.limit = Double(limit) }
                clearTemporaryState()
            }
        }
        banner = charge.message
    }
    @discardableResult
    private func clearTemporaryState() -> Bool {
        temporaryFull = false; temporarySession = nil
        lastRestoreAttempt = nil
        guard !preview && !renderingOnly else { return true }
        do { try temporaryStore.clear(); return true }
        catch {
            banner = "当前状态已确认，但未能清理恢复记录；下次启动会再次核对系统状态。"
            return false
        }
    }
    private func persistTemporarySession(_ session: TemporaryChargeSession) {
        do { try temporaryStore.save(session) }
        catch { banner = "系统请求已提交，原恢复点仍已保留，但未能保存最新进度；请稍后刷新确认。" }
    }
    private func completeTemporaryRestoration() {
        guard let session = temporarySession else { return }
        var shouldNotify = false
        if !preview && !renderingOnly {
            do { shouldNotify = try temporaryStore.completeRestoration(session) }
            catch {
                banner = "原充电设置已确认恢复，但未能清理恢复记录；记录已保留，稍后会重试确认。"
                return
            }
        }
        if let actual = charge.currentLimit { settings.limit = Double(actual) }
        clearTemporaryState()
        banner = "原充电设置已恢复。"
        if shouldNotify { notify(title: "临时充满已完成", text: "已恢复原来的系统充电设置。") }
    }
    func refreshLoginStatus(statusProvider: (() -> SMAppService.Status)? = nil) {
        if let statusProvider {
            loginEnabled = statusProvider() == .enabled
            return
        }
        guard !preview && !renderingOnly else { return }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }
    func setLogin(_ enabled: Bool) {
        guard !preview && !renderingOnly else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
            if enabled && !loginEnabled { banner = "请在系统设置 → 通用 → 登录项中允许 \(AppIdentity.displayName)。" }
        } catch {
            refreshLoginStatus()
            banner = "无法更改登录项：\(error.localizedDescription)"
        }
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
    func updateNotificationStatus(force: Bool = true, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !preview && !renderingOnly else { return }
        if !force {
            guard settings.limitReminder || settings.lowBatteryReminder || settings.highTemperatureReminder || settings.scheduleEnabled else { return }
        }
        guard let token = notificationPermissionRefresh.begin(now: now, force: force) else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] info in
            DispatchQueue.main.async {
                guard let self, self.notificationPermissionRefresh.complete(token) else { return }
                self.receiveNotificationSettings(info)
            }
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
        processBatteryReminders(monitor.snapshot)
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
    private enum BatteryReminderKind { case limit, lowBattery }

    /// Unknown or stale battery readings cannot end a previously notified
    /// episode. They also cannot authorize a new notification.
    private func synchronizeReminderGates(_ snapshot: BatterySnapshot, canNotify: Bool, now: Date)
        -> (limit: ReminderNoticeCandidate?, low: ReminderNoticeCandidate?, daily: DailyReminderCandidate?) {
        let fresh = snapshot.hasBattery && (-5...120).contains(now.timeIntervalSince(snapshot.updatedAt))
        let percentage = fresh ? snapshot.percentage.flatMap { (0...100).contains($0) ? $0 : nil } : nil
        let limit = limitReminderGate.consider(
            condition: percentage.map { snapshot.isPluggedIn && $0 >= Int(settings.limit) },
            threshold: Int(settings.limit), enabled: settings.limitReminder, canNotify: canNotify, now: now)
        let low = lowBatteryReminderGate.consider(
            condition: percentage.map { !snapshot.isPluggedIn && $0 <= Int(settings.lowBatteryThreshold) },
            threshold: Int(settings.lowBatteryThreshold), enabled: settings.lowBatteryReminder, canNotify: canNotify, now: now)
        let daily = dailyReminderGate.consider(
            enabled: settings.scheduleEnabled, hour: settings.scheduleHour, minute: settings.scheduleMinute,
            canNotify: canNotify, now: now)
        return (limit, low, daily)
    }

    private func processBatteryReminders(_ snapshot: BatterySnapshot) {
        guard !preview && !renderingOnly else { return }
        // Poll permission independently of reminder candidates: a cached denial
        // cannot prevent noticing a later change in System Settings. The policy
        // bounds background reads and prevents callback-driven reentrancy.
        updateNotificationStatus(force: false)
        let candidates = synchronizeReminderGates(snapshot, canNotify: notificationCanDeliver, now: Date())
        if let candidate = candidates.limit, let percentage = snapshot.percentage {
            submitBatteryReminder(candidate, kind: .limit, percentage: percentage)
        }
        if let candidate = candidates.low, let percentage = snapshot.percentage {
            submitBatteryReminder(candidate, kind: .lowBattery, percentage: percentage)
        }
        if let candidate = candidates.daily {
            postReminder(identifier: candidate.identifier,
                         title: "每日电池养护提醒",
                         text: "查看电池状态、连接电源和充电上限，保持良好的电池习惯。",
                         isCurrent: { [weak self] in self?.dailyReminderGate.isPending(candidate) == true },
                         completion: { [weak self] succeeded in
                             guard let self else { return }
                             self.dailyReminderGate.complete(candidate, succeeded: succeeded, now: Date())
                         })
        }
    }

    private func submitBatteryReminder(_ candidate: ReminderNoticeCandidate, kind: BatteryReminderKind, percentage: Int) {
        let title: String
        let text: String
        switch kind {
        case .limit:
            title = "电量已达到上限"
            text = "当前电量 \(percentage)%，设定上限 \(Int(settings.limit))%。"
        case .lowBattery:
            title = "低电量提醒"
            text = "电量剩余 \(percentage)%，请连接电源。"
        }
        postReminder(identifier: "battery-reminder-\(candidate.id.uuidString)", title: title, text: text,
                     isCurrent: { [weak self] in
                         guard let self else { return false }
                         switch kind {
                         case .limit: return self.limitReminderGate.isPending(candidate)
                         case .lowBattery: return self.lowBatteryReminderGate.isPending(candidate)
                         }
                     }, willSubmit: { [weak self] in
                         guard let self else { return }
                         switch kind {
                         case .limit: self.limitReminderGate.markSubmitted(candidate)
                         case .lowBattery: self.lowBatteryReminderGate.markSubmitted(candidate)
                         }
                     }, completion: { [weak self] succeeded in
                         guard let self else { return }
                         switch kind {
                         case .limit: self.limitReminderGate.complete(candidate, succeeded: succeeded, now: Date())
                         case .lowBattery: self.lowBatteryReminderGate.complete(candidate, succeeded: succeeded, now: Date())
                         }
                     })
    }

    /// Both async boundaries recheck the current episode. An old completion
    /// must not consume a reminder after an option, threshold or date changes.
    private func postReminder(identifier: String, title: String, text: String,
                              isCurrent: @escaping () -> Bool, willSubmit: @escaping () -> Void = {},
                              completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.receiveNotificationSettings(info)
                _ = self.synchronizeReminderGates(self.monitor.snapshot, canNotify: false, now: Date())
                guard isCurrent(), self.notificationCanDeliver else { completion(false); return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = text
                if self.notificationSoundAllowed { content.sound = .default }
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                willSubmit()
                UNUserNotificationCenter.current().add(request) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        _ = self.synchronizeReminderGates(self.monitor.snapshot, canNotify: false, now: Date())
                        guard isCurrent() else { return }
                        completion(error == nil)
                        self.banner = error == nil ? text : "提醒暂未提交，将稍后重试。"
                    }
                }
            }
        }
    }

    private func handle(_ snapshot: BatterySnapshot) {
        guard !renderingOnly else { return }
        processTemperatureReminder(snapshot)
        if temporaryFull || chargeActions.pending != nil { refreshChargeState() }
        processBatteryReminders(snapshot)
        if let percentage = snapshot.percentage {
            if temporaryFull && !temporaryAwaitingConfirmation && temporaryRestoreEnabled != nil && percentage >= 100, let started = temporaryStarted, Date().timeIntervalSince(started) > 30,
               lastRestoreAttempt == nil || Date().timeIntervalSince(lastRestoreAttempt!) > 30 {
                lastRestoreAttempt = Date()
                _ = restoreTemporaryFull(automatically: true)
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }
}
