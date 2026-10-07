import AppKit
import Combine
import SwiftUI
import CoreServices
import ServiceManagement
import NativeCharge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var coordinator: AppCoordinator!
    private var statusItem: NSStatusItem!
    private var dashboardPanel: DashboardPanelController!
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator(preview: CommandLine.arguments.contains("--preview"))
        coordinator.openSettingsHandler = { [weak self] in self?.showSettings() }
        coordinator.closePopoverHandler = { [weak self] in self?.dashboardPanel.close() }
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self; button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "\(AppIdentity.displayName) · 电池养护控制台"
            button.setAccessibilityLabel("\(AppIdentity.displayName) 电池养护菜单")
        }
        dashboardPanel = DashboardPanelController(coordinator: coordinator)
        coordinator.monitor.$snapshot.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }.store(in: &subscriptions)
        coordinator.settings.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        updateStatus()
        let loginLaunch = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue ?? false
        if !loginLaunch && !CommandLine.arguments.contains("--background") {
            showSettings()
        }
    }

    @objc private func didWake() { coordinator.monitor.refresh(); coordinator.charge.refresh() }
    func applicationDidBecomeActive(_ notification: Notification) { coordinator?.updateNotificationStatus() }

    @objc private func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            dashboardPanel.close()
            let menu = NSMenu()
            let settings = NSMenuItem(title: "打开电池养护控制台", action: #selector(openSettingsAction), keyEquivalent: ",")
            settings.target = self; menu.addItem(settings)
            let refresh = NSMenuItem(title: "刷新电池读数", action: #selector(refreshAction), keyEquivalent: "r")
            refresh.target = self; menu.addItem(refresh)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出 \(AppIdentity.displayName)", action: #selector(quitAction), keyEquivalent: "q")
            quit.target = self; menu.addItem(quit)
            if let event = NSApp.currentEvent, let button = statusItem.button {
                NSMenu.popUpContextMenu(menu, with: event, for: button)
            }
            return
        }
        if let button = statusItem.button {
            coordinator.refreshChargeState()
            coordinator.updateNotificationStatus()
            dashboardPanel.toggle(relativeTo: button)
        }
    }
    @objc private func openSettingsAction() { coordinator.openSettings() }
    @objc private func openAboutAction() { coordinator.openSettings(.about) }
    @objc private func refreshAction() { coordinator.monitor.refresh(); coordinator.refreshChargeState() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func installApplicationMenu() {
        let root = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: AppIdentity.displayName)
        let about = NSMenuItem(title: "关于 \(AppIdentity.displayName)", action: #selector(openAboutAction), keyEquivalent: "")
        about.target = self
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        let quit = NSMenuItem(title: "退出 \(AppIdentity.displayName)", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        applicationMenu.addItem(about)
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        root.addItem(applicationItem)
        NSApp.mainMenu = root
    }

    private func updateStatus() {
        guard let button = statusItem?.button, coordinator != nil else { return }
        let snapshot = coordinator.monitor.snapshot
        let percent = snapshot.percentage.map { "\($0)%" } ?? "—%"
        let power = snapshot.systemPower.map { String(format: "%.1fW", $0) } ?? "—W"
        let text: String
        switch coordinator.settings.readout {
        case .battery: text = percent
        case .power: text = power
        case .both: text = "\(percent)  ·  \(power)"
        }
        // Status bar ink depends on the desktop behind the bar, not the app's
        // window appearance. Native titles and template icons let macOS choose
        // contrasting ink; forcing labelColor/contentTintColor made dark bars
        // display black text on the current system.
        button.contentTintColor = nil
        button.appearance = nil
        button.attributedTitle = NSAttributedString(string: "")
        button.title = text
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        button.toolTip = "\(AppIdentity.displayName) · \(snapshot.statusText) · \(text)"
        if snapshot.isCharging && coordinator.settings.useColors {
            button.title = ""
            button.image = StatusReadout.chargingImage(text: text)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel("\(AppIdentity.displayName)，正在充电，\(text)")
            return
        }
        let powerConnected = snapshot.isPluggedIn || snapshot.isCharging
        let symbol = powerConnected ? "battery.100percent.bolt" : "battery.100percent"
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "电池")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        if coordinator.settings.useColors {
            let color = StatusReadout.batteryGreen
            if powerConnected { image = StatusReadout.powerConnectedBattery(color: color) }
            else { image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) }
            image?.isTemplate = false
        } else { image?.isTemplate = true }
        button.image = image
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleNone
        button.setAccessibilityLabel("\(AppIdentity.displayName)，\(snapshot.statusText)，\(text)")
    }

    private func showSettings() {
        dashboardPanel?.close()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "\(AppIdentity.displayName) · 电池养护控制台"
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.32, alpha: 1)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 780, height: 600)
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator))
            window.center()
            window.setFrameAutosaveName("iAdenteSettingsWindow")
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        dashboardPanel?.close()
        // System charging limits deliberately persist. Temporary 100% is
        // restored on an orderly quit; a regular saved limit is never changed.
        if coordinator.temporaryFull { _ = coordinator.restoreTemporaryFull() }
    }
}

