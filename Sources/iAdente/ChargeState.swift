import Foundation

/// Normalize persisted values before they reach sliders, integer conversions or timers.
enum AppSettingBounds {
    static func number(_ value: Double, range: ClosedRange<Double>, fallback: Double, rounded: Bool = false) -> Double {
        guard value.isFinite else { return fallback }
        let bounded = min(range.upperBound, max(range.lowerBound, value))
        return rounded ? bounded.rounded() : bounded
    }
    static func lowBattery(_ value: Double) -> Double { number(value, range: 5...40, fallback: 20, rounded: true) }
    static func limit(_ value: Double) -> Double { number(value, range: 1...100, fallback: 100, rounded: true) }
    static func temperature(_ value: Double) -> Double { number(value, range: 35...55, fallback: 40, rounded: true) }
    static func refresh(_ value: Double) -> Double { number(value, range: 2...60, fallback: 5) }
    static func hour(_ value: Int) -> Int { min(23, max(0, value)) }
    static func minute(_ value: Int) -> Int { min(59, max(0, value)) }
}

enum ChargeAction: Equatable {
    case limit(Int)
    case systemManagement

    func isConfirmed(by readback: ChargeLimitReadback) -> Bool {
        switch self {
        case .limit(let limit): return readback.confirms(limit)
        case .systemManagement: return readback.known && !readback.enabled
        }
    }
}

/// A new accepted action supersedes the previous action, including a delayed disable.
struct ChargeActionTracker {
    private(set) var pending: ChargeAction?
    mutating func submitted(_ action: ChargeAction, confirmed: Bool) { pending = confirmed ? nil : action }
    mutating func clear() { pending = nil }
    mutating func confirm(_ readback: ChargeLimitReadback) -> ChargeAction? {
        guard let action = pending, action.isConfirmed(by: readback) else { return nil }
        pending = nil
        return action
    }
}

struct TemporaryChargeSession: Codable, Equatable {
    enum Phase: String, Codable { case prepared, awaitingFullConfirmation, charging, restoring }
    var version = 1
    var originalLimit: Int
    // A missing legacy flag is not equivalent to disabled charging management.
    var originalEnabled: Bool?
    var startedAt: Date
    var phase: Phase
    var automaticCompletionNoticePending = false

    var isValid: Bool { version == 1 && (1...100).contains(originalLimit) && startedAt.timeIntervalSinceReferenceDate.isFinite }
    var awaitingFullConfirmation: Bool { phase == .prepared || phase == .awaitingFullConfirmation }
    func confirmsRestoration(_ readback: ChargeLimitReadback) -> Bool {
        guard let enabled = originalEnabled else { return false }
        return readback.confirmsRestore(limit: originalLimit, enabled: enabled)
    }
}

struct TemporarySessionLoad {
    var session: TemporaryChargeSession?
    var warning: String?
}

/// A single atomic file is written and read back before changing hardware. Legacy
/// preferences are removed only after the complete replacement record is verified.
final class TemporaryChargeSessionStore {
    private let url: URL
    private let defaults: UserDefaults
    private let removeRecord: (URL) throws -> Void
    private static let legacyKeys = ["temporaryRestoreLimit", "temporaryRestoreEnabled", "temporaryStartedAt", "temporaryAwaitingConfirmation", "temporaryRestorePending"]

    init(url: URL? = nil, defaults: UserDefaults = .standard,
         removeRecord: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.defaults = defaults
        self.removeRecord = removeRecord
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cn.local.iadente.remake", isDirectory: true)
            .appendingPathComponent("temporary-charge-session.json")
    }

