import Foundation

@MainActor
func runReminderDeliveryChecks() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    func consider(_ gate: inout ReminderDeliveryGate, _ seconds: TimeInterval,
                  condition: Bool? = true, threshold: Int = 20, enabled: Bool = true,
                  canNotify: Bool = true) -> ReminderNoticeCandidate? {
        gate.consider(condition: condition, threshold: threshold, enabled: enabled,
                      canNotify: canNotify, now: at(seconds))
    }

    // Observing a low battery/charge-limit event while disabled or denied does
    // not consume it. Duplicate samples cannot submit concurrent requests.
    for threshold in [20, 80, 90, 100] {
        var gate = ReminderDeliveryGate()
        precondition(consider(&gate, 0, threshold: threshold, enabled: false) == nil)
        precondition(consider(&gate, 1, threshold: threshold, canNotify: false) == nil)
        let enabled = consider(&gate, 2, threshold: threshold)!
        precondition(consider(&gate, 2, threshold: threshold) == nil)
        precondition(gate.complete(enabled, succeeded: true, now: at(3)))
        precondition(!gate.complete(enabled, succeeded: true, now: at(3)))
        precondition(consider(&gate, 4, threshold: threshold) == nil)
        precondition(consider(&gate, 5, condition: nil, threshold: threshold) == nil)
        precondition(consider(&gate, 6, threshold: threshold) == nil)
        precondition(consider(&gate, 3_600, threshold: threshold) == nil)
        precondition(consider(&gate, 3_601, condition: false, threshold: threshold) == nil)
        precondition(consider(&gate, 3_602, threshold: threshold) != nil)
    }

    // Submission failures retry only at or after sixty seconds. Repeated
    // failures each start a new delay, and obsolete callbacks remain inert.
    var retry = ReminderDeliveryGate()
    let failed = consider(&retry, 0)!
    precondition(!retry.complete(failed, succeeded: false, now: at(1)))
    precondition(consider(&retry, 60.999) == nil)
    let retried = consider(&retry, 61)!
    precondition(retried.id != failed.id)
    precondition(!retry.complete(failed, succeeded: true, now: at(61)))
    precondition(consider(&retry, 61) == nil)
    precondition(!retry.complete(retried, succeeded: false, now: at(62)))
    precondition(consider(&retry, 121.999) == nil)
    let success = consider(&retry, 122)!
    precondition(retry.complete(success, succeeded: true, now: at(123)))
    precondition(consider(&retry, 10_000) == nil)

    // Disable, condition recovery and threshold changes invalidate in-flight
    // completions even with unavailable permission. A new event stays live.
    var configuration = ReminderDeliveryGate()
    let disabled = consider(&configuration, 0)!
    precondition(consider(&configuration, 1, enabled: false, canNotify: false) == nil)
    precondition(!configuration.complete(disabled, succeeded: true, now: at(2)))
    let recovered = consider(&configuration, 3)!
    precondition(consider(&configuration, 4, condition: false, canNotify: false) == nil)
    precondition(!configuration.complete(recovered, succeeded: true, now: at(5)))
    let changed = consider(&configuration, 6)!
    precondition(consider(&configuration, 7, threshold: 25, canNotify: false) == nil)
    precondition(!configuration.complete(changed, succeeded: true, now: at(8)))
    let newThreshold = consider(&configuration, 9, threshold: 25)!
    precondition(configuration.complete(newThreshold, succeeded: true, now: at(10)))
    var missingSample = ReminderDeliveryGate()
    let invalidatedByMissing = consider(&missingSample, 0)!
    precondition(consider(&missingSample, 1, condition: nil) == nil)
    precondition(!missingSample.complete(invalidatedByMissing, succeeded: true, now: at(2)))
    precondition(consider(&missingSample, 3) != nil)

    // Once submission begins, missing telemetry cannot erase its successful
    // completion or cause a duplicate when the next valid sample arrives.
    var submitted = ReminderDeliveryGate()
    let submittedToken = consider(&submitted, 0)!
    precondition(submitted.markSubmitted(submittedToken))
    precondition(consider(&submitted, 1, condition: nil) == nil)
    precondition(submitted.isPending(submittedToken))
    precondition(submitted.complete(submittedToken, succeeded: true, now: at(2)))
    precondition(consider(&submitted, 3) == nil)
    precondition(!submitted.markSubmitted(submittedToken))

    // Unknown readings during a failed submission must also retain its failure
    // timestamp, so restored telemetry still observes the sixty-second delay.
    var submittedFailure = ReminderDeliveryGate()
    let submittedFailureToken = consider(&submittedFailure, 0)!
    precondition(submittedFailure.markSubmitted(submittedFailureToken))
    precondition(consider(&submittedFailure, 1, condition: nil) == nil)
    precondition(!submittedFailure.complete(submittedFailureToken, succeeded: false, now: at(2)))
    precondition(consider(&submittedFailure, 3, condition: nil) == nil)
    precondition(consider(&submittedFailure, 61.999) == nil)
    precondition(consider(&submittedFailure, 62) != nil)

    // Actual condition recovery, disabling or threshold changes still cancel
    // submitted tokens; a late success cannot consume the next episode.
    var submittedRecovery = ReminderDeliveryGate()
    let oldSubmission = consider(&submittedRecovery, 0)!
    precondition(submittedRecovery.markSubmitted(oldSubmission))
    precondition(consider(&submittedRecovery, 1, condition: false) == nil)
    precondition(!submittedRecovery.complete(oldSubmission, succeeded: true, now: at(2)))
    let freshSubmission = consider(&submittedRecovery, 3)!
    precondition(submittedRecovery.markSubmitted(freshSubmission))
    precondition(consider(&submittedRecovery, 4, enabled: false) == nil)
    precondition(!submittedRecovery.complete(freshSubmission, succeeded: true, now: at(5)))

    // Wall-clock correction cannot leave failures blocked until a far-future
    // old timestamp. Non-finite clocks do not generate or complete requests.
    var clock = ReminderDeliveryGate()
    let beforeCorrection = consider(&clock, 1_000)!
    precondition(!clock.complete(beforeCorrection, succeeded: false, now: at(1_001)))
    precondition(consider(&clock, 100) == nil)
    precondition(consider(&clock, 159.999) == nil)
    let afterCorrection = consider(&clock, 160)!
    precondition(!clock.complete(afterCorrection, succeeded: true, now: Date(timeIntervalSinceReferenceDate: .nan)))
    precondition(clock.complete(afterCorrection, succeeded: true, now: at(160)))
    var invalid = ReminderDeliveryGate()
    precondition(invalid.consider(condition: true, threshold: 20, enabled: true,
                                  canNotify: true, now: Date(timeIntervalSinceReferenceDate: .infinity)) == nil)

    let suiteName = "BatteryCare.ReminderDeliveryChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
    func date(day: Int = 15, hour: Int = 9, minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }
    func daily(_ gate: inout DailyReminderDeliveryGate, _ now: Date,
               enabled: Bool = true, hour: Int = 9, minute: Int = 0,
               canNotify: Bool = true) -> DailyReminderCandidate? {
        gate.consider(enabled: enabled, hour: hour, minute: minute,
                      canNotify: canNotify, now: now, calendar: calendar)
    }

    var dailyGate = DailyReminderDeliveryGate(defaults: defaults)
    precondition(daily(&dailyGate, date(hour: 8, minute: 59)) == nil)
    precondition(daily(&dailyGate, date(), canNotify: false) == nil)
    let dailyFirst = daily(&dailyGate, date(second: 5))!
    precondition(daily(&dailyGate, date(second: 5)) == nil)
    precondition(dailyGate.complete(dailyFirst, succeeded: true, now: date(second: 6), calendar: calendar))
    precondition(daily(&dailyGate, date(second: 7)) == nil)
    precondition(defaults.stringArray(forKey: "dailyReminderDeliveredDays") == [dailyFirst.dayKey])
    var restarted = DailyReminderDeliveryGate(defaults: defaults)
    precondition(daily(&restarted, date(second: 10)) == nil)
    precondition(daily(&restarted, date(hour: 10)) == nil)
    // Changing the schedule or disabling and re-enabling cannot produce a
    // second successful notice on an already delivered date.
    precondition(daily(&restarted, date(hour: 10), enabled: false) == nil)
    precondition(daily(&restarted, date(hour: 10), hour: 10) == nil)

    let next = daily(&restarted, date(day: 16))!
    precondition(next.identifier != dailyFirst.identifier)
    precondition(restarted.complete(next, succeeded: true, now: date(day: 16, second: 1), calendar: calendar))
    var rollback = DailyReminderDeliveryGate(defaults: defaults)
    precondition(daily(&rollback, date()) == nil)
    precondition(daily(&rollback, date(day: 16)) == nil)

    // Failed daily submissions do not persist a success. Retry can occur after
    // the scheduled minute, at a controlled rate and with the same identifier.
    var dailyRetry = DailyReminderDeliveryGate(defaults: defaults, key: "retry")
    let dayFailure = daily(&dailyRetry, date(second: 50))!
    precondition(!dailyRetry.complete(dayFailure, succeeded: false, now: date(second: 51), calendar: calendar))
    precondition(defaults.object(forKey: "retry") == nil)
    precondition(daily(&dailyRetry, date(minute: 1, second: 50)) == nil)
    let dayRetry = daily(&dailyRetry, date(minute: 1, second: 51))!
    precondition(dayRetry.identifier == dayFailure.identifier)
    precondition(dayRetry.id != dayFailure.id)
    precondition(!dailyRetry.complete(dayFailure, succeeded: true, now: date(minute: 1, second: 52), calendar: calendar))
    precondition(dailyRetry.complete(dayRetry, succeeded: true, now: date(minute: 1, second: 52), calendar: calendar))

    // Permission becoming available later that date still delivers an activated
    // event; merely starting the app after the minute does not invent one.
    var permission = DailyReminderDeliveryGate(defaults: defaults, key: "permission")
    precondition(daily(&permission, date(), canNotify: false) == nil)
    precondition(daily(&permission, date(hour: 10)) != nil)
    var lateStart = DailyReminderDeliveryGate(defaults: defaults, key: "late-start")
    precondition(daily(&lateStart, date(hour: 10)) == nil)

    var dailyConfiguration = DailyReminderDeliveryGate(defaults: defaults, key: "configuration")
    let beforeDisable = daily(&dailyConfiguration, date())!
    precondition(daily(&dailyConfiguration, date(second: 1), enabled: false, canNotify: false) == nil)
    precondition(!dailyConfiguration.complete(beforeDisable, succeeded: true, now: date(second: 2), calendar: calendar))
    let beforeChange = daily(&dailyConfiguration, date(second: 3))!
    precondition(daily(&dailyConfiguration, date(second: 4), minute: 1, canNotify: false) == nil)
    precondition(!dailyConfiguration.complete(beforeChange, succeeded: true, now: date(second: 5), calendar: calendar))
    let afterChange = daily(&dailyConfiguration, date(minute: 1), minute: 1)!
    precondition(dailyConfiguration.complete(afterChange, succeeded: true, now: date(minute: 1, second: 1), calendar: calendar))

    var midnight = DailyReminderDeliveryGate(defaults: defaults, key: "midnight")
    let previousDate = daily(&midnight, date(hour: 23, minute: 59), hour: 23, minute: 59)!
    precondition(!midnight.complete(previousDate, succeeded: true, now: date(day: 16, hour: 0), calendar: calendar))
    precondition(defaults.object(forKey: "midnight") == nil)
    precondition(daily(&midnight, date(day: 16, hour: 0), hour: 23, minute: 59) == nil)

    var dailyClock = DailyReminderDeliveryGate(defaults: defaults, key: "clock")
    let clockFailure = daily(&dailyClock, date(second: 50))!
    precondition(!dailyClock.complete(clockFailure, succeeded: false, now: date(second: 51), calendar: calendar))
    precondition(daily(&dailyClock, date(second: 10)) == nil)
    precondition(daily(&dailyClock, date(minute: 1, second: 9)) == nil)
    precondition(daily(&dailyClock, date(minute: 1, second: 10)) != nil)
    // A request pending when the clock returns before the configured time is
    // invalidated, and cannot mark the upcoming scheduled event delivered.
    var beforeDue = DailyReminderDeliveryGate(defaults: defaults, key: "before-due")
    let futureToken = daily(&beforeDue, date())!
    precondition(daily(&beforeDue, date(hour: 8, minute: 59)) == nil)
    precondition(!beforeDue.complete(futureToken, succeeded: true, now: date(), calendar: calendar))
    precondition(daily(&beforeDue, date()) != nil)

    // The 2025 Chinese regular and leap sixth months have identical legacy
    // era/year/month/day fields. They must still represent two civil dates.
    var chinese = Calendar(identifier: .chinese)
    chinese.timeZone = calendar.timeZone
    let regularMonth = calendar.date(from: DateComponents(year: 2025, month: 6, day: 25, hour: 9))!
    let leapMonth = calendar.date(from: DateComponents(year: 2025, month: 7, day: 25, hour: 9))!
    let regularParts = chinese.dateComponents([.era, .year, .month, .day], from: regularMonth)
    let leapParts = chinese.dateComponents([.era, .year, .month, .day], from: leapMonth)
    precondition(regularParts.era == leapParts.era && regularParts.year == leapParts.year)
    precondition(regularParts.month == leapParts.month && regularParts.day == leapParts.day)
    precondition(regularParts.isLeapMonth == false && leapParts.isLeapMonth == true)
    var leapGate = DailyReminderDeliveryGate(defaults: defaults, key: "leap-month")
    let regularCandidate = leapGate.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                             now: regularMonth, calendar: chinese)!
    precondition(regularCandidate.dayKey == "gregorian-1-2025-6-25")
    precondition(leapGate.complete(regularCandidate, succeeded: true, now: regularMonth, calendar: chinese))
    var leapRestart = DailyReminderDeliveryGate(defaults: defaults, key: "leap-month")
    let leapCandidate = leapRestart.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                              now: leapMonth, calendar: chinese)!
    precondition(leapCandidate.dayKey == "gregorian-1-2025-7-25")
    precondition(leapCandidate.identifier != regularCandidate.identifier)
    precondition(leapRestart.complete(leapCandidate, succeeded: true, now: leapMonth, calendar: chinese))
    precondition(leapRestart.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                       now: leapMonth, calendar: chinese) == nil)

    // Display-calendar changes cannot invalidate an in-flight notification or
    // generate a second successful notice for the same local civil date.
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = calendar.timeZone
    var displaySwitch = DailyReminderDeliveryGate(defaults: defaults, key: "display-switch")
    let beforeDisplaySwitch = daily(&displaySwitch, date())!
    precondition(displaySwitch.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                         now: date(), calendar: buddhist) == nil)
    precondition(displaySwitch.isPending(beforeDisplaySwitch))
    precondition(displaySwitch.complete(beforeDisplaySwitch, succeeded: true, now: date(), calendar: buddhist))
    var displayRestart = DailyReminderDeliveryGate(defaults: defaults, key: "display-switch")
    for displayCalendar in [calendar, buddhist, chinese] {
        precondition(displayRestart.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                              now: date(), calendar: displayCalendar) == nil)
    }

    // Gregorian history written by 1.3.4 retains exactly the same date keys,
    // even when the display calendar has changed since that delivery.
    defaults.set(["gregorian-1-2026-10-15"], forKey: "legacy-gregorian")
    var legacyGregorian = DailyReminderDeliveryGate(defaults: defaults, key: "legacy-gregorian")
    precondition(legacyGregorian.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                           now: date(), calendar: buddhist) == nil)
    precondition(legacyGregorian.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                           now: date(day: 16), calendar: buddhist) != nil)

    // Legacy non-Gregorian keys lack enough information for a lossless
    // migration. Preserve them without guessing a match that could suppress a
    // valid leap-month delivery; future successes use the unambiguous key.
    let ambiguousLegacy = "chinese-\(regularParts.era!)-\(regularParts.year!)-\(regularParts.month!)-\(regularParts.day!)"
    defaults.set([ambiguousLegacy], forKey: "legacy-ambiguous")
    var legacyAmbiguous = DailyReminderDeliveryGate(defaults: defaults, key: "legacy-ambiguous")
    let afterAmbiguous = legacyAmbiguous.consider(enabled: true, hour: 9, minute: 0, canNotify: true,
                                                  now: leapMonth, calendar: chinese)!
    precondition(afterAmbiguous.dayKey == "gregorian-1-2025-7-25")
    precondition(legacyAmbiguous.complete(afterAmbiguous, succeeded: true, now: leapMonth, calendar: chinese))
    precondition(defaults.stringArray(forKey: "legacy-ambiguous") == [ambiguousLegacy, afterAmbiguous.dayKey])

    // Use the injected local time zone, not UTC or the preferred calendar.
    // At this instant Beijing is already on the 15th while UTC is on the 14th.
    let nearMidnight = date(hour: 0, minute: 30)
    var utcBuddhist = buddhist
    utcBuddhist.timeZone = TimeZone(secondsFromGMT: 0)!
    var zoneGate = DailyReminderDeliveryGate(defaults: defaults, key: "time-zone")
    let beijingCandidate = zoneGate.consider(enabled: true, hour: 0, minute: 30, canNotify: true,
                                              now: nearMidnight, calendar: buddhist)!
    precondition(beijingCandidate.dayKey == "gregorian-1-2026-10-15")
    precondition(zoneGate.complete(beijingCandidate, succeeded: true, now: nearMidnight, calendar: buddhist))
    let utcCandidate = zoneGate.consider(enabled: true, hour: 16, minute: 30, canNotify: true,
                                          now: nearMidnight, calendar: utcBuddhist)!
    precondition(utcCandidate.dayKey == "gregorian-1-2026-10-14")
    precondition(zoneGate.complete(utcCandidate, succeeded: true, now: nearMidnight, calendar: utcBuddhist))
    var zoneRestart = DailyReminderDeliveryGate(defaults: defaults, key: "time-zone")
    precondition(zoneRestart.consider(enabled: true, hour: 0, minute: 30, canNotify: true,
                                       now: nearMidnight, calendar: chinese) == nil)

    // Persist a bounded history rather than growing preferences indefinitely.
    // A repeat of the current or recent prior date remains suppressed.
    var bounded = DailyReminderDeliveryGate(defaults: defaults, key: "bounded")
    var finalDay = date()
    for offset in 0..<400 {
        finalDay = calendar.date(byAdding: .day, value: offset, to: date())!
        let candidate = daily(&bounded, finalDay)!
        precondition(bounded.complete(candidate, succeeded: true, now: finalDay, calendar: calendar))
    }
    precondition(defaults.stringArray(forKey: "bounded")?.count == 366)
    var boundedRestart = DailyReminderDeliveryGate(defaults: defaults, key: "bounded")
    precondition(daily(&boundedRestart, finalDay) == nil)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: finalDay)!
    precondition(daily(&boundedRestart, yesterday) == nil)

    print("Reminder delivery checks passed: enable/permission recovery, success-only consumption, retries, stale callbacks, daily persistence, leap months, display calendars, local time zones and clock correction.")
}
