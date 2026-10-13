import Foundation
import Darwin

enum AppSamplingSource: Hashable, Sendable {
    case menuDashboard
    case settingsDashboard
}

enum PowerMeasurementSource: Sendable, Equatable {
    case systemLoad
    case batteryDischargeEstimate
}

/// Pure timing and visibility decisions. The monitor owns timers and workers.
struct BatterySamplingPolicy {
    static let appInterval: TimeInterval = 15
    private(set) var visibleSources: Set<AppSamplingSource> = []
    private(set) var isSuspended = false
    private(set) var appGeneration: UInt64 = 0
    private(set) var batteryGeneration: UInt64 = 0
    private(set) var lastAppSampleStartedAt: Date?

    var shouldRunAppTimer: Bool { !isSuspended && !visibleSources.isEmpty }

    mutating func setVisible(_ visible: Bool, source: AppSamplingSource) {
        let wasVisible = !visibleSources.isEmpty
        if visible { visibleSources.insert(source) }
        else { visibleSources.remove(source) }
        if wasVisible && visibleSources.isEmpty { appGeneration &+= 1 }
    }

    @discardableResult
    mutating func setSuspended(_ suspended: Bool) -> Bool {
        guard suspended != isSuspended else { return false }
        isSuspended = suspended
        if suspended {
            appGeneration &+= 1
            batteryGeneration &+= 1
        }
        return true
    }

    func shouldSampleApps(at now: Date) -> Bool {
        guard shouldRunAppTimer else { return false }
        guard let previous = lastAppSampleStartedAt else { return true }
        let elapsed = now.timeIntervalSince(previous)
        // A clock correction must not suppress samples until the old date.
        return elapsed >= Self.appInterval || elapsed < 0
    }

    mutating func recordAppSampleStarted(at now: Date) {
        lastAppSampleStartedAt = now
    }

    func acceptsAppResult(generation: UInt64) -> Bool {
        shouldRunAppTimer && generation == appGeneration
    }

    func acceptsBatteryResult(generation: UInt64) -> Bool {
        !isSuspended && generation == batteryGeneration
    }

    static func historyReading(_ snapshot: BatterySnapshot) -> (watts: Double, source: PowerMeasurementSource)? {
        guard let watts = snapshot.systemPower, watts.isFinite, watts >= 0 else { return nil }
        let source = snapshot.systemPowerSource ?? .systemLoad
        if source == .batteryDischargeEstimate && (snapshot.isPluggedIn || snapshot.isCharging) { return nil }
        return (watts, source)
    }
}

struct ProcessSample: Sendable, Equatable {
    let pid: Int32
    let cpuPercent: Double
}

enum ProcessSamplingResult: Sendable {
    case success([ProcessSample])
    case failure(String)
    case cancelled
}

/// Tests may supply workers and a clock without accessing hardware or spawning
/// ps. Production uses the monitor's normal read-only workers instead.
struct BatterySamplingDependencies: Sendable {
    var battery: @Sendable () async -> BatterySnapshot
    var appActivity: @Sendable () async -> ProcessSamplingResult
    var now: @Sendable () -> Date
    var automaticallySchedulesTimers = false
}

enum ProcessSampleParser {
    static func parse(_ text: String) -> [ProcessSample] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, let pid = Int32(fields[0]), pid > 0,
                  let cpu = Double(fields[1]), cpu.isFinite, cpu >= 0 else { return nil }
            return ProcessSample(pid: pid, cpuPercent: cpu)
        }
    }
}

enum BatteryMetricParser {
    static func percentage(current: Double, maximum: Double) -> Int? {
        guard current.isFinite, maximum.isFinite, current >= 0, maximum > 0 else { return nil }
        // Clamp the ratio before conversion: even finite registry inputs can
        // overflow when divided or multiplied, or exceed Int's range.
        let percentage = min(100, max(0, current / maximum * 100))
        return Int(percentage.rounded())
    }

    static func firstPositiveInteger(_ values: Double?...) -> Int? {
        values.compactMap { value -> Int? in
            guard let value, value.isFinite, value > 0, value < Double(Int.max) else { return nil }
            return Int(value)
        }.first
    }

    static func firstNonnegativeInteger(_ values: Double?...) -> Int? {
        values.compactMap { value -> Int? in
            guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
            return Int(value)
        }.first
    }

    static func health(maximum: Int?, design: Int?) -> Int? {
        guard let maximum, let design, maximum > 0, design > 0 else { return nil }
        let percentage = Double(maximum) / Double(design) * 100
        return Int(min(100, max(0, percentage)).rounded())
    }
}

/// Only this request's own /bin/ps child may be terminated. No process names,
/// arguments, account data or process trees are collected.
final class AppProcessSampleRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false
    private var didTimeOut = false

    func cancel() {
        lock.lock()
        wasCancelled = true
        stopChildLocked()
        lock.unlock()
    }

    func run(timeout: TimeInterval = 3) -> ProcessSamplingResult {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/ps")
        child.arguments = ["-axo", "pid=,pcpu="]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice

        lock.lock()
        guard !wasCancelled else { lock.unlock(); return .cancelled }
        process = child
        do { try child.run() }
        catch {
            process = nil
            lock.unlock()
            return .failure("暂时无法读取应用活动")
        }
        lock.unlock()

        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.process?.isRunning == true {
                self.didTimeOut = true
                self.stopChildLocked()
            }
            self.lock.unlock()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        deadline.cancel()

        lock.lock()
        let cancelled = wasCancelled
        let timedOut = didTimeOut
        process = nil
        lock.unlock()
        if cancelled { return .cancelled }
        if timedOut { return .failure("应用活动读取超时，稍后重试") }
        guard child.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return .failure("暂时无法读取应用活动")
        }
        return .success(ProcessSampleParser.parse(text))
    }

    /// The lock pins the Process object while its child is still active.
    private func stopChildLocked() {
        guard let child = process, child.isRunning else { return }
        child.terminate()
        // Bound cleanup even if our ps child does not respond to SIGTERM.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self, weak child] in
            guard let self, let child else { return }
            self.lock.lock()
            if self.process === child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
            self.lock.unlock()
        }
    }
}
