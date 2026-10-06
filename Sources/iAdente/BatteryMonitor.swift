import AppKit
import Combine
import Foundation
import IOKit
import IOKit.ps

/// A read-only sample. Optional values mean the computer did not provide that metric.
struct BatterySnapshot: Sendable {
    var hasBattery: Bool = false
    var percentage: Int? = nil
    var isPluggedIn: Bool = false
    var isCharging: Bool = false
    var temperature: Double? = nil
    /// Capacity-based estimate, rounded and clamped to 0...100.
    var health: Int? = nil
    var cycles: Int? = nil
    var adapterVoltage: Double? = nil
    var adapterAmperage: Double? = nil
    var adapterPower: Double? = nil
    var systemPower: Double? = nil
    var batteryPower: Double? = nil
    var timeRemainingMinutes: Int? = nil
    /// Available capacity fields are expressed in mAh, never percentage units.
    var currentCapacity: Int? = nil
    var designCapacity: Int? = nil
    var maxCapacity: Int? = nil
    var batteryVoltage: Double? = nil
    var batteryAmperage: Double? = nil
    var updatedAt: Date = Date()

    var statusText: String {
        guard hasBattery else { return "未检测到内置电池" }
        if isCharging { return "正在充电" }
        if isPluggedIn {
            return (percentage ?? 0) >= 100 ? "电池已充满" : "已接通电源（未充电）"
        }
        return "使用电池供电"
    }

    /// Used only when the app explicitly launches in its screenshot preview mode.
    static let preview = BatterySnapshot(
        hasBattery: true, percentage: 100, isPluggedIn: true, isCharging: false,
        temperature: nil, health: 100, cycles: 49,
        adapterVoltage: 27.62, adapterAmperage: 1.62,
        adapterPower: 44.78, systemPower: 44.78, batteryPower: 0,
        currentCapacity: 8422, designCapacity: 8579, maxCapacity: 8552,
        batteryVoltage: 13.02, batteryAmperage: 0
    )
}

struct PowerSample: Identifiable, Sendable {
    var timestamp: Date
    var watts: Double
    var id: UUID = UUID()
}

