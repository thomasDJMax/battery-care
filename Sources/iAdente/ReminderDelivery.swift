import Foundation

struct ReminderNoticeCandidate: Equatable, Sendable {
    let id: UUID
}

/// Delivery state for one level-triggered reminder, such as low charge or the
/// charge limit. Permission and successful submission are separate: observing
/// the condition without permission must never consume the event.
struct ReminderDeliveryGate {
    private let defaults: UserDefaults?
    private let persistenceKey: String?
    private var configuredThreshold: Int?
    private var delivered = false
    private var pending: ReminderNoticeCandidate?
    private var pendingSubmitted = false
    private var lastFailedAt: Date?
    private var lastObservedAt: Date?

    init() {
        defaults = nil
        persistenceKey = nil
    }

    /// Persists the delivered flag and its threshold so one episode cannot
    /// notify twice when the app restarts while its condition still holds. The
    /// record is cleared as soon as the condition ends, the reminder is disabled
    /// or its threshold changes.
    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        persistenceKey = key
        let record = defaults.dictionary(forKey: key)
        delivered = record?["delivered"] as? Bool ?? false
        configuredThreshold = record?["threshold"] as? Int
    }

    mutating func consider(condition: Bool?, threshold: Int, enabled: Bool,
                           canNotify: Bool, now: Date) -> ReminderNoticeCandidate? {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            pending = nil
            pendingSubmitted = false
            return nil
        }
        observeClock(now)
        guard enabled else {
            resetEpisode()
            configuredThreshold = nil
            persistEpisode()
            return nil
        }
        if configuredThreshold != threshold {
            resetEpisode()
            configuredThreshold = threshold
            persistEpisode()
        }
        guard let condition else {
            // Missing telemetry cannot prove that the event ended. Cancel a
            // token awaiting permission, but retain an already submitted one
            // so its success can still prevent a later duplicate delivery.
            if !pendingSubmitted { pending = nil }
            return nil
        }
        guard condition else {
            resetEpisode()
            persistEpisode()
            return nil
        }
        guard canNotify, !delivered, pending == nil else { return nil }
        if let lastFailedAt, now.timeIntervalSince(lastFailedAt) < 60 { return nil }
        let candidate = ReminderNoticeCandidate(id: UUID())
        pending = candidate
        pendingSubmitted = false
        return candidate
    }

    func isPending(_ candidate: ReminderNoticeCandidate) -> Bool {
        pending?.id == candidate.id
    }

    /// Call immediately before submitting the request, after checking the
    /// current condition and settings. Unknown telemetry during the platform
    /// callback must not discard a success that has already been submitted.
    @discardableResult
    mutating func markSubmitted(_ candidate: ReminderNoticeCandidate) -> Bool {
        guard isPending(candidate) else { return false }
        pendingSubmitted = true
        return true
    }

    /// Call only after checking the latest settings and condition with
    /// consider(canNotify: false). An invalidated completion cannot consume a
    /// later event, including one with the same threshold.
    @discardableResult
    mutating func complete(_ candidate: ReminderNoticeCandidate, succeeded: Bool,
                           now: Date) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite, isPending(candidate) else { return false }
        observeClock(now)
        pending = nil
        pendingSubmitted = false
        if succeeded {
            delivered = true
            lastFailedAt = nil
            persistEpisode()
            return true
        }
        lastFailedAt = now
        return false
    }

    private mutating func resetEpisode() {
        delivered = false
        pending = nil
        pendingSubmitted = false
        lastFailedAt = nil
    }

    private func persistEpisode() {
        guard let defaults, let persistenceKey else { return }
        guard delivered || configuredThreshold != nil else {
            if defaults.object(forKey: persistenceKey) != nil {
                defaults.removeObject(forKey: persistenceKey)
            }
            return
        }
        var record: [String: Any] = [:]
        if delivered { record["delivered"] = true }
        if let configuredThreshold { record["threshold"] = configuredThreshold }
        defaults.set(record, forKey: persistenceKey)
    }

    private mutating func observeClock(_ now: Date) {
        // A backwards correction must not defer retry until the old wall clock
        // catches up. Begin a fresh sixty-second delay from the correction.
        if let previous = lastObservedAt, now < previous, lastFailedAt != nil {
            lastFailedAt = now
        }
        lastObservedAt = now
    }
}

struct DailyReminderCandidate: Equatable, Sendable {
    let id: UUID
    let dayKey: String
    var identifier: String { "battery-care-daily-\(dayKey)" }
}

