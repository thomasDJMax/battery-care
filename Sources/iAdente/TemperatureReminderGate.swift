import Foundation

struct TemperatureNoticeCandidate: Equatable, Sendable {
    let id: UUID
    let temperature: Double
}

/// Pure sampling and delivery state. The caller owns permissions, notification
/// submission and persistence, and must call consider when its settings change.
struct TemperatureReminderGate {
    private static let freshness: TimeInterval = 120
    private static let futureTolerance: TimeInterval = 5
    private static let cooldown: TimeInterval = 600
    private static let retryDelay: TimeInterval = 60

    private var configuredThreshold: Double?
    private var lastSampleAt: Date?
    private var lastTemperature: Double?
    private var hotSamples = 0
    private var coolSamples = 0
    private var armed = true
    private var pending: TemperatureNoticeCandidate?
    private var lastFailedAt: Date?
    private(set) var lastNotifiedAt: Date?
    private var lastObservedAt: Date?

    init(lastNotifiedAt: Date? = nil) {
        self.lastNotifiedAt = lastNotifiedAt.flatMap {
            $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil
        }
    }

    mutating func consider(snapshot: BatterySnapshot, threshold: Double, enabled: Bool,
                           canNotify: Bool, now: Date) -> TemperatureNoticeCandidate? {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        observeClock(now)
        // Configuration changes invalidate in-flight completions even when the
        // accompanying sample is unavailable. Successful cooldown survives.
        guard enabled, threshold.isFinite, (35...55).contains(threshold) else {
            resetEpisode()
            configuredThreshold = nil
            return nil
        }
        if configuredThreshold != threshold {
            resetEpisode()
            configuredThreshold = threshold
        }

        guard snapshot.hasBattery,
              let temperature = snapshot.temperature, temperature.isFinite,
              temperature > 0, temperature < 90,
              snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard age >= -Self.futureTolerance, age <= Self.freshness else { return nil }

        if let previous = lastSampleAt, snapshot.updatedAt < previous { return nil }
        if lastSampleAt != snapshot.updatedAt {
            // A long gap cannot provide the second consecutive reading. It
            // does not rearm an already-notified episode or cancel a delivery.
            if let previous = lastSampleAt,
               snapshot.updatedAt.timeIntervalSince(previous) > Self.freshness {
                hotSamples = 0
                coolSamples = 0
            }
            lastSampleAt = snapshot.updatedAt
            lastTemperature = temperature
            if temperature >= threshold {
                hotSamples = min(2, hotSamples + 1)
                coolSamples = 0
            } else if temperature <= threshold - 3 {
                hotSamples = 0
                coolSamples = min(2, coolSamples + 1)
                if coolSamples == 2 {
                    armed = true
                }
            } else {
                hotSamples = 0
                coolSamples = 0
            }
        }

        // A qualified event stays eligible while permission is unavailable,
        // cooldown runs, or a submission fails. A fresh duplicate may retry,
        // but can never contribute another high or low sample.
        guard canNotify, pending == nil, armed, hotSamples == 2,
              temperature >= threshold, let observedTemperature = lastTemperature,
              observedTemperature >= threshold else { return nil }
        if let lastNotifiedAt,
           now.timeIntervalSince(lastNotifiedAt) < Self.cooldown { return nil }
        if let lastFailedAt,
           now.timeIntervalSince(lastFailedAt) < Self.retryDelay { return nil }

        let candidate = TemperatureNoticeCandidate(id: UUID(), temperature: observedTemperature)
        pending = candidate
        return candidate
    }

    /// Returns true only for the successful completion of the current token.
    /// A failed or obsolete token never updates the persisted success date.
    mutating func complete(_ candidate: TemperatureNoticeCandidate, succeeded: Bool,
                           now: Date) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              pending?.id == candidate.id else { return false }
        observeClock(now)
        pending = nil
        if succeeded {
            lastNotifiedAt = now
            lastFailedAt = nil
            // Rearming requires two distinct cooling readings after success.
            // Keep lastSampleAt so an earlier reading cannot count again.
            armed = false
            hotSamples = 0
            coolSamples = 0
            return true
        }
        lastFailedAt = now
        return false
    }

    private mutating func resetEpisode() {
        lastSampleAt = nil
        lastTemperature = nil
        hotSamples = 0
        coolSamples = 0
        armed = true
        pending = nil
        lastFailedAt = nil
    }

    /// Wall-clock readings can move backwards after a manual change, a restored
    /// VM snapshot or a large NTP step. A sample or delivery stamp left in the
    /// future would otherwise drop every new sample and defer cooldown/retry
    /// until the old clock catches up, so rebase them onto the corrected clock.
    private mutating func observeClock(_ now: Date) {
        if let previous = lastObservedAt, now < previous {
            // Sample streaks counted on the old clock cannot be trusted.
            lastSampleAt = nil
            hotSamples = 0
            coolSamples = 0
        }
        lastObservedAt = now
        // lastNotifiedAt survives a restart, so it can still be in the future.
        if let notified = lastNotifiedAt, notified > now { lastNotifiedAt = now }
        if let failed = lastFailedAt, failed > now { lastFailedAt = now }
    }
}
