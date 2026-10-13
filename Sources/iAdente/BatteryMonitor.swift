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
    var systemPowerSource: PowerMeasurementSource? = nil
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
        adapterPower: 44.78, systemPower: 44.78, systemPowerSource: .systemLoad, batteryPower: 0,
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
    @Published private(set) var isRefreshing = false
    @Published private(set) var appsUpdatedAt: Date?
    @Published private(set) var appActivityMessage: String? = "打开仪表盘后读取应用活动"

    private var timer: Timer?
    private var appTimer: Timer?
    private var batteryTask: Task<Void, Never>?
    private var appTask: Task<Void, Never>?
    private var appRequest: AppProcessSampleRequest?
    private var sampling = BatterySamplingPolicy()
    private var historySource: PowerMeasurementSource?
    private let isPreview: Bool
    private let samplingDependencies: BatterySamplingDependencies?
    private var refreshInterval: TimeInterval = 4

    init(preview: Bool = false, samplingDependencies: BatterySamplingDependencies? = nil) {
        isPreview = preview
        self.samplingDependencies = samplingDependencies
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
            appsUpdatedAt = now
            appActivityMessage = nil
            historySource = .systemLoad
        } else {
            refresh()
            installTimer()
        }
    }

    deinit {
        timer?.invalidate()
        appTimer?.invalidate()
        batteryTask?.cancel()
        appRequest?.cancel()
        appTask?.cancel()
    }

    func setRefreshInterval(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let interval = min(60, max(2, seconds))
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        if !isPreview && !sampling.isSuspended { installTimer() }
    }

    func refresh() {
        guard !isPreview, !sampling.isSuspended, !isRefreshing else { return }
        isRefreshing = true
        let generation = sampling.batteryGeneration
        let dependencies = samplingDependencies

        // Process sampling has its own task and cadence; it cannot delay a
        // battery read, a wake refresh, or the charging status in the menu bar.
        batteryTask = Task { [weak self] in
            let result: BatterySnapshot
            if let dependencies { result = await dependencies.battery() }
            else { result = await Task.detached(priority: .utility) { Self.readBattery() }.value }
            guard !Task.isCancelled, let self,
                  self.sampling.acceptsBatteryResult(generation: generation) else { return }
            self.snapshot = result
            if let reading = BatterySamplingPolicy.historyReading(result) {
                // A discharge estimate and measured SystemLoad are different
                // metrics. Do not draw a continuous history across that switch.
                if self.historySource != reading.source { self.history.removeAll(keepingCapacity: true) }
                self.historySource = reading.source
                self.history.append(PowerSample(timestamp: result.updatedAt, watts: reading.watts))
                if self.history.count > 90 { self.history.removeFirst(self.history.count - 90) }
            }
            self.isRefreshing = false
            self.batteryTask = nil
        }
    }

    func setAppSamplingVisible(_ visible: Bool, source: AppSamplingSource) {
        sampling.setVisible(visible, source: source)
        updateAppSampling()
    }

    func setSuspended(_ suspended: Bool) {
        guard sampling.setSuspended(suspended) else { return }
        if suspended {
            timer?.invalidate()
            timer = nil
            batteryTask?.cancel()
            batteryTask = nil
            isRefreshing = false
        } else if !isPreview {
            installTimer()
            refresh()
        }
        updateAppSampling()
    }

    private func updateAppSampling() {
        guard !isPreview else { return }
        if sampling.shouldRunAppTimer {
            if appTimer == nil && automaticallySchedulesTimers {
                appTimer = Timer.scheduledTimer(withTimeInterval: BatterySamplingPolicy.appInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshAppsIfDue() }
                }
                appTimer?.tolerance = 2
                if let appTimer { RunLoop.main.add(appTimer, forMode: .common) }
            }
            refreshAppsIfDue()
        } else {
            appTimer?.invalidate()
            appTimer = nil
            appRequest?.cancel()
            appRequest = nil
            appTask?.cancel()
            appTask = nil
            if apps.isEmpty { appActivityMessage = "打开仪表盘后读取应用活动" }
        }
    }

    private func refreshAppsIfDue() {
        let now = currentDate
        guard appTask == nil, sampling.shouldSampleApps(at: now) else { return }
        sampling.recordAppSampleStarted(at: now)
        let generation = sampling.appGeneration
        let dependencies = samplingDependencies
        let request = dependencies == nil ? AppProcessSampleRequest() : nil
        appRequest = request
        if apps.isEmpty { appActivityMessage = "正在读取应用活动…" }
        appTask = Task { [weak self] in
            let result: ProcessSamplingResult
            if let dependencies { result = await dependencies.appActivity() }
            else if let request { result = await Task.detached(priority: .utility) { request.run() }.value }
            else { return }
            guard !Task.isCancelled, let self,
                  self.sampling.acceptsAppResult(generation: generation) else { return }
            self.appRequest = nil
            self.appTask = nil
            switch result {
            case .success(let samples):
                self.publishApps(samples)
                self.appsUpdatedAt = self.currentDate
                self.appActivityMessage = self.apps.isEmpty ? "暂未找到可显示的应用" : nil
            case .failure(let message):
                self.apps = []
                self.appActivityMessage = message
            case .cancelled:
                self.appActivityMessage = self.apps.isEmpty ? "应用活动采样已暂停" : nil
            }
        }
    }

    private func publishApps(_ samples: [ProcessSample]) {
        guard !samples.isEmpty else { apps = []; return }
        let running = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        // Fetch icons only for the three rows that will actually be displayed.
        let ranked = samples.compactMap { sample -> (ProcessSample, NSRunningApplication, String)? in
            guard let application = running[sample.pid], application.activationPolicy == .regular,
                  let name = application.localizedName else { return nil }
            return (sample, application, name)
        }.sorted {
            $0.0.cpuPercent == $1.0.cpuPercent ? $0.2.localizedCompare($1.2) == .orderedAscending : $0.0.cpuPercent > $1.0.cpuPercent
        }.prefix(3)
        apps = ranked.map { AppUsage(id: $0.0.pid, name: $0.2, cpuPercent: $0.0.cpuPercent, icon: $0.1.icon) }
    }

    private func installTimer() {
        guard automaticallySchedulesTimers else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer?.tolerance = min(5, refreshInterval * 0.2)
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private var automaticallySchedulesTimers: Bool { samplingDependencies?.automaticallySchedulesTimers ?? true }
    private var currentDate: Date { samplingDependencies?.now() ?? Date() }

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
                    sample.percentage = BatteryMetricParser.percentage(current: current, maximum: maximum)
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
        sample.cycles = BatteryMetricParser.firstNonnegativeInteger(number(registry, "CycleCount"))
        if sample.percentage == nil,
           let current = number(registry, "CurrentCapacity"), let maximum = number(registry, "MaxCapacity"), maximum > 0 {
            sample.percentage = BatteryMetricParser.percentage(current: current, maximum: maximum)
        }

        sample.batteryVoltage = positive(number(registry, "Voltage")).map { $0 / 1_000 }
        sample.batteryAmperage = signedNumber(registry, "InstantAmperage") ?? signedNumber(registry, "Amperage")
        sample.batteryAmperage = sample.batteryAmperage.map { $0 / 1_000 }
        if sample.temperature == nil {
            sample.temperature = BatteryTemperature.fromCentiCelsius(number(registry, "Temperature"))
        }

        let batteryData = registry["BatteryData"] as? [String: Any] ?? [:]
        // Validate each mAh candidate before falling back. A zero placeholder
        // in the first key must not hide a valid nested capacity. The public
        // normalized CurrentCapacity/MaxCapacity fields are not mAh fallbacks.
        sample.designCapacity = BatteryMetricParser.firstPositiveInteger(number(registry, "DesignCapacity"), number(batteryData, "DesignCapacity"))
        sample.maxCapacity = BatteryMetricParser.firstPositiveInteger(number(registry, "AppleRawMaxCapacity"), number(batteryData, "FullChargeCapacity"), number(batteryData, "NominalChargeCapacity"))
        sample.currentCapacity = BatteryMetricParser.firstNonnegativeInteger(number(registry, "AppleRawCurrentCapacity"), number(batteryData, "RemainingCapacity"))
        sample.health = BatteryMetricParser.health(maximum: sample.maxCapacity, design: sample.designCapacity)

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
        if sample.systemPower != nil { sample.systemPowerSource = .systemLoad }
        sample.batteryPower = signedNumber(telemetry, "BatteryPower").map { $0 / 1_000 }
        if sample.batteryPower == nil, let voltage = sample.batteryVoltage, let amperage = sample.batteryAmperage {
            sample.batteryPower = voltage * amperage
        }
        if sample.systemPower == nil, !sample.isPluggedIn, !sample.isCharging {
            sample.systemPower = sample.batteryPower.map { abs($0) }
            if sample.systemPower != nil { sample.systemPowerSource = .batteryDischargeEstimate }
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
