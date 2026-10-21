import AppKit
import Combine
import SwiftUI

/// The state shown in the Settings window. The app delegate refreshes it after every change.
final class SettingsModel: ObservableObject {
    struct HookDirectory: Identifiable {
        let directory: ClaudeHookInstaller.ConfigDirectory
        let installed: Bool
        var id: String { directory.url.path }
    }

    @Published private(set) var hookDirectories: [HookDirectory] = []
    @Published private(set) var thermalLimit = ProcessInfo.ThermalState.serious
    @Published private(set) var thermalState = ProcessInfo.ThermalState.nominal
    @Published private(set) var passwordlessInstalled = false
    @Published private(set) var launchesAtLogin = false
    @Published private(set) var dashboardTiles = DashboardView.Tiles()
    @Published private(set) var dashboardStatus = DashboardView.Status()

    private weak var app: AppDelegate?

    init(app: AppDelegate?) {
        self.app = app
        refresh()
    }

    func refresh() {
        hookDirectories = ClaudeHookInstaller.configDirectories().map {
            HookDirectory(directory: $0, installed: ClaudeHookInstaller.isInstalled(in: $0))
        }
        thermalLimit = Settings.shared.thermalLimit
        thermalState = ProcessInfo.processInfo.thermalState
        passwordlessInstalled = PrivilegedSetup.isInstalled
        launchesAtLogin = app?.launchesAtLogin ?? false
        dashboardTiles = Settings.shared.dashboardTiles
        dashboardStatus = app?.dashboardStatus ?? DashboardView.Status()
    }

    // Actions run after the current event, so any alert they show isn't nested in SwiftUI's event handling.

    func toggleHooks(_ entry: HookDirectory) { later { $0.toggleHooks(in: entry.directory) } }
    func setThermalLimit(_ limit: ProcessInfo.ThermalState) { later { $0.setThermalLimit(limit) } }
    func toggleLaunchAtLogin() { later { $0.toggleLaunchAtLogin() } }

    func setDashboardTiles(_ tiles: DashboardView.Tiles) {
        dashboardTiles = tiles  // so the preview updates at once
        later { $0.setDashboardTiles(tiles) }
    }

    func togglePasswordlessControl() {
        let installed = passwordlessInstalled
        later { app in
            if installed { app.uninstallPrivilegedHelper() } else { app.installPrivilegedHelper(confirm: false) }
        }
    }

    private func later(_ action: @escaping (AppDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let app = self?.app else { return }
            action(app)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Two columns, so the window isn't tall and narrow: sleep control and auto-restart on
            // the left, Claude Code and the dashboard on the right.
            HStack(alignment: .top, spacing: 0) {
                column {
                    passwordlessSection
                    thermalSection
                    autoRestartSection
                }
                // Inset to span the sections rather than the whole window.
                Divider()
                    .padding(.vertical, 20)
                column {
                    hooksSection
                    dashboardSection
                }
            }

            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .toggleStyle(.switch)
        .frame(width: 820)
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity)
    }

    private var passwordlessSection: some View {
        Section {
            LabeledContent {
                Button {
                    model.togglePasswordlessControl()
                } label: {
                    // Both titles are laid out, so the button is the same width either way.
                    ZStack {
                        Text("Set Up…").hidden()
                        Text("Remove…").hidden()
                        Text(model.passwordlessInstalled ? "Remove…" : "Set Up…")
                    }
                }
            } label: {
                Label {
                    Text(model.passwordlessInstalled ? "Set up" : "Not set up")
                } icon: {
                    Image(systemName: model.passwordlessInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.passwordlessInstalled ? Color.green : Color.orange)
                }
            }
        } header: {
            Text("Passwordless Control")
        } footer: {
            footnote("Changing the Mac's lid-close sleep setting requires administrator rights. Colchian Dragon asks for your password once and adds a rule to /etc/sudoers.d/colchian that lets your account change the lid-close sleep setting without needing to enter the password again.")
        }
    }

