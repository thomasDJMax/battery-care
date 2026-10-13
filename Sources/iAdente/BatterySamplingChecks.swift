import Foundation

/// Deterministic policy and monitor checks. Injected workers avoid timers,
/// subprocesses, IOKit access, notifications and charge-control writes.
enum BatterySamplingChecks {
    static func run() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var policy = BatterySamplingPolicy()
        precondition(!policy.shouldSampleApps(at: now))
        policy.setVisible(true, source: .menuDashboard)
        precondition(policy.shouldSampleApps(at: now))
        policy.recordAppSampleStarted(at: now)
        precondition(!policy.shouldSampleApps(at: now.addingTimeInterval(14.999)))
        precondition(policy.shouldSampleApps(at: now.addingTimeInterval(15)))
        precondition(policy.shouldSampleApps(at: now.addingTimeInterval(-1)))

        let generation = policy.appGeneration
        policy.setVisible(true, source: .settingsDashboard)
        policy.setVisible(false, source: .menuDashboard)
        precondition(policy.shouldRunAppTimer)
        precondition(policy.acceptsAppResult(generation: generation))
        policy.setVisible(false, source: .settingsDashboard)
        precondition(!policy.shouldRunAppTimer)
        precondition(!policy.acceptsAppResult(generation: generation))
        policy.setVisible(true, source: .menuDashboard)
        precondition(!policy.acceptsAppResult(generation: generation))
        precondition(!policy.shouldSampleApps(at: now.addingTimeInterval(5)))

        let appGeneration = policy.appGeneration
        let batteryGeneration = policy.batteryGeneration
        precondition(policy.setSuspended(true))
        precondition(!policy.setSuspended(true))
        precondition(!policy.shouldSampleApps(at: now.addingTimeInterval(30)))
        precondition(!policy.acceptsBatteryResult(generation: batteryGeneration))
        precondition(policy.setSuspended(false))
        precondition(policy.shouldSampleApps(at: now.addingTimeInterval(30)))
        precondition(!policy.acceptsAppResult(generation: appGeneration))
        precondition(policy.acceptsBatteryResult(generation: policy.batteryGeneration))

        let parsed = ProcessSampleParser.parse(" 42 13.5\n43 150.0\n0 5.0\n44 nan\n45 -1\n46 7.0 extra\n")
        precondition(parsed == [ProcessSample(pid: 42, cpuPercent: 13.5), ProcessSample(pid: 43, cpuPercent: 150)])
        precondition(ProcessSampleParser.parse("").isEmpty)

        // Only known mAh fields are handed to the capacity parser; public
        // percent fields never become fallbacks when all mAh fields are absent.
        precondition(BatteryMetricParser.firstPositiveInteger(nil, nil) == nil)
        precondition(BatteryMetricParser.firstPositiveInteger(0, 8_500) == 8_500)
        precondition(BatteryMetricParser.firstPositiveInteger(-1, .infinity, 8_400) == 8_400)
        precondition(BatteryMetricParser.firstNonnegativeInteger(0, 8_000) == 0)
        precondition(BatteryMetricParser.firstNonnegativeInteger(-1, 7_900) == 7_900)
        precondition(BatteryMetricParser.firstPositiveInteger(Double(Int.max)) == nil)
        precondition(BatteryMetricParser.firstNonnegativeInteger(Double(Int.max)) == nil)
        precondition(BatteryMetricParser.percentage(current: 80, maximum: 100) == 80)
        precondition(BatteryMetricParser.percentage(current: 0, maximum: 100) == 0)
        precondition(BatteryMetricParser.percentage(current: .greatestFiniteMagnitude, maximum: .leastNonzeroMagnitude) == 100)
        precondition(BatteryMetricParser.percentage(current: .nan, maximum: 100) == nil)
        precondition(BatteryMetricParser.percentage(current: 50, maximum: .infinity) == nil)
        precondition(BatteryMetricParser.percentage(current: -1, maximum: 100) == nil)
        precondition(BatteryMetricParser.health(maximum: 8_000, design: 10_000) == 80)
        precondition(BatteryMetricParser.health(maximum: Int.max, design: 1) == 100)

