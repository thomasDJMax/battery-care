import Foundation

func runNotificationPermissionRefreshChecks() {
    // A background poll obtains settings even when no reminder can be created.
    // Subsequent two-second battery samples cannot query the system repeatedly.
    var background = NotificationPermissionRefreshPolicy()
    let initial = background.begin(now: 1_000)!
    precondition(background.complete(initial))
    for seconds in stride(from: 2.0, through: 58.0, by: 2.0) {
        precondition(background.begin(now: 1_000 + seconds) == nil)
    }
    precondition(background.begin(now: 1_059.999) == nil)
    let periodic = background.begin(now: 1_060)!
    precondition(periodic != initial)
    precondition(background.complete(periodic))
    precondition(!background.complete(initial))

    // A visible UI or wake event may bypass the interval, while simultaneous
    // forced and periodic refreshes share the same in-flight request.
    let visible = background.begin(now: 1_061, force: true)!
    precondition(background.begin(now: 1_061, force: true) == nil)
    precondition(background.begin(now: 1_119) == nil)
    precondition(!background.complete(UUID()))
    precondition(background.begin(now: 1_119, force: true) == nil)
    precondition(background.complete(visible))
    precondition(background.begin(now: 1_120.999) == nil)
    let next = background.begin(now: 1_121)!
    precondition(background.complete(next))

    // A system callback that never arrives must not disable refresh forever.
    // Its late completion cannot consume or overwrite the replacement request.
    var stalled = NotificationPermissionRefreshPolicy()
    let expired = stalled.begin(now: 200)!
    for seconds in [1.0, 59, 60, 119.999] {
        precondition(stalled.begin(now: 200 + seconds, force: true) == nil)
    }
    let replacement = stalled.begin(now: 320)!
    precondition(replacement != expired)
    precondition(!stalled.complete(expired))
    precondition(stalled.begin(now: 321, force: true) == nil)
    precondition(stalled.complete(replacement))
    precondition(!stalled.complete(replacement))

    // Invalid injected clocks leave the pending request and throttle intact.
    var invalid = NotificationPermissionRefreshPolicy()
    for time in [Double.nan, Double.infinity, -Double.infinity, -1.0] {
        precondition(invalid.begin(now: time, force: true) == nil)
    }
    let valid = invalid.begin(now: 0)!
    precondition(invalid.begin(now: .nan, force: true) == nil)
    precondition(invalid.begin(now: .infinity, force: true) == nil)
    precondition(invalid.complete(valid))
    precondition(invalid.begin(now: 59.999) == nil)
    let afterInvalid = invalid.begin(now: 60)!
    precondition(invalid.complete(afterInvalid))

    // A defensive monotonic-clock reset rebases the lease instead of flooding
    // requests or postponing them until the old absolute timestamp is reached.
    var reset = NotificationPermissionRefreshPolicy()
    let beforeReset = reset.begin(now: 10_000)!
    precondition(reset.begin(now: 10, force: true) == nil)
    precondition(reset.begin(now: 129.999, force: true) == nil)
    let afterReset = reset.begin(now: 130)!
    precondition(!reset.complete(beforeReset))
    precondition(reset.complete(afterReset))

    var completedReset = NotificationPermissionRefreshPolicy()
    let completed = completedReset.begin(now: 10_000)!
    precondition(completedReset.complete(completed))
    precondition(completedReset.begin(now: 10) == nil)
    precondition(completedReset.begin(now: 69.999) == nil)
    let rebased = completedReset.begin(now: 70)!
    precondition(completedReset.complete(rebased))
}
