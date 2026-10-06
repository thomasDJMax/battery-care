import AppKit
import SwiftUI

extension Notification.Name {
    static let iadenteDashboardClosed = Notification.Name("iadenteDashboardClosed")
}

/// A status-menu panel must be eligible to accompany another application's
/// fullscreen window before it is ordered on screen. A nonactivating panel
/// keeps that application's current Space and supports our native controls.
@MainActor
final class DashboardPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        title = "\(AppIdentity.displayName) · 实时电池养护"
        setAccessibilityLabel(title)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct DashboardPlacement {
    let frame: NSRect
    let arrowX: CGFloat

    init(anchor: NSRect, screen: NSRect) {
        let width: CGFloat = 410
        let margin: CGFloat = 8
        let top = min(anchor.minY - 3, screen.maxY - margin)
        let height = min(720, max(1, top - screen.minY - margin))
        let x = min(max(anchor.midX - width / 2, screen.minX + margin), screen.maxX - width - margin)
        frame = NSRect(x: x, y: top - height, width: width, height: height)
        arrowX = min(max(anchor.midX - x, 24), width - 24)
    }
}

@MainActor
final class DashboardPanelController {
    private let coordinator: AppCoordinator
    private let panel = DashboardPanel()
    private weak var anchorButton: NSStatusBarButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var hostingView: NSHostingView<DashboardPanelContent>?

    var isShown: Bool { panel.isVisible }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown { close() } else { show(relativeTo: button) }
    }

    private func show(relativeTo button: NSStatusBarButton) {
        guard let anchorWindow = button.window, let screen = anchorWindow.screen else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // The anchor's own screen is important on secondary displays. Recompute
        // the height each time, including when the menu bar auto-hides.
        let usableScreen = NSRect(x: screen.frame.minX, y: screen.visibleFrame.minY,
                                  width: screen.frame.width, height: screen.frame.maxY - screen.visibleFrame.minY)
        let placement = DashboardPlacement(anchor: anchor, screen: usableScreen)
        let content = DashboardPanelContent(coordinator: coordinator, height: placement.frame.height, arrowX: placement.arrowX)
        if let hostingView { hostingView.rootView = content }
        else {
            let host = NSHostingView(rootView: content)
            hostingView = host
            panel.contentView = host
        }
        panel.setFrame(placement.frame, display: false)
        anchorButton = button
        coordinator.monitor.refresh()
        coordinator.charge.refresh()
        button.highlight(true)
        installEventMonitors()
        // Do not activate NSApp here: that can move a fullscreen browser back
        // to the app's desktop Space. The panel alone receives keyboard focus.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        NotificationCenter.default.post(name: .iadenteDashboardClosed, object: nil)
        if let sheet = panel.attachedSheet {
            panel.endSheet(sheet)
            sheet.orderOut(nil)
        }
        panel.orderOut(nil)
        anchorButton?.highlight(false)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func installEventMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown)) { [weak self] event in
            guard let self, self.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    // A sheet's cancel shortcut should dismiss the sheet first.
                    if self.panel.attachedSheet != nil { return event }
                    self.close()
                    return nil
                }
            } else if !self.ownsInteraction(with: event.window) {
                self.close()
            }
            return event
        }
        // Mouse-only global monitoring works without accessibility permission.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            guard let self, self.isShown else { return }
            let point = NSEvent.mouseLocation
            if !self.panel.frame.contains(point) { self.close() }
        }
    }

    private func ownsInteraction(with window: NSWindow?) -> Bool {
        // Keep the mouse-down on the status button. Its mouse-up toggles the
        // panel; dismissing on mouse-down would immediately reopen it.
        if let window, window === anchorButton?.window { return true }
        var current = window
        while let window = current {
            if window === panel { return true }
            current = window.sheetParent ?? window.parent
        }
        return false
    }
}

private struct DashboardPanelContent: View {
    @ObservedObject var coordinator: AppCoordinator
    let height: CGFloat
    let arrowX: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 8)
            DashboardView(coordinator: coordinator).frame(height: max(1, height - 8))
        }
        .frame(width: 410, height: height)
        .background(alignment: .topLeading) {
            MenuArrow().fill(Color(white: coordinator.settings.material == .solid ? 0.19 : 0.36))
                .frame(width: 18, height: 8).offset(x: arrowX - 9)
        }
        .clipShape(MenuBubble(arrowX: arrowX))
        .overlay { MenuBubble(arrowX: arrowX).stroke(Color.white.opacity(0.16), lineWidth: 1) }
        .preferredColorScheme(.dark)
    }
}

private struct MenuArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct MenuBubble: Shape {
    let arrowX: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + 8, width: rect.width, height: max(0, rect.height - 8)), cornerRadius: 20)
        path.addPath(MenuArrow().path(in: CGRect(x: arrowX - 9, y: rect.minY, width: 18, height: 8)))
        return path
    }
}

@MainActor
func runDashboardPresentationChecks() {
    let panel = DashboardPanel()
    precondition(panel.styleMask.contains(.nonactivatingPanel))
    precondition(panel.collectionBehavior.contains(.canJoinAllApplications))
    precondition(panel.collectionBehavior.contains(.canJoinAllSpaces))
    precondition(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    precondition(!panel.hidesOnDeactivate && panel.canBecomeKey && !panel.canBecomeMain)
    precondition(panel.level == .statusBar)
    for screen in [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1920, y: -120, width: 1920, height: 1080), NSRect(x: 1440, y: 0, width: 1024, height: 600)] {
        for anchorX in [screen.minX + 15, screen.midX, screen.maxX - 100] {
            let anchor = NSRect(x: anchorX, y: screen.maxY - 28, width: 85, height: 25)
            let placement = DashboardPlacement(anchor: anchor, screen: screen)
            precondition(screen.contains(placement.frame))
            precondition(placement.frame.maxY < anchor.minY)
            precondition((24...386).contains(placement.arrowX))
        }
    }
    print("Dashboard checks passed: nonactivating fullscreen panel, screen placement and edge clamping.")
}
