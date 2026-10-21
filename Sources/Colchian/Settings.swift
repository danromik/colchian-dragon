import Foundation

/// How Colchian decides whether lid-close sleep should be disabled.
enum Mode: String, CaseIterable {
    /// Normal macOS behavior: closing the lid sleeps the Mac.
    case normal
    /// Lid-close sleep is always disabled.
    case alwaysAwake
    /// Lid-close sleep is disabled only while a Claude Code turn is in progress.
    case claudeCode

    var title: String {
        switch self {
        case .normal: return "No override"
        case .alwaysAwake: return "Stay Awake (Always)"
        case .claudeCode: return "Stay Awake (Claude Code)"
        }
    }
}

/// Persistent user preferences, stored in UserDefaults (domain: the app's bundle identifier).
/// Any key can be overridden at launch with `--args -key value`, e.g. `-showDockIcon YES`.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let mode = "mode"
        static let thermalLimit = "thermalLimit"
        static let showDockIcon = "showDockIcon"
        static let staleTurnMinutes = "staleTurnMinutes"
        static let showThermalStatus = "showThermalStatus"
        static let showClaudeStatus = "showClaudeStatus"
    }

    private init() {
        defaults.register(defaults: [
            Key.mode: Mode.normal.rawValue,
            Key.thermalLimit: ProcessInfo.ThermalState.serious.rawValue,
            Key.showDockIcon: false,
            Key.staleTurnMinutes: 30,
            Key.showThermalStatus: true,
            Key.showClaudeStatus: true,
        ])
        // Earlier versions could save this from Settings; now only the launch argument sets it.
        defaults.removeObject(forKey: Key.showDockIcon)
    }

    var mode: Mode {
        get { Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    /// Thermal state at or above which Colchian stops keeping the Mac awake.
    var thermalLimit: ProcessInfo.ThermalState {
        get { ProcessInfo.ThermalState(rawValue: defaults.integer(forKey: Key.thermalLimit)) ?? .serious }
        set { defaults.set(newValue.rawValue, forKey: Key.thermalLimit) }
    }

    /// The app is a background utility without a Dock icon. For development, `make dev` shows one
    /// with the `-showDockIcon YES` launch argument.
    var showDockIcon: Bool { defaults.bool(forKey: Key.showDockIcon) }

    /// Which status boxes the menu's dashboard shows.
    var dashboardTiles: DashboardView.Tiles {
        get { DashboardView.Tiles(thermal: defaults.bool(forKey: Key.showThermalStatus),
                                  claude: defaults.bool(forKey: Key.showClaudeStatus)) }
        set {
            defaults.set(newValue.thermal, forKey: Key.showThermalStatus)
            defaults.set(newValue.claude, forKey: Key.showClaudeStatus)
        }
    }

    /// A turn with no hook activity for this long is assumed to have ended without a Stop hook
    /// (Claude Code does not run Stop hooks when the user interrupts a turn).
    var staleTurnInterval: TimeInterval {
        TimeInterval(max(1, defaults.integer(forKey: Key.staleTurnMinutes)) * 60)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