    private var thermalSection: some View {
        Section {
            Picker("Stop disabling sleep at thermal level", selection: Binding(
                get: { model.thermalLimit },
                set: { model.setThermalLimit($0) }
            )) {
                Text("Fair (most cautious)").tag(ProcessInfo.ThermalState.fair)
                Text("Serious (recommended)").tag(ProcessInfo.ThermalState.serious)
                Text("Critical").tag(ProcessInfo.ThermalState.critical)
            }
            LabeledContent("Current thermal state", value: model.thermalState.label)
        } header: {
            Text("Thermal Safety Limit")
        } footer: {
            footnote("Disabling sleep with the lid closed creates a risk of your Mac overheating, especially if stored in a case or bag. When the Mac's thermal state reaches the safety limit you set, Colchian Dragon re-enables lid-close sleep and puts a closed laptop to sleep.")
        }
    }

    private var hooksSection: some View {
        Section {
            if model.hookDirectories.isEmpty {
                Text("No Claude Code configuration directory (~/.claude) found.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.hookDirectories) { entry in
                Toggle(entry.directory.displayName, isOn: Binding(
                    get: { entry.installed },
                    set: { _ in model.toggleHooks(entry) }
                ))
            }
        } header: {
            Text("Claude Code Hooks")
        } footer: {
            footnote("Hooks in each Claude Code directory's settings.json tell Colchian Dragon when a session becomes active and inactive. You can configure whether hooks are enabled for each Claude Code configuration.")
        }
    }

    private var dashboardSection: some View {
        Section {
            Toggle("Thermal status", isOn: tileBinding(\.thermal))
            Toggle("Claude Code status", isOn: tileBinding(\.claude))
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DashboardPreview(status: model.dashboardStatus, tiles: model.dashboardTiles)
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("Dashboard")
        } footer: {
            footnote("Control what status information is displayed in the app menu.")
        }
        .toggleStyle(.checkbox)
    }

    private func tileBinding(_ tile: WritableKeyPath<DashboardView.Tiles, Bool>) -> Binding<Bool> {
        Binding(get: { model.dashboardTiles[keyPath: tile] },
                set: { var tiles = model.dashboardTiles; tiles[keyPath: tile] = $0; model.setDashboardTiles(tiles) })
    }

    private var autoRestartSection: some View {
        Section("Auto-Restart") {
            Toggle("Launch Colchian Dragon at Login", isOn: Binding(
                get: { model.launchesAtLogin },
                set: { _ in model.toggleLaunchAtLogin() }
            ))
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The top of the menu as it will look, on the menu's own background.
private struct DashboardPreview: NSViewRepresentable {
    let status: DashboardView.Status
    let tiles: DashboardView.Tiles

    func makeNSView(context: Context) -> NSVisualEffectView {
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        let dashboard = DashboardView()
        dashboard.autoresizingMask = [.width, .height]
        background.addSubview(dashboard)
        return background
    }

    func updateNSView(_ background: NSVisualEffectView, context: Context) {
        guard let dashboard = background.subviews.first as? DashboardView else { return }
        dashboard.status = status
        dashboard.tiles = tiles
        dashboard.frame = background.bounds
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        CGSize(width: StatusMenu.width, height: DashboardView.height(for: tiles))
    }
}

/// The Settings window is a non-activating panel: it takes keyboard focus without making Colchian
/// the active app, so the menu bar keeps showing the app you were using.
private final class SettingsPanel: NSPanel {
    /// Escape closes the window.
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    /// ⌘W closes the window. (The main menu's Close only works while Colchian is the active app.)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController {
    let model: SettingsModel
    private var tilesObserver: AnyCancellable?

    init(app: AppDelegate) {
        model = SettingsModel(app: app)
        // The non-activating style only takes effect when set at creation.
        let panel = SettingsPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.title = "Colchian Dragon Settings"
        panel.contentViewController = NSHostingController(rootView: SettingsView(model: model) { [weak panel] in panel?.close() })
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        fitToContent()
        panel.center()
        // The dashboard preview's height depends on the tiles shown.
        tilesObserver = model.$dashboardTiles.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        model.refresh()
        fitToContent()
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    /// Sizes the window to fit the form, keeping its top edge in place. A grouped Form scrolls,
    /// so it doesn't give the window a height of its own.
    private func fitToContent() {
        guard let window, let content = window.contentView else { return }
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize)).size
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height),
                        display: true)
    }
}
