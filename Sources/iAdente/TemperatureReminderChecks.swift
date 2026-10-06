import Foundation

@MainActor
func runTemperatureReminderChecks() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func sample(_ temperature: Double?, at seconds: TimeInterval, hasBattery: Bool = true) -> BatterySnapshot {
        BatterySnapshot(hasBattery: hasBattery, temperature: temperature,
                        updatedAt: start.addingTimeInterval(seconds))
    }
    func consider(_ gate: inout TemperatureReminderGate, _ temperature: Double?, at seconds: TimeInterval,
                  threshold: Double = 40, enabled: Bool = true, canNotify: Bool = true,
                  sampleAt: TimeInterval? = nil, hasBattery: Bool = true) -> TemperatureNoticeCandidate? {
        gate.consider(snapshot: sample(temperature, at: sampleAt ?? seconds, hasBattery: hasBattery),
                      threshold: threshold, enabled: enabled, canNotify: canNotify,
                      now: start.addingTimeInterval(seconds))
    }

    // Two distinct samples, pending de-duplication, and one successful notice
    // per hot episode even after the time-based cooldown has expired.
    var gate = TemperatureReminderGate()
    precondition(consider(&gate, 40, at: 0) == nil)
    precondition(consider(&gate, 40, at: 1, sampleAt: 0) == nil)
    let first = consider(&gate, 41, at: 5)!
    precondition(first.temperature == 41)
    precondition(consider(&gate, 42, at: 10) == nil)
    precondition(gate.complete(first, succeeded: true, now: start.addingTimeInterval(10)))
    precondition(!gate.complete(first, succeeded: true, now: start.addingTimeInterval(11)))
    precondition(consider(&gate, 42, at: 620) == nil)
    precondition(consider(&gate, 42, at: 625) == nil)

    // Unknown samples do not represent cooling, and a duplicate low reading
    // cannot rearm the gate. Genuine cooling uses threshold minus three.
    precondition(consider(&gate, 37, at: 630) == nil)
    precondition(consider(&gate, 37, at: 631, sampleAt: 630) == nil)
    precondition(consider(&gate, nil, at: 635) == nil)
    precondition(consider(&gate, 20, at: 640, hasBattery: false) == nil)
    precondition(consider(&gate, 20, at: 645, sampleAt: 500) == nil)
    precondition(consider(&gate, 41, at: 650) == nil)
    precondition(consider(&gate, 41, at: 655) == nil)
    precondition(consider(&gate, 37, at: 660) == nil)
    precondition(consider(&gate, 37, at: 665) == nil)
    precondition(consider(&gate, 40, at: 670) == nil)
    let afterCooling = consider(&gate, 40, at: 675)!
    precondition(gate.complete(afterCooling, succeeded: true, now: start.addingTimeInterval(675)))

    // Rearming and cooldown are independent. A qualified new episode remains
    // eligible until exactly ten minutes after the preceding success.
    precondition(consider(&gate, 37, at: 680) == nil)
    precondition(consider(&gate, 37, at: 685) == nil)
    precondition(consider(&gate, 41, at: 1200) == nil)
    precondition(consider(&gate, 41, at: 1205) == nil)
    precondition(consider(&gate, 41, at: 1274) == nil)
    let afterCooldown = consider(&gate, 41, at: 1275)!
    precondition(gate.complete(afterCooldown, succeeded: true, now: start.addingTimeInterval(1275)))

    // Late permission does not consume the event or need to manufacture a new
    // distinct sample once two fresh high readings are already established.
    var permission = TemperatureReminderGate()
    precondition(consider(&permission, 41, at: 0, canNotify: false) == nil)
    precondition(consider(&permission, 41, at: 5, canNotify: false) == nil)
    let permitted = consider(&permission, 41, at: 10, sampleAt: 5)!
    precondition(permission.complete(permitted, succeeded: true, now: start.addingTimeInterval(10)))

    // A failed active submission retries at sixty seconds, leaves successful
    // history untouched, and cannot be completed later by the old token.
    var retry = TemperatureReminderGate()
    precondition(consider(&retry, 41, at: 0) == nil)
    let failed = consider(&retry, 41, at: 5)!
    precondition(!retry.complete(failed, succeeded: false, now: start.addingTimeInterval(10)))
    precondition(retry.lastNotifiedAt == nil)
    precondition(consider(&retry, 41, at: 69, sampleAt: 5) == nil)
    let retried = consider(&retry, 41, at: 70, sampleAt: 5)!
    precondition(retried.id != failed.id)
    precondition(!retry.complete(failed, succeeded: true, now: start.addingTimeInterval(70)))
    precondition(!retry.complete(failed, succeeded: false, now: start.addingTimeInterval(70)))
    precondition(consider(&retry, 41, at: 71, sampleAt: 5) == nil)
    precondition(retry.complete(retried, succeeded: true, now: start.addingTimeInterval(70)))

    // A saved success date preserves the minimum cooldown across a restart.
    var restarted = TemperatureReminderGate(lastNotifiedAt: start)
    precondition(consider(&restarted, 41, at: 500) == nil)
    precondition(consider(&restarted, 41, at: 505) == nil)
    precondition(consider(&restarted, 41, at: 599) == nil)
    let persistedCooldown = consider(&restarted, 41, at: 600)!
    precondition(restarted.complete(persistedCooldown, succeeded: true, now: start.addingTimeInterval(600)))

    var futureSuccess = TemperatureReminderGate(lastNotifiedAt: start.addingTimeInterval(60))
    precondition(consider(&futureSuccess, 41, at: 600) == nil)
    precondition(consider(&futureSuccess, 41, at: 605) == nil)
    precondition(consider(&futureSuccess, 41, at: 659) == nil)
    precondition(consider(&futureSuccess, 41, at: 660) != nil)

    // Disable and threshold changes invalidate pending callbacks before any
    // sample/permission early return, while retaining successful cooldown.
    var configuration = TemperatureReminderGate()
    precondition(consider(&configuration, 41, at: 0) == nil)
    let disabled = consider(&configuration, 41, at: 5)!
    precondition(consider(&configuration, nil, at: 10, enabled: false, canNotify: false) == nil)
    precondition(!configuration.complete(disabled, succeeded: true, now: start.addingTimeInterval(11)))
    precondition(consider(&configuration, 45, at: 15) == nil)
    let changed = consider(&configuration, 45, at: 20)!
    precondition(consider(&configuration, nil, at: 25, threshold: 45, canNotify: false) == nil)
    precondition(!configuration.complete(changed, succeeded: true, now: start.addingTimeInterval(26)))
    precondition(consider(&configuration, 45, at: 30, threshold: 45) == nil)
    let newThreshold = consider(&configuration, 45, at: 35, threshold: 45)!
    precondition(configuration.complete(newThreshold, succeeded: true, now: start.addingTimeInterval(35)))
    precondition(consider(&configuration, nil, at: 40, enabled: false) == nil)
    precondition(consider(&configuration, 41, at: 50) == nil)
    precondition(consider(&configuration, 41, at: 55) == nil)
    precondition(configuration.lastNotifiedAt == start.addingTimeInterval(35))

    // Invalid thresholds and unavailable/implausible temperatures cannot
    // qualify; rejected input is also unable to complete an obsolete token.
    var invalid = TemperatureReminderGate()
    for threshold in [Double.nan, .infinity, 34, 56] {
        precondition(consider(&invalid, 50, at: 0, threshold: threshold) == nil)
        precondition(consider(&invalid, 50, at: 5, threshold: threshold) == nil)
    }
    for temperature: Double? in [nil, .nan, .infinity, -.infinity, 0, -5, 90, 100] {
        precondition(consider(&invalid, temperature, at: 10) == nil)
    }
    precondition(consider(&invalid, 40, at: 15) == nil)
    let invalidated = consider(&invalid, 40, at: 20)!
    precondition(consider(&invalid, nil, at: 25, threshold: .nan) == nil)
    precondition(!invalid.complete(invalidated, succeeded: true, now: start.addingTimeInterval(30)))

    // Freshness is inclusive at 120s; an obviously future reading and older
    // out-of-order samples never supply another qualifying sample.
    var freshness = TemperatureReminderGate()
    precondition(consider(&freshness, 41, at: 121, sampleAt: 0) == nil)
    precondition(consider(&freshness, 41, at: 120.001, sampleAt: 0) == nil)
    precondition(consider(&freshness, 41, at: 0, sampleAt: 6) == nil)
    precondition(consider(&freshness, 41, at: 0) == nil)
    precondition(consider(&freshness, 41, at: 1, sampleAt: -1) == nil)
    let inclusiveFreshness = consider(&freshness, 41, at: 125, sampleAt: 5)!
    precondition(freshness.complete(inclusiveFreshness, succeeded: true, now: start.addingTimeInterval(125)))

    var futureTolerance = TemperatureReminderGate()
    precondition(consider(&futureTolerance, 41, at: 0, sampleAt: 5.001) == nil)
    precondition(consider(&futureTolerance, 41, at: 0, sampleAt: 5) == nil)
    precondition(consider(&futureTolerance, 41, at: 1, sampleAt: 6) != nil)

    // Both inclusive threshold endpoints work. A middle-band reading breaks
    // a consecutive high pair and also breaks a consecutive cooling pair.
    for threshold in [35.0, 55.0] {
        var endpoint = TemperatureReminderGate()
        precondition(consider(&endpoint, threshold, at: 0, threshold: threshold) == nil)
        precondition(consider(&endpoint, threshold, at: 5, threshold: threshold) != nil)
    }
    var consecutive = TemperatureReminderGate()
    precondition(consider(&consecutive, 41, at: 0) == nil)
    precondition(consider(&consecutive, 39, at: 5) == nil)
    precondition(consider(&consecutive, 41, at: 10) == nil)
    let consecutiveHigh = consider(&consecutive, 41, at: 15)!
    precondition(consecutive.complete(consecutiveHigh, succeeded: true, now: start.addingTimeInterval(15)))
    precondition(consider(&consecutive, 37, at: 620) == nil)
    precondition(consider(&consecutive, 39, at: 625) == nil)
    precondition(consider(&consecutive, 37, at: 630) == nil)
    precondition(consider(&consecutive, 41, at: 635) == nil)
    precondition(consider(&consecutive, 41, at: 640) == nil)

    // Pre-success cooling cannot partially rearm a successful episode. Only
    // two new low timestamps after the completion make it eligible again.
    var pendingCooling = TemperatureReminderGate()
    precondition(consider(&pendingCooling, 41, at: 0) == nil)
    let delayed = consider(&pendingCooling, 41, at: 5)!
    precondition(consider(&pendingCooling, 37, at: 10) == nil)
    precondition(pendingCooling.complete(delayed, succeeded: true, now: start.addingTimeInterval(11)))
    precondition(consider(&pendingCooling, 37, at: 12, sampleAt: 10) == nil)
    precondition(consider(&pendingCooling, 37, at: 15) == nil)
    precondition(consider(&pendingCooling, 41, at: 615) == nil)
    precondition(consider(&pendingCooling, 41, at: 620) == nil)
    precondition(consider(&pendingCooling, 37, at: 625) == nil)
    precondition(consider(&pendingCooling, 37, at: 630) == nil)
    precondition(consider(&pendingCooling, 41, at: 635) == nil)
    precondition(consider(&pendingCooling, 41, at: 640) != nil)

    // A sampling gap must not turn a single fresh high reading into two.
    var gap = TemperatureReminderGate()
    precondition(consider(&gap, 41, at: 0) == nil)
    precondition(consider(&gap, 41, at: 121) == nil)
    precondition(consider(&gap, 41, at: 126) != nil)

    print("Temperature reminder checks passed: distinct sampling, hysteresis, permissions, cooldown, retries and obsolete completions.")
}
