import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The project's home page, linked from the menu.
    static let website = URL(string: "https://github.com/danromik/colchian-dragon")!

    let settings = Settings.shared
    let turns = ClaudeTurnMonitor()
    let thermal = ThermalMonitor()
    private var menu: StatusMenu!
    private var settingsWindow: SettingsWindowController?

    /// Whether Colchian has currently set SleepDisabled.
    private(set) var sleepDisabled = false
    /// Latched when the thermal limit is reached; cleared once the Mac has cooled down.
    private(set) var overheated = false
    private(set) var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconSetting()
        NSApp.mainMenu = makeMainMenu()

        menu = StatusMenu(app: self)
        turns.onChange = { [weak self] in self?.reconcile() }
        thermal.onChange = { [weak self] _ in self?.thermalStateChanged() }
        thermal.start()
        turns.start()

        // Refresh the hook script in case a newer app version changed it.
        if hooksInstalled { try? ClaudeHookInstaller.installScript() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.turns.refresh() }

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // Adopt whatever state a previous run (or a crash) left behind; thermalStateChanged() reconciles it.
        sleepDisabled = PowerManager.isSleepDisabled()
        thermalStateChanged()
    }

    /// Opening the app again (from Finder, or its Dock icon) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        turns.stop()
        if sleepDisabled || PowerManager.isSleepDisabled() {
            _ = PowerManager.setSleepDisabled(false)
        }
    }

    // MARK: - State

    var desiredSleepDisabled: Bool {
        if overheated { return false }
        switch settings.mode {
        case .normal: return false
        case .alwaysAwake: return true
        case .claudeCode: return !turns.activeSessions.isEmpty
        }
    }

    /// Applies the desired SleepDisabled state if it differs from the current one.
    func reconcile() {
        let want = desiredSleepDisabled
        if want != sleepDisabled {
            if let error = PowerManager.setSleepDisabled(want) {
                lastError = PrivilegedSetup.isInstalled ? error : "Passwordless control is not set up"
            } else {
                lastError = nil
                let wasDisabled = sleepDisabled
                sleepDisabled = want
                // Releasing while the lid is already closed: go to sleep as the user expects.
                if wasDisabled && !want && PowerManager.isLidClosed() {
                    PowerManager.sleepNow()
                }
            }
        } else {
            lastError = nil
        }
        stateDidChange()
    }

    private func thermalStateChanged() {
        let state = thermal.state
        let limit = settings.thermalLimit
        if state.rawValue >= limit.rawValue {
            if !overheated {
                overheated = true
                if sleepDisabled {
                    notify(title: "Colchian Dragon: Mac is running hot",
                           body: "Thermal state is \(state.label). Lid-close sleep has been re-enabled.")
                }
            }
        } else if overheated && state.rawValue <= max(0, limit.rawValue - 2) {
            // Hysteresis: resume only once well below the limit (nominal for the default limit).
            overheated = false
        }
        reconcile()
    }

    /// Updates the menu and the Settings window after any state change.
    func stateDidChange() {
        menu.update()
        if settingsWindow?.window?.isVisible == true { settingsWindow?.model.refresh() }
    }

    // MARK: - Actions (called from the menu and Settings)

    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }

    var hooksInstalled: Bool {
        ClaudeHookInstaller.configDirectories().contains(where: ClaudeHookInstaller.isInstalled)
    }

    /// Whether choosing `mode` first asks the user to set something up.
    func needsSetup(for mode: Mode) -> Bool {
        (mode != .normal && !PrivilegedSetup.isInstalled) || (mode == .claudeCode && !hooksInstalled)
    }

    func setMode(_ mode: Mode) {
        if mode != .normal, !PrivilegedSetup.isInstalled, !installPrivilegedHelper() { return }
        if mode == .claudeCode, !hooksInstalled { offerHookInstall() }
        settings.mode = mode
        reconcile()
    }

    func setThermalLimit(_ limit: ProcessInfo.ThermalState) {
        settings.thermalLimit = limit
        overheated = false
        thermalStateChanged()
    }

    /// Returns true if passwordless control is (now) available.
    @discardableResult
    func installPrivilegedHelper(confirm: Bool = true) -> Bool {
        if confirm, !confirmPrivilegedHelper() { return false }
        if let error = PrivilegedSetup.install() {
            showError("Could not set up passwordless control", error)
            return false
        }
        reconcile()
        return true
    }

    private func confirmPrivilegedHelper() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow Colchian Dragon to control lid-close sleep?"
        alert.informativeText = """
        Disabling sleep requires administrator rights. Colchian Dragon will ask for your password once and install a \
        rule in \(PrivilegedSetup.sudoersPath) that lets your account run only these commands without a password:

        pmset -a disablesleep 0
        pmset -a disablesleep 1
        pmset sleepnow
        """
        alert.addButton(withTitle: "Continue…")
        alert.addButton(withTitle: "Cancel")
        return runModal(alert) == .alertFirstButtonReturn
    }

    func uninstallPrivilegedHelper() {
        settings.mode = .normal
        if let error = PrivilegedSetup.uninstall() {
            showError("Could not remove passwordless control", error)
        } else {
            sleepDisabled = false
        }
        reconcile()
    }

    func toggleHooks(in dir: ClaudeHookInstaller.ConfigDirectory) {
        do {
            if ClaudeHookInstaller.isInstalled(in: dir) {
                try ClaudeHookInstaller.uninstall(from: dir)
            } else {
                try ClaudeHookInstaller.install(in: dir)
            }
        } catch {
            showError("Could not update \(dir.settingsURL.path)", error.localizedDescription)
        }
        stateDidChange()
    }

    private func offerHookInstall() {
        let dirs = ClaudeHookInstaller.configDirectories()
        let alert = NSAlert()
        alert.messageText = "Install Claude Code hooks?"
        alert.informativeText = dirs.isEmpty
            ? "No Claude Code configuration directory (~/.claude) was found. Run Claude Code once, then install hooks in Colchian Dragon Settings."
            : """
            Colchian Dragon adds hooks to settings.json in: \(dirs.map(\.displayName).joined(separator: ", ")). \
            They mark when a Claude Code session becomes active and inactive, and sessions that are already running pick \
            them up automatically. You can choose individual directories later in Colchian Dragon Settings.
            """
        if !dirs.isEmpty {
            alert.addButton(withTitle: "Install Hooks")
            alert.addButton(withTitle: "Not Now")
        }
        guard !dirs.isEmpty, runModal(alert) == .alertFirstButtonReturn else { return }
        for dir in dirs where !ClaudeHookInstaller.isInstalled(in: dir) {
            do { try ClaudeHookInstaller.install(in: dir) } catch {
                showError("Could not update \(dir.settingsURL.path)", error.localizedDescription)
            }
        }
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLaunchAtLogin() {
        do {
            if launchesAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            showError("Could not change Launch at Login", error.localizedDescription)
        }
        stateDidChange()
    }

    func setDashboardTiles(_ tiles: DashboardView.Tiles) {
        settings.dashboardTiles = tiles
        stateDidChange()
    }

    /// What the menu's dashboard shows now, for the preview in Settings.
    var dashboardStatus: DashboardView.Status { menu.dashboardStatus }

    private func applyDockIconSetting() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    // MARK: - UI helpers

    /// A minimal main menu. It is only visible while the Dock icon is shown, but always
    /// provides ⌘, ⌘W and ⌘Q while the Settings window is active.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Colchian Dragon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    @objc private func openSettings() {
        showSettings()
    }

    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        present(alert)
    }

    /// Shows an alert as a sheet on the Settings window when that's open, which keeps Colchian
    /// from becoming the active app, or as a standalone dialog otherwise.
    private func present(_ alert: NSAlert) {
        if let window = settingsWindow?.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            _ = runModal(alert)
        }
    }

    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
