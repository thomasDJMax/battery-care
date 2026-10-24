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
            if damagedRecord {
                // An unreadable record can never restore anything, and keeping it
                // would repeat this warning on every launch. The file and the
                // legacy keys both failed to produce a session, so remove the
                // unusable file; the user is still told to check the system cap.
                do {
                    try removeRecord(url)
                    return TemporarySessionLoad(warning: "临时充满恢复记录已损坏，已清除；请在系统电池设置中确认充电上限。")
                } catch {
                    return TemporarySessionLoad(warning: "临时充满恢复记录已损坏且无法清除；请在系统电池设置中确认充电上限。")
                }
            }
            let hasLegacy = Self.legacyKeys.contains { defaults.object(forKey: $0) != nil }
            return TemporarySessionLoad(warning: hasLegacy ? "临时充满恢复记录不完整，已保留原记录；请在系统电池设置中确认充电上限。" : nil)
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
    /// Consume only an exact legacy recovery point after explicit manual confirmation.
    /// This never infers an original management mode or authorizes a hardware write.
    func acknowledgeLegacyRecovery(_ session: TemporaryChargeSession, readback: ChargeLimitReadback) throws {
        guard readback.known, session.isValid, session.originalEnabled == nil else {
            throw CocoaError(.coderInvalidValue)
        }
        // Read failure, a missing record, or a different recovery point must leave
        // the active lock intact. Cleanup failure likewise remains retryable.
        let current = try JSONDecoder().decode(TemporaryChargeSession.self, from: Data(contentsOf: url))
        guard current.isValid, current.originalEnabled == nil, current == session else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try clear()
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
        let unknownReadback = ChargeLimitReadback(known: false, enabled: false, limit: nil)
        let systemReadback = ChargeLimitReadback(known: true, enabled: false, limit: 100)
        do {
            try store.acknowledgeLegacyRecovery(incomplete, readback: unknownReadback)
            preconditionFailure("Unknown system state cannot acknowledge manual recovery")
        } catch { precondition(store.load().session == incomplete) }
        var mismatchedLegacy = incomplete
        mismatchedLegacy.originalLimit = 80
        do {
            try store.acknowledgeLegacyRecovery(mismatchedLegacy, readback: systemReadback)
            preconditionFailure("A stale legacy confirmation cannot clear the active recovery record")
        } catch { precondition(store.load().session == incomplete) }
        do {
            try failingCleanup.acknowledgeLegacyRecovery(incomplete, readback: systemReadback)
            preconditionFailure("Legacy cleanup failure must remain retryable")
        } catch { precondition(store.load().session == incomplete) }
        // The user's current setting can differ from the saved limit: we preserve
        // their explicit manual choice, rather than infer a missing original flag.
        try store.acknowledgeLegacyRecovery(incomplete, readback: systemReadback)
        precondition(store.load().session == nil && defaults.object(forKey: "temporaryRestoreLimit") == nil)
        for readback in [ChargeLimitReadback(known: true, enabled: true, limit: 80),
                         ChargeLimitReadback(known: true, enabled: true, limit: 90)] {
            try store.save(incomplete)
            try store.acknowledgeLegacyRecovery(incomplete, readback: readback)
            precondition(store.load().session == nil)
        }
        try store.save(prepared)
        do {
            try store.acknowledgeLegacyRecovery(prepared, readback: systemReadback)
            preconditionFailure("A complete recovery record cannot be dismissed as legacy")
        } catch { precondition(store.load().session == prepared) }
        try store.clear()
        try Data("broken".utf8).write(to: url)
        let damaged = store.load()
        precondition(damaged.session == nil && damaged.warning != nil)
        // An unreadable record holds no recovery point: remove it instead of
        // repeating the warning on every launch.
        precondition(!FileManager.default.fileExists(atPath: url.path))
        precondition(store.load().warning == nil && store.load().session == nil)
        // A failed cleanup keeps both the file and the warning for a later retry.
        try Data("broken".utf8).write(to: url)
        let stuckCleanup = TemporaryChargeSessionStore(url: url, defaults: defaults,
            removeRecord: { _ in throw CocoaError(.fileWriteNoPermission) })
        precondition(stuckCleanup.load().session == nil && stuckCleanup.load().warning != nil)
        precondition(FileManager.default.fileExists(atPath: url.path))
        // A valid legacy recovery point is migrated over the damaged file rather
        // than being discarded with it.
        defaults.set(70, forKey: "temporaryRestoreLimit")
        defaults.set(true, forKey: "temporaryRestoreEnabled")
        let migratedOverDamaged = store.load()
        precondition(migratedOverDamaged.session?.originalLimit == 70 && migratedOverDamaged.warning == nil)
        precondition(FileManager.default.fileExists(atPath: url.path))
        try store.clear()
        // A failed migration preserves every old key, instead of erasing recovery data.
        let blockedURL = directory.appendingPathComponent("blocked")
        try Data().write(to: blockedURL)
        let blocked = TemporaryChargeSessionStore(url: blockedURL.appendingPathComponent("session.json"), defaults: defaults)
        defaults.set(80, forKey: "temporaryRestoreLimit"); defaults.set(true, forKey: "temporaryRestoreEnabled")
        precondition(blocked.load().session?.originalLimit == 80)
        precondition(defaults.object(forKey: "temporaryRestoreLimit") != nil)
    } catch { preconditionFailure("Charge state persistence checks failed: \(error)") }
    print("Charge state checks passed: bounded preferences, delayed disable confirmation, single completion, atomic recovery records, damaged-record cleanup, conservative legacy migration and explicit manual legacy acknowledgement. No native writes or notifications.")
}