/// Daily delivery history uses Gregorian local civil dates rather than the
/// preferred display calendar or current process lifetime. A stable request
/// identifier also lets the notification center replace a pending request for
/// the same date.
struct DailyReminderDeliveryGate {
    private struct Schedule: Equatable {
        let hour: Int
        let minute: Int
    }

    private let defaults: UserDefaults
    private let persistenceKey: String
    private static let historyLimit = 366
    private var deliveredDays: [String]
    private var schedule: Schedule?
    private var activeDay: String?
    private var pending: DailyReminderCandidate?
    private var lastFailedAt: Date?
    private var lastObservedAt: Date?

    init(defaults: UserDefaults, key: String = "dailyReminderDeliveredDays") {
        self.defaults = defaults
        persistenceKey = key
        deliveredDays = Array((defaults.stringArray(forKey: key) ?? []).suffix(Self.historyLimit))
    }

    mutating func consider(enabled: Bool, hour: Int, minute: Int, canNotify: Bool,
                           now: Date, calendar: Calendar = .current) -> DailyReminderCandidate? {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            pending = nil
            return nil
        }
        observeClock(now)
        guard enabled, (0...23).contains(hour), (0...59).contains(minute) else {
            resetEpisode()
            schedule = nil
            return nil
        }
        let configured = Schedule(hour: hour, minute: minute)
        if schedule != configured {
            resetEpisode()
            schedule = configured
        }
        let day = Self.dayKey(for: now, calendar: calendar)
        if let activeDay, activeDay != day { resetEpisode() }
        refreshDeliveredDays()
        guard !deliveredDays.contains(day) else {
            resetEpisode()
            return nil
        }
        let components = Self.civilCalendar(timeZone: calendar.timeZone)
            .dateComponents([.hour, .minute], from: now)
        guard let currentHour = components.hour, let currentMinute = components.minute else { return nil }
        let dueMinute = currentHour == hour && currentMinute == minute
        let atOrAfterDue = currentHour > hour || (currentHour == hour && currentMinute >= minute)
        guard atOrAfterDue else {
            // The clock can return to an earlier time in the same day while a
            // request is pending. Its completion must no longer count.
            pending = nil
            return nil
        }
        if dueMinute { activeDay = day }
        // Once activated, unavailable permission or a failed submission can
        // retry after the configured minute, but only within the same date.
        guard activeDay == day, canNotify, pending == nil else { return nil }
        if let lastFailedAt, now.timeIntervalSince(lastFailedAt) < 60 { return nil }
        let candidate = DailyReminderCandidate(id: UUID(), dayKey: day)
        pending = candidate
        return candidate
    }

    func isPending(_ candidate: DailyReminderCandidate) -> Bool {
        pending?.id == candidate.id
    }

    /// The caller first synchronizes the latest settings with consider. Only
    /// a successful submission for the still-current date is persisted.
    @discardableResult
    mutating func complete(_ candidate: DailyReminderCandidate, succeeded: Bool,
                           now: Date, calendar: Calendar = .current) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite, isPending(candidate) else { return false }
        guard candidate.dayKey == Self.dayKey(for: now, calendar: calendar) else {
            resetEpisode()
            return false
        }
        observeClock(now)
        pending = nil
        if succeeded {
            refreshDeliveredDays()
            deliveredDays.removeAll { $0 == candidate.dayKey }
            deliveredDays.append(candidate.dayKey)
            deliveredDays = Array(deliveredDays.suffix(Self.historyLimit))
            defaults.set(deliveredDays, forKey: persistenceKey)
            lastFailedAt = nil
            return true
        }
        lastFailedAt = now
        return false
    }

    private mutating func resetEpisode() {
        activeDay = nil
        pending = nil
        lastFailedAt = nil
    }

    private mutating func refreshDeliveredDays() {
        // Retain insertion order: clock corrections can revisit an older date,
        // so lexical date order is not the same as recent successful delivery.
        for day in defaults.stringArray(forKey: persistenceKey) ?? [] {
            if !deliveredDays.contains(day) { deliveredDays.append(day) }
        }
        deliveredDays = Array(deliveredDays.suffix(Self.historyLimit))
    }

    private mutating func observeClock(_ now: Date) {
        if let previous = lastObservedAt, now < previous, lastFailedAt != nil {
            lastFailedAt = now
        }
        lastObservedAt = now
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = civilCalendar(timeZone: calendar.timeZone)
            .dateComponents([.era, .year, .month, .day], from: date)
        // Keep the existing Gregorian spelling so 1.3.4 delivery records still
        // suppress a second notification after upgrading. Legacy display-
        // calendar keys remain stored, but cannot be safely translated: a
        // Chinese key omits the leap-month bit and may mean two distinct days.
        return "gregorian-\(parts.era ?? 0)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private static func civilCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