    func save(_ session: TemporaryChargeSession) throws {
        guard session.isValid else { throw CocoaError(.coderInvalidValue) }
        let data = try JSONEncoder().encode(session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let verified = try JSONDecoder().decode(TemporaryChargeSession.self, from: Data(contentsOf: url))
        guard verified == session else { throw CocoaError(.fileWriteUnknown) }
    }

    func load(now: Date = Date()) -> TemporarySessionLoad {
        var damagedRecord = false
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let session = try JSONDecoder().decode(TemporaryChargeSession.self, from: Data(contentsOf: url))
                guard session.isValid else { throw CocoaError(.coderInvalidValue) }
                removeLegacyKeys()
                return TemporarySessionLoad(session: session)
            } catch { damagedRecord = true }
        }
        guard let limit = defaults.object(forKey: "temporaryRestoreLimit") as? Int, (1...100).contains(limit) else {
            let hasLegacy = Self.legacyKeys.contains { defaults.object(forKey: $0) != nil }
            return TemporarySessionLoad(warning: damagedRecord || hasLegacy ? "临时充满恢复记录不完整，已保留原记录；请在系统电池设置中确认充电上限。" : nil)
        }
        let enabled = defaults.object(forKey: "temporaryRestoreEnabled") as? Bool
        let phase: TemporaryChargeSession.Phase = defaults.bool(forKey: "temporaryRestorePending") ? .restoring :
            (defaults.bool(forKey: "temporaryAwaitingConfirmation") ? .awaitingFullConfirmation : .charging)
        let session = TemporaryChargeSession(originalLimit: limit, originalEnabled: enabled,
            startedAt: defaults.object(forKey: "temporaryStartedAt") as? Date ?? now, phase: phase)
        do {
            try save(session)
            removeLegacyKeys()
            return TemporarySessionLoad(session: session, warning: enabled == nil ? "原上限已保留，但旧记录缺少恢复方式；请在系统电池设置中确认。" : nil)
        } catch {
            return TemporarySessionLoad(session: session, warning: "暂时无法保存新的恢复记录，旧记录已保留。")
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try removeRecord(url) }
        removeLegacyKeys()
    }
    func completeRestoration(_ session: TemporaryChargeSession) throws -> Bool {
        // The caller gets permission to notify only after the durable marker is
        // consumed. A removal error returns no permission and keeps the record.
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let current = try JSONDecoder().decode(TemporaryChargeSession.self, from: Data(contentsOf: url))
        guard current.isValid && current == session else { throw CocoaError(.fileReadCorruptFile) }
        try clear()
        return session.automaticCompletionNoticePending
    }
    private func removeLegacyKeys() { Self.legacyKeys.forEach { defaults.removeObject(forKey: $0) } }
}

