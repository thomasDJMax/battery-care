import Foundation

/// Bounds background authorization reads independently of reminder eligibility.
/// Uptime keeps changes to the user's wall clock from delaying permission recovery.
struct NotificationPermissionRefreshPolicy {
    private struct Request {
        let token: UUID
        var startedAt: TimeInterval
    }

    private let refreshInterval: TimeInterval = 60
    private let requestTimeout: TimeInterval = 120
    private var lastStartedAt: TimeInterval?
    private var lastObservedAt: TimeInterval?
    private var request: Request?

    mutating func begin(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        force: Bool = false
    ) -> UUID? {
        guard now.isFinite, now >= 0 else { return nil }

        // Uptime cannot normally move backward in one process. Rebase a supplied
        // clock reset defensively, retaining the in-flight exclusion and delay.
        if let lastObservedAt, now < lastObservedAt {
            if lastStartedAt != nil { lastStartedAt = now }
            if request != nil { request?.startedAt = now }
        }
        lastObservedAt = now

        if let request {
            guard now - request.startedAt >= requestTimeout else { return nil }
            self.request = nil
        }

        if !force, let lastStartedAt, now - lastStartedAt < refreshInterval {
            return nil
        }

        let token = UUID()
        request = Request(token: token, startedAt: now)
        lastStartedAt = now
        return token
    }

    /// Only the current request may publish its result. Late responses from a
    /// timed-out request cannot overwrite a newer authorization snapshot.
    @discardableResult
    mutating func complete(_ token: UUID) -> Bool {
        guard request?.token == token else { return false }
        request = nil
        return true
    }
}
