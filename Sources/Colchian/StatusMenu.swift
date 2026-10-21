import AppKit

/// The menu bar item: the selected mode's icon, and a menu with a status dashboard,
/// the three modes, and Quit/Settings.
final class StatusMenu: NSObject, NSMenuDelegate {
    static let width: CGFloat = 330

    private unowned let app: AppDelegate
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let dashboard = DashboardView()
    private let notice = NoticeRowView()
    private let noticeItem = NSMenuItem()
    private let modeHeader = SectionHeaderView(title: "Sleep Override Mode", hasHelp: true)
    private let modeGuide = ModeGuide()
    private let modeRows = Mode.allCases.map(ModeRowView.init)
    private let footer = FooterRowView()
    private let about = AboutView()
    private let aboutItem = NSMenuItem()
    private let animator = MenuAnimator()
    private let tooltips = TooltipController()
    private let sensors = TemperatureSensors()
    /// Readings for the dashboard, taken while the menu is open.
    private var openSessions = 0
    private var temperatures = Temperatures()
    private var lastReading: CFTimeInterval = 0

    init(app: AppDelegate) {
        self.app = app
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false

        menu.addItem(viewItem(dashboard, title: "Colchian Dragon", enabled: false))
        notice.onClick = { [unowned app] in app.showSettings() }
        noticeItem.view = notice
        menu.addItem(noticeItem)
        menu.addItem(.separator())

        menu.addItem(viewItem(modeHeader, title: "Sleep Override Mode", enabled: false))
        for row in modeRows {
            let mode = row.mode
            row.onSelect = { [unowned self] in self.select(mode) }
            // The action runs when the item is chosen with the keyboard; clicks are handled by the view.
            menu.addItem(viewItem(row, title: mode.title, action: row.onSelect))
        }
        menu.addItem(.separator())

        footer.onQuit = { NSApp.terminate(nil) }
        footer.onSettings = { [unowned app] in app.showSettings() }
        footer.onAbout = { [unowned self] in self.toggleAbout() }
        footer.onWebsite = { NSWorkspace.shared.open(AppDelegate.website) }
        let footerItem = viewItem(footer, title: "Quit Colchian Dragon", action: footer.onQuit)
        footerItem.keyEquivalent = "q"
        menu.addItem(footerItem)
        // The About panel opens below the footer, so the buttons stay put as the menu grows.
        aboutItem.view = about
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)
        let settingsItem = ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [unowned app] in app.showSettings() }
        settingsItem.isHidden = true
        settingsItem.allowsKeyEquivalentWhenHidden = true
        menu.addItem(settingsItem)

        animator.views = [dashboard, notice, modeHeader] + modeRows + [footer, about]
        animator.onFrame = { [unowned self] now in
            if now - lastReading >= 2 { takeReadings(now: now) }
            modeGuide.update(button: modeHeader.helpHovered ? modeHeader.helpScreenRect : nil, now: now)
            modeHeader.helpShown = modeGuide.isShown
            let tooltip = animator.views.lazy.compactMap { view in view.mouseLocation.flatMap(view.tooltip(at:)) }.first
            tooltips.update(tooltip, now: now)
        }
        item.menu = menu
        update()
    }

    /// What the dashboard shows, with fresh readings.
    var dashboardStatus: DashboardView.Status {
        takeReadings(now: CACurrentMediaTime())
        return dashboard.status
    }

    func update() {
        let mode = app.settings.mode
        dashboard.tiles = app.settings.dashboardTiles
        dashboard.status = DashboardView.Status(mode: mode, overheated: app.overheated, hooksInstalled: app.hooksInstalled,
                                                activeTurns: app.turns.activeSessions.count, openSessions: openSessions,
                                                thermalState: app.thermal.state, thermalLimit: app.settings.thermalLimit,
                                                temperatures: temperatures)
        modeRows.forEach { $0.isSelected = $0.mode == mode }
        let message = noticeMessage()
        notice.message = message ?? ""
        noticeItem.isHidden = message == nil

        let summary = statusSummary()
        item.button?.image = MenuBarIcon.image(for: mode, description: summary)
        item.button?.toolTip = "Colchian Dragon — \(summary)"
    }

    /// Counts the open Claude Code sessions and reads the temperatures, every 2 s while the menu is open.
    private func takeReadings(now: CFTimeInterval) {
        lastReading = now
        openSessions = ClaudeTurnMonitor.openSessionCount()
        temperatures = sensors.read()
        update()
    }

    /// Selects a mode while keeping the menu open, so the change can be seen. If the mode first
    /// needs setting up, which shows dialogs, the menu closes instead.
    private func select(_ mode: Mode) {
        tooltips.dismiss()
        if app.needsSetup(for: mode) {
            menu.cancelTracking()
            DispatchQueue.main.async { [unowned app] in app.setMode(mode) }
        } else {
            app.setMode(mode)
        }
    }

    private func toggleAbout() {
        tooltips.dismiss()
        about.setOpen(!about.isOpen)
        footer.aboutOpen = about.isOpen
    }

    private func noticeMessage() -> String? {
        if let error = app.lastError { return error }
        if app.settings.mode == .claudeCode, !app.hooksInstalled {
            return "Claude Code hooks are not installed"
        }
        return nil
    }

    /// What happens when the lid closes, for the menu bar icon's tooltip.
    private func statusSummary() -> String {
        if app.overheated && app.settings.mode != .normal { return "Too hot: lid-close sleep re-enabled" }
        if app.sleepDisabled {
            return app.settings.mode == .claudeCode ? "Claude Code session active: staying awake" : "Staying awake with lid closed"
        }
        if app.settings.mode == .claudeCode { return "Waiting for an active Claude Code session" }
        return "No override: sleeps on lid close"
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        takeReadings(now: CACurrentMediaTime())
        animator.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        animator.stop()
        modeGuide.hide()
        footer.aboutOpen = false
        tooltips.hide()
    }

    private func viewItem(_ view: NSView, title: String, enabled: Bool = true, action: (() -> Void)? = nil) -> NSMenuItem {
        let item = action.map { ClosureMenuItem(title: title, keyEquivalent: "", handler: $0) } ?? NSMenuItem()
        item.title = title
        item.view = view
        item.isEnabled = enabled
        return item
    }
}

/// An NSMenuItem that runs a closure when chosen.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        // Defer until the menu has closed so modal alerts don't appear inside menu tracking.
        DispatchQueue.main.async(execute: handler)
    }
}