@MainActor
func runChargeStateChecks() {
    precondition(AppSettingBounds.lowBattery(.nan) == 20 && AppSettingBounds.lowBattery(.infinity) == 20)
    precondition(AppSettingBounds.limit(.nan) == 100 && AppSettingBounds.temperature(.infinity) == 40)
    precondition(AppSettingBounds.lowBattery(-20) == 5 && AppSettingBounds.lowBattery(100) == 40)
    precondition(AppSettingBounds.refresh(.nan) == 5 && AppSettingBounds.refresh(-2) == 2 && AppSettingBounds.refresh(500) == 60)
    precondition(AppSettingBounds.hour(-1) == 0 && AppSettingBounds.hour(24) == 23)
    precondition(AppSettingBounds.minute(-1) == 0 && AppSettingBounds.minute(60) == 59)
    var tracker = ChargeActionTracker()
    tracker.submitted(.limit(80), confirmed: false)
    tracker.submitted(.systemManagement, confirmed: false)
    precondition(tracker.confirm(ChargeLimitReadback(known: true, enabled: true, limit: 80)) == nil)
    precondition(tracker.confirm(ChargeLimitReadback(known: false, enabled: false, limit: nil)) == nil)
    precondition(tracker.confirm(ChargeLimitReadback(known: true, enabled: false, limit: 100)) == .systemManagement)
    precondition(tracker.confirm(ChargeLimitReadback(known: true, enabled: false, limit: 100)) == nil)
    tracker.submitted(.limit(90), confirmed: false)
    precondition(tracker.confirm(ChargeLimitReadback(known: true, enabled: true, limit: 90)) == .limit(90))

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryCare-state-check-\(UUID().uuidString)")
    let suiteName = "BatteryCare-state-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName); try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("session.json")
    let store = TemporaryChargeSessionStore(url: url, defaults: defaults)
    do {
        defaults.set(Double.nan, forKey: "lowBatteryThreshold")
        defaults.set(Double.infinity, forKey: "refreshInterval")
        defaults.set(30, forKey: "scheduleHour"); defaults.set(-10, forKey: "scheduleMinute")
        let settings = AppSettings(store: defaults)
        precondition(settings.lowBatteryThreshold == 20 && settings.refreshInterval == 5)
        precondition(settings.scheduleHour == 23 && settings.scheduleMinute == 0)
        settings.lowBatteryThreshold = .infinity; settings.refreshInterval = .nan
        settings.scheduleHour = -5; settings.scheduleMinute = 100
        settings.limit = .nan; settings.highTemperatureThreshold = .infinity
        precondition(settings.lowBatteryThreshold == 20 && settings.refreshInterval == 5)
        precondition(settings.scheduleHour == 0 && settings.scheduleMinute == 59)
        precondition(settings.limit == 100 && settings.highTemperatureThreshold == 40)
        precondition(defaults.double(forKey: "lowBatteryThreshold") == 20 && defaults.double(forKey: "refreshInterval") == 5)
        let prepared = TemporaryChargeSession(originalLimit: 80, originalEnabled: true, startedAt: Date(), phase: .prepared)
        try store.save(prepared)
        precondition(store.load().session == prepared) // A restart between persistence and hardware submission retains the recovery point.
        var restoring = prepared
        restoring.phase = .restoring
        restoring.automaticCompletionNoticePending = true
        try store.save(restoring)
        precondition(!restoring.confirmsRestoration(ChargeLimitReadback(known: false, enabled: false, limit: nil)))
        precondition(!restoring.confirmsRestoration(ChargeLimitReadback(known: true, enabled: true, limit: 100)))
        let confirmed = store.load().session!
        precondition(confirmed.confirmsRestoration(ChargeLimitReadback(known: true, enabled: true, limit: 80)))
        precondition(confirmed.automaticCompletionNoticePending)
        var stale = confirmed
        stale.originalLimit = 85
        do {
            _ = try store.completeRestoration(stale)
            preconditionFailure("A mismatched session must not delete the current recovery record")
        } catch { precondition(store.load().session == confirmed) }
        let failingCleanup = TemporaryChargeSessionStore(url: url, defaults: defaults,
            removeRecord: { _ in throw CocoaError(.fileWriteNoPermission) })
        var notices = 0
        do {
            if try failingCleanup.completeRestoration(confirmed) { notices += 1 }
            preconditionFailure("Expected a cleanup failure")
        } catch { precondition(notices == 0 && store.load().session == confirmed) }
        if try store.completeRestoration(confirmed) { notices += 1 }
        precondition(notices == 1 && store.load().session == nil)
        let repeatedNotice = try store.completeRestoration(confirmed)
        precondition(!repeatedNotice) // A direct repeated call with the stale session cannot consume a missing record.
        if let repeated = store.load().session, try store.completeRestoration(repeated) { notices += 1 }
        precondition(notices == 1) // A failed cleanup never authorizes a notice; a successful retry authorizes exactly one.
        defaults.set(85, forKey: "temporaryRestoreLimit")
        defaults.set(true, forKey: "temporaryRestoreEnabled")
        defaults.set(true, forKey: "temporaryRestorePending")
        let migrated = store.load().session!
        precondition(migrated.originalLimit == 85 && migrated.originalEnabled == true && migrated.phase == .restoring)
        precondition(defaults.object(forKey: "temporaryRestoreLimit") == nil && store.load().session == migrated)
        try store.clear()
        defaults.set(90, forKey: "temporaryRestoreLimit")
        let incomplete = store.load().session!
        precondition(incomplete.originalEnabled == nil)
        precondition(!incomplete.confirmsRestoration(ChargeLimitReadback(known: true, enabled: false, limit: 100)))
        try store.clear()
        try Data("broken".utf8).write(to: url)
        precondition(store.load().session == nil && store.load().warning != nil)
        precondition(FileManager.default.fileExists(atPath: url.path))
        // A failed migration preserves every old key, instead of erasing recovery data.
        let blockedURL = directory.appendingPathComponent("blocked")
        try Data().write(to: blockedURL)
        let blocked = TemporaryChargeSessionStore(url: blockedURL.appendingPathComponent("session.json"), defaults: defaults)
        defaults.set(80, forKey: "temporaryRestoreLimit"); defaults.set(true, forKey: "temporaryRestoreEnabled")
        precondition(blocked.load().session?.originalLimit == 80)
        precondition(defaults.object(forKey: "temporaryRestoreLimit") != nil)
    } catch { preconditionFailure("Charge state persistence checks failed: \(error)") }
    print("Charge state checks passed: bounded preferences, delayed disable confirmation, single completion, atomic recovery records and conservative legacy migration. No native writes or notifications.")
}