struct AppUsage: Identifiable {
    let id: Int32
    let name: String
    /// The operating system's process CPU percentage, not an energy share.
    let cpuPercent: Double
    let icon: NSImage?
}

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var snapshot = BatterySnapshot()
    @Published var history: [PowerSample] = []
    @Published var apps: [AppUsage] = []

    private var timer: Timer?
    private var isRefreshing = false
    private let isPreview: Bool
    private var refreshInterval: TimeInterval = 4

    init(preview: Bool = false) {
        isPreview = preview
        if preview {
            snapshot = .preview
            let values: [Double] = [27, 28, 31, 29, 33, 37, 35, 34, 40, 38, 42, 45, 41, 39, 43, 44.78]
            let now = Date()
            history = values.enumerated().map { index, value in
                PowerSample(timestamp: now.addingTimeInterval(Double(index - values.count + 1) * 4), watts: value)
            }
            apps = [
                AppUsage(id: -1, name: "ChatGPT", cpuPercent: 32.2, icon: NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)),
                AppUsage(id: -2, name: "Tiger办公", cpuPercent: 25.0, icon: NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)),
                AppUsage(id: -3, name: "Muse", cpuPercent: 1.4, icon: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil))
            ]
        } else {
            refresh()
            installTimer()
        }
    }

    deinit { timer?.invalidate() }

    func setRefreshInterval(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        refreshInterval = min(60, max(2, seconds))
        if !isPreview { installTimer() }
    }

    func refresh() {
        guard !isPreview, !isRefreshing else { return }
        isRefreshing = true

        // AppKit objects remain on the main actor; only numeric process samples
        // and battery values return from the background worker.
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (Self.readBattery(), Self.readProcesses())
            }.value
            guard let self else { return }
            self.snapshot = result.0
            if let watts = result.0.systemPower ?? result.0.batteryPower.map({ abs($0) }), watts.isFinite {
                self.history.append(PowerSample(timestamp: result.0.updatedAt, watts: watts))
                if self.history.count > 90 { self.history.removeFirst(self.history.count - 90) }
            }

            let running = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            self.apps = result.1.compactMap { sample -> AppUsage? in
                guard let application = running[sample.pid],
                      application.activationPolicy == .regular,
                      let name = application.localizedName else { return nil }
                return AppUsage(id: sample.pid, name: name, cpuPercent: sample.cpuPercent, icon: application.icon)
            }.sorted {
                $0.cpuPercent == $1.cpuPercent ? $0.name.localizedCompare($1.name) == .orderedAscending : $0.cpuPercent > $1.cpuPercent
            }.prefix(3).map { $0 }
            self.isRefreshing = false
        }
    }

    private func installTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private struct ProcessSample: Sendable {
        let pid: Int32
        let cpuPercent: Double
    }

    nonisolated private static func readProcesses() -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2, let pid = Int32(fields[0]), let cpu = Double(fields[1]), cpu.isFinite else { return nil }
                return ProcessSample(pid: pid, cpuPercent: max(0, cpu))
            }
        } catch {
            return []
        }
    }

    nonisolated private static func readBattery() -> BatterySnapshot {
        var sample = BatterySnapshot(updatedAt: Date())

        // Prefer the public power-source API for basic battery state.
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                sample.hasBattery = true
                if let current = number(description, kIOPSCurrentCapacityKey), let maximum = number(description, kIOPSMaxCapacityKey), maximum > 0 {
                    sample.percentage = min(100, max(0, Int((current / maximum * 100).rounded())))
                }
                sample.isPluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                sample.isCharging = boolean(description, kIOPSIsChargingKey) ?? false
                let remaining = number(description, sample.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey)
                sample.timeRemainingMinutes = validMinutes(remaining)
                sample.temperature = BatteryTemperature.celsius(number(description, kIOPSTemperatureKey))
                break
            }
        }

        // Recent systems expose the pack's live sensor on a separate service.
        // Query it independently of AppleSmartBattery's legacy properties.
        if sample.temperature == nil { sample.temperature = readBatteryPackTemperature() }

        // Registry extras are optional. No serial, identity, or firmware values
        // are stored, logged, or exposed. This app never writes registry values.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return sample }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let registry = properties?.takeRetainedValue() as? [String: Any] else { return sample }

        sample.hasBattery = boolean(registry, "BatteryInstalled") ?? true
        sample.isPluggedIn = boolean(registry, "ExternalConnected") ?? sample.isPluggedIn
        sample.isCharging = boolean(registry, "IsCharging") ?? sample.isCharging
        sample.cycles = number(registry, "CycleCount").map { Int($0) }
        if sample.percentage == nil,
           let current = number(registry, "CurrentCapacity"), let maximum = number(registry, "MaxCapacity"), maximum > 0 {
            sample.percentage = min(100, max(0, Int((current / maximum * 100).rounded())))
        }

        sample.batteryVoltage = positive(number(registry, "Voltage")).map { $0 / 1_000 }
        sample.batteryAmperage = signedNumber(registry, "InstantAmperage") ?? signedNumber(registry, "Amperage")
        sample.batteryAmperage = sample.batteryAmperage.map { $0 / 1_000 }
        if sample.temperature == nil {
            sample.temperature = BatteryTemperature.fromCentiCelsius(number(registry, "Temperature"))
        }

        let batteryData = registry["BatteryData"] as? [String: Any] ?? [:]
        sample.designCapacity = positive(number(registry, "DesignCapacity") ?? number(batteryData, "DesignCapacity")).map { Int($0) }
        sample.maxCapacity = positive(number(registry, "AppleRawMaxCapacity") ?? number(batteryData, "FullChargeCapacity") ?? number(batteryData, "NominalChargeCapacity")).map { Int($0) }
        sample.currentCapacity = nonnegative(number(registry, "AppleRawCurrentCapacity") ?? number(batteryData, "RemainingCapacity")).map { Int($0) }
        if let maximum = sample.maxCapacity, let design = sample.designCapacity, design > 0 {
            sample.health = min(100, max(0, Int((Double(maximum) / Double(design) * 100).rounded())))
        }

        let telemetry = registry["PowerTelemetryData"] as? [String: Any] ?? [:]
        if sample.isPluggedIn {
            // AdapterDetails describes negotiated capability. SystemVoltageIn
            // and SystemCurrentIn describe the observed supply instead.
            sample.adapterVoltage = positive(number(telemetry, "SystemVoltageIn")).map { $0 / 1_000 }
            sample.adapterAmperage = nonnegative(number(telemetry, "SystemCurrentIn")).map { $0 / 1_000 }
            sample.adapterPower = nonnegative(number(telemetry, "SystemPowerIn")).map { $0 / 1_000 }
            if sample.adapterPower == nil, let voltage = sample.adapterVoltage, let amperage = sample.adapterAmperage {
                sample.adapterPower = voltage * amperage
            }
        }
        sample.systemPower = nonnegative(number(telemetry, "SystemLoad")).map { $0 / 1_000 }
        sample.batteryPower = signedNumber(telemetry, "BatteryPower").map { $0 / 1_000 }
        if sample.batteryPower == nil, let voltage = sample.batteryVoltage, let amperage = sample.batteryAmperage {
            sample.batteryPower = voltage * amperage
        }
        if sample.systemPower == nil, !sample.isPluggedIn {
            sample.systemPower = sample.batteryPower.map { abs($0) }
        }
        if sample.timeRemainingMinutes == nil {
            sample.timeRemainingMinutes = validMinutes(number(registry, sample.isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty"))
        }
        if sample.isPluggedIn, !sample.isCharging { sample.timeRemainingMinutes = nil }
        return sample
    }

    nonisolated private static func readBatteryPackTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBatteryPack"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return nil }
        // Temperature is the current sensor reading. LifetimeData contains
        // historical min/max/averages and must not fill a missing live value.
        return BatteryTemperature.fromCentiCelsius(number(data, "Temperature"))
    }

    nonisolated private static func number(_ values: [String: Any], _ key: String) -> Double? {
        guard let value = values[key] as? NSNumber else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }

    nonisolated private static func signedNumber(_ values: [String: Any], _ key: String) -> Double? {
        guard let value = values[key] as? NSNumber else { return nil }
        // Some registry counters expose signed amperage as an unsigned 64-bit
        // NSNumber. int64Value recovers its two's-complement sign.
        let result = Double(value.int64Value)
        return abs(result) < 10_000_000 ? result : nil
    }

    nonisolated private static func boolean(_ values: [String: Any], _ key: String) -> Bool? {
        (values[key] as? NSNumber)?.boolValue
    }

    nonisolated private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    nonisolated private static func nonnegative(_ value: Double?) -> Double? {
        guard let value, value >= 0, value < 1_000_000 else { return nil }
        return value
    }

    nonisolated private static func validMinutes(_ value: Double?) -> Int? {
        guard let value, value > 0, value < 65_535 else { return nil }
        return Int(value)
    }
}