@main
struct BatteryCareApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Targeted maintenance used when moving this same application's bundle.
        // The bundle identifier stays stable, preserving preferences/permissions.
        if CommandLine.arguments.contains("--login-status") {
            print(SMAppService.mainApp.status.rawValue)
            return
        }
        if CommandLine.arguments.contains("--unregister-login") || CommandLine.arguments.contains("--register-login") {
            do {
                if CommandLine.arguments.contains("--unregister-login") { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
                print("Login item status: \(SMAppService.mainApp.status.rawValue)")
            } catch { print("Login item update failed: \(error)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-power-qa"), index + 1 < CommandLine.arguments.count {
            do { try renderPowerFlowViews(to: CommandLine.arguments[index + 1]) }
            catch { print("Power flow rendering failed: \(error)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-care-qa"), index + 1 < CommandLine.arguments.count {
            do { try renderQuickCareViews(to: CommandLine.arguments[index + 1]) }
            catch { print("Quick care rendering failed: \(error)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-protection-qa"), index + 1 < CommandLine.arguments.count {
            do { try renderProtectionViews(to: CommandLine.arguments[index + 1]) }
            catch { print("Protection rendering failed: \(error)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-qa"), index + 1 < CommandLine.arguments.count {
            do { try renderApplicationViews(to: CommandLine.arguments[index + 1]) }
            catch { print("Rendering failed: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            runReadOnlyChecks()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    @MainActor private static func runReadOnlyChecks() {
        runChargeLimitOptionsChecks()
        runDashboardPresentationChecks()
        runQuickCareChecks()
        runTemperatureReminderChecks()
        precondition(BatteryTemperature.celsius(31.5) == 31.5)
        precondition(abs(BatteryTemperature.fromCentiCelsius(3139)! - 31.39) < 0.0001)
        precondition(BatteryTemperature.fromCentiCelsius(0) == nil)
        precondition(BatteryTemperature.fromCentiCelsius(.nan) == nil)
        precondition(BatteryTemperature.fromCentiCelsius(9900) == nil)
        let monitor = BatteryMonitor()
        let deadline = Date().addingTimeInterval(5)
        while !monitor.snapshot.hasBattery && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let snapshot = monitor.snapshot
        precondition(snapshot.percentage == nil || (0...100).contains(snapshot.percentage!))
        precondition(snapshot.health == nil || (0...100).contains(snapshot.health!))
        precondition(monitor.history.count <= 90)
        precondition(IAChargeSetLimit(0, nil, 0) == 0 && IAChargeSetLimit(101, nil, 0) == 0, "Invalid limits must be rejected before reaching system")
        let native = NativeChargeController()
        precondition(native.availableLimits.allSatisfy { (1...100).contains($0) })
        precondition(native.availableLimits == ChargeLimitOptions(native.availableLimits).values)
        print("System available charge limits: \(native.availableLimits)")
        print("Battery present: \(snapshot.hasBattery); percentage: \(snapshot.percentage.map(String.init) ?? "unavailable"); cycles: \(snapshot.cycles.map(String.init) ?? "unavailable")")
        let temperature = snapshot.temperature.map { String(format: "%.2f°C", $0) } ?? "unavailable"
        print("System power: \(snapshot.systemPower.wattsText); app samples: \(monitor.apps.count); battery temperature: \(temperature)")
        print("Native charge limit supported: \(native.isSupported); limit: \(native.currentLimit.map(String.init) ?? "unavailable"); enabled: \(native.isEnabled)")
        print("Read-only checks passed. No valid charging writes or login-item changes performed.")
    }
}