        var sample = BatterySnapshot(hasBattery: true, isPluggedIn: true, batteryPower: 20)
        precondition(BatterySamplingPolicy.historyReading(sample) == nil)
        sample.systemPower = 35
        sample.systemPowerSource = .systemLoad
        precondition(BatterySamplingPolicy.historyReading(sample)?.watts == 35)
        sample.systemPowerSource = .batteryDischargeEstimate
        precondition(BatterySamplingPolicy.historyReading(sample) == nil)
        sample.isPluggedIn = false
        precondition(BatterySamplingPolicy.historyReading(sample)?.source == .batteryDischargeEstimate)
        sample.isCharging = true
        precondition(BatterySamplingPolicy.historyReading(sample) == nil)
        sample.systemPower = .nan
        sample.systemPowerSource = .systemLoad
        precondition(BatterySamplingPolicy.historyReading(sample) == nil)
    }

    @MainActor
    static func runMonitorLifecycleChecks() async {
        let clock = SamplingCheckClock(Date(timeIntervalSinceReferenceDate: 1_000))
        let probe = SamplingCheckProbe(clock: clock)
        let dependencies = BatterySamplingDependencies(
            battery: { await probe.readBattery() },
            appActivity: { await probe.readApps() },
            now: { clock.now }
        )
        let monitor = BatteryMonitor(samplingDependencies: dependencies)
        await waitUntil("initial battery sample") { !monitor.isRefreshing }
        var appCount = await probe.appCount()
        precondition(appCount == 0, "A background monitor must not run ps")
        precondition(monitor.appsUpdatedAt == nil)

        monitor.setAppSamplingVisible(true, source: .menuDashboard)
        await waitUntil("first visible app sample") { await probe.appCount() == 1 }
        await probe.finishApp()
        await waitUntil("published visible app sample") { monitor.appsUpdatedAt == clock.now }
        precondition(monitor.appActivityMessage != nil, "An empty sample needs an explanation")
        let firstUpdate = monitor.appsUpdatedAt

        monitor.setAppSamplingVisible(false, source: .menuDashboard)
        clock.advance(by: 20)
        monitor.refresh()
        await waitUntil("hidden battery sample") { !monitor.isRefreshing }
        appCount = await probe.appCount()
        precondition(appCount == 1, "Battery refresh must not start app sampling")
        precondition(monitor.appsUpdatedAt == firstUpdate)

        monitor.setAppSamplingVisible(true, source: .menuDashboard)
        await waitUntil("second app worker") { await probe.appCount() == 2 }
        monitor.setAppSamplingVisible(false, source: .menuDashboard)
        await probe.finishApp()
        await drainWorkerContinuations()
        precondition(monitor.appsUpdatedAt == firstUpdate, "Hidden app results must not publish")
        appCount = await probe.appCount()
        precondition(appCount == 2)

        clock.advance(by: 20)
        monitor.setAppSamplingVisible(true, source: .settingsDashboard)
        await waitUntil("app worker before sleep") { await probe.appCount() == 3 }
        await probe.holdNextBattery()
        monitor.refresh()
        await waitUntil("battery worker before sleep") { await probe.isBatteryHeld() }
        let percentageBeforeSleep = monitor.snapshot.percentage
        monitor.setSuspended(true)
        precondition(!monitor.isRefreshing)
        // These workers deliberately ignore cancellation until we release
        // them, reproducing a read that finishes after its UI disappears.
        await probe.finishApp()
        await probe.finishBattery(percentage: 11)
        await drainWorkerContinuations()
        precondition(monitor.snapshot.percentage == percentageBeforeSleep, "A pre-sleep battery result must not publish")
        precondition(monitor.appsUpdatedAt == firstUpdate, "A pre-sleep app result must not publish")
        monitor.refresh()
        monitor.setAppSamplingVisible(true, source: .settingsDashboard)
        appCount = await probe.appCount()
        precondition(appCount == 3, "Sleeping must not start an app worker")

        clock.advance(by: 20)
        monitor.setSuspended(false)
        await waitUntil("app sampling after wake") { await probe.appCount() == 4 }
        await probe.finishApp()
        await waitUntil("fresh results after wake") { !monitor.isRefreshing && monitor.appsUpdatedAt == clock.now }
        precondition(monitor.snapshot.percentage == 81)
        monitor.setAppSamplingVisible(false, source: .settingsDashboard)
    }

    @MainActor
    private static func waitUntil(_ description: String, condition: @MainActor () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Timed out waiting for \(description)")
    }

    private static func drainWorkerContinuations() async {
        // Let released workers return through the monitor's MainActor tasks.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private final class SamplingCheckClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }
    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
    func advance(by seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private actor SamplingCheckProbe {
    private let clock: SamplingCheckClock
    private var appsStarted = 0
    private var appContinuation: CheckedContinuation<ProcessSamplingResult, Never>?
    private var shouldHoldBattery = false
    private var batteryContinuation: CheckedContinuation<BatterySnapshot, Never>?

    init(clock: SamplingCheckClock) { self.clock = clock }

    func readBattery() async -> BatterySnapshot {
        if shouldHoldBattery {
            shouldHoldBattery = false
            return await withCheckedContinuation { batteryContinuation = $0 }
        }
        return batterySample(percentage: 81)
    }

    func readApps() async -> ProcessSamplingResult {
        appsStarted += 1
        return await withCheckedContinuation { appContinuation = $0 }
    }

    func appCount() -> Int { appsStarted }
    func isBatteryHeld() -> Bool { batteryContinuation != nil }
    func holdNextBattery() { shouldHoldBattery = true }

    func finishApp() {
        precondition(appContinuation != nil)
        let continuation = appContinuation
        appContinuation = nil
        continuation?.resume(returning: .success([]))
    }

    func finishBattery(percentage: Int) {
        precondition(batteryContinuation != nil)
        let continuation = batteryContinuation
        batteryContinuation = nil
        continuation?.resume(returning: batterySample(percentage: percentage))
    }

    private func batterySample(percentage: Int) -> BatterySnapshot {
        BatterySnapshot(hasBattery: true, percentage: percentage, systemPower: 12,
                        systemPowerSource: .systemLoad, updatedAt: clock.now)
    }
}
