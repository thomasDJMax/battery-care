import ServiceManagement

@MainActor
func runLoginStatusChecks() {
    // The provider exercises the coordinator's observable refresh path without
    // registering, unregistering, or changing the real macOS login item.
    let coordinator = AppCoordinator(preview: true, renderingOnly: true)
    var status: SMAppService.Status = .enabled
    var reads = 0
    let provider = {
        reads += 1
        return status
    }

    coordinator.refreshLoginStatus(statusProvider: provider)
    precondition(coordinator.loginEnabled, "Approved login items must appear enabled")

    status = .notRegistered
    coordinator.refreshLoginStatus(statusProvider: provider)
    precondition(!coordinator.loginEnabled, "An externally removed login item must clear the switch")

    status = .enabled
    coordinator.refreshLoginStatus(statusProvider: provider)
    precondition(coordinator.loginEnabled, "An externally re-enabled login item must refresh the switch")

    status = .requiresApproval
    coordinator.refreshLoginStatus(statusProvider: provider)
    precondition(!coordinator.loginEnabled, "Pending approval must not appear enabled")

    status = .notFound
    coordinator.refreshLoginStatus(statusProvider: provider)
    precondition(!coordinator.loginEnabled, "A missing login item must not appear enabled")
    precondition(reads == 5, "Every refresh must obtain the current status")

    coordinator.loginEnabled = true
    coordinator.refreshLoginStatus()
    precondition(coordinator.loginEnabled, "Preview/rendering refreshes must not read real login status")

    print("Login status checks passed: external disable/re-enable, pending approval, missing items and isolated preview refresh.")
}
