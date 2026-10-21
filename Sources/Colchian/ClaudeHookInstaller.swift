import Foundation

/// Adds and removes Colchian's hooks in Claude Code `settings.json` files.
///
/// Claude Code reads user settings from `~/.claude/settings.json`, or from
/// `$CLAUDE_CONFIG_DIR/settings.json` when that variable is set. Since a GUI app cannot see the
/// shell's environment, Colchian offers every `~/.claude` and `~/.claude-*` directory it finds.
enum ClaudeHookInstaller {
    static var scriptURL: URL { ClaudeTurnMonitor.supportDirectory.appendingPathComponent("colchian-hook") }

    /// Identifies Colchian's hook entries; anything whose command contains this is ours.
    private static let marker = "Colchian/colchian-hook"

    /// Hook event → argument passed to the hook script.
    private static let events: [(event: String, action: String)] = [
        ("UserPromptSubmit", "start"),
        ("PreToolUse", "heartbeat"),
        ("PostToolUse", "heartbeat"),
        ("SubagentStop", "heartbeat"),
        ("Stop", "stop"),
        ("StopFailure", "stop"),
        ("SessionEnd", "stop"),
    ]

    static let script = """
    #!/bin/sh
    # Claude Code hook installed by Colchian Dragon.app. Rewritten whenever the hooks are installed.
    # Usage: colchian-hook start|heartbeat|stop   (hook JSON arrives on stdin)
    # Must print nothing: UserPromptSubmit hook output is added to Claude's context.
    # Each marker holds the PID of the claude process that runs the hooks, so the app can tell
    # when the session has exited.
    dir="$HOME/Library/Application Support/Colchian/turns"
    input=$(/bin/cat)
    sid=$(printf '%s' "$input" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null | /usr/bin/tr -cd 'A-Za-z0-9._-')
    [ -n "$sid" ] || sid=unknown
    /bin/mkdir -p "$dir" 2>/dev/null
    case "$1" in
      start) echo "$PPID" > "$dir/$sid" ;;
      heartbeat)
        # A tool call means the session is working, even if its marker is gone (it started before
        # the hooks were turned on, or timed out while waiting for a permission prompt). Other
        # events can come from Claude Code's own helpers after a turn ends, so they only refresh.
        event=$(printf '%s' "$input" | /usr/bin/plutil -extract hook_event_name raw -o - - 2>/dev/null)
        case "$event" in
          PreToolUse|PostToolUse) echo "$PPID" > "$dir/$sid" ;;
          *) [ -e "$dir/$sid" ] && /usr/bin/touch "$dir/$sid" ;;
        esac ;;
      stop)
        # Background agents, workflows and shell commands keep running after the turn ends, and
        # report back by starting a new turn. Stop lists them; the session is done when none are left.
        tasks=$(printf '%s' "$input" | /usr/bin/plutil -extract background_tasks raw -o - - 2>/dev/null)
        if [ "${tasks:-0}" -gt 0 ] 2>/dev/null; then
          echo "$PPID" > "$dir/$sid"
        else
          /bin/rm -f "$dir/$sid"
        fi ;;
    esac
    /usr/bin/notifyutil -p \(ClaudeTurnMonitor.notificationName) >/dev/null 2>&1
    exit 0

    """

    struct ConfigDirectory {
        let url: URL
        var displayName: String { "~/" + url.lastPathComponent }
        // Resolved so a symlinked settings.json (e.g. from a dotfiles repo) is edited in place.
        var settingsURL: URL { url.appendingPathComponent("settings.json").resolvingSymlinksInPath() }
    }

    enum InstallError: LocalizedError {
        case unreadableSettings(String)
        var errorDescription: String? {
            switch self {
            case .unreadableSettings(let path): return "\(path) is not a JSON object; leaving it untouched."
            }
        }
    }

    /// `~/.claude` plus any `~/.claude-*` directories (used with CLAUDE_CONFIG_DIR).
    static func configDirectories() -> [ConfigDirectory] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .sorted()
            .map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(ConfigDirectory.init)
    }

    static func isInstalled(in dir: ConfigDirectory) -> Bool {
        guard let hooks = (try? readSettings(dir))?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isOurs)
            }
        }
    }

    static func install(in dir: ConfigDirectory) throws {
        try installScript()
        var settings = try readSettings(dir)
        var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        let command = "\"$HOME/Library/Application Support/\(marker)\""
        for (event, action) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": "\(command) \(action)", "timeout": 10]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings, to: dir)
    }

    static func uninstall(from dir: ConfigDirectory) throws {
        var settings = try readSettings(dir)
        let hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(settings, to: dir)
    }

    static func installScript() throws {
        try FileManager.default.createDirectory(at: ClaudeTurnMonitor.supportDirectory, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - settings.json

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(marker) == true
    }

    private static func removingOurs(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.isEmpty { return nil }
                var group = group
                group["hooks"] = remaining
                return group
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func readSettings(_ dir: ConfigDirectory) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.settingsURL), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadableSettings(dir.settingsURL.path)
        }
        return object
    }

    private static func writeSettings(_ settings: [String: Any], to dir: ConfigDirectory) throws {
        let fm = FileManager.default
        // Keep a one-time backup of the user's original settings.
        let backup = dir.settingsURL.appendingPathExtension("colchian-backup")
        if fm.fileExists(atPath: dir.settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: dir.settingsURL, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: dir.settingsURL, options: .atomic)
    }
}
