import Foundation
import notify

/// Tracks Claude Code turns in progress.
///
/// The `colchian-hook` script (installed by `ClaudeHookInstaller`) keeps one marker file per
/// session in `turnsDirectory`: created when a turn starts, touched on tool activity, removed
/// when the turn ends with no background tasks left running. After each change it posts a Darwin
/// notification so the app updates immediately; a periodic rescan also expires turns that ended
/// without a Stop hook (Claude Code does not run Stop hooks when the user interrupts a turn) and
/// turns whose claude process has exited.
final class ClaudeTurnMonitor {
    static let notificationName = "com.danromik.colchian-dragon.turns"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Colchian", isDirectory: true)
    }
    static var turnsDirectory: URL { supportDirectory.appendingPathComponent("turns", isDirectory: true) }

    /// Session IDs with a turn in progress.
    private(set) var activeSessions: [String] = []
    var onChange: (() -> Void)?

    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var timer: Timer?

    func start() {
        try? FileManager.default.createDirectory(at: Self.turnsDirectory, withIntermediateDirectories: true)
        notify_register_dispatch(Self.notificationName, &notifyToken, .main) { [weak self] _ in
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        if notifyToken != NOTIFY_TOKEN_INVALID { notify_cancel(notifyToken) }
    }

    func refresh() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.turnsDirectory,
                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: .skipsHiddenFiles)) ?? []
        let staleBefore = Date().addingTimeInterval(-Settings.shared.staleTurnInterval)
        var sessions: [String] = []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < staleBefore || !isRunning(sessionMarker: file) {
                try? fm.removeItem(at: file)
            } else {
                sessions.append(file.lastPathComponent)
            }
        }
        sessions.sort()
        if sessions != activeSessions {
            activeSessions = sessions
            onChange?()
        }
    }

    /// Whether the claude process that wrote a marker is still running. Claude Code doesn't always run
    /// SessionEnd hooks (for example when its terminal is closed), so this catches sessions that are gone.
    /// Markers without a PID (from older hook scripts) count as running.
    private func isRunning(sessionMarker file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
        return Self.isClaude(Self.arguments(of: pid))
    }

    /// The number of Claude Code sessions open:`claude` processes running in a terminal.
    static func openSessionCount() -> Int {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return 0 }
        // Room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return 0 }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).filter { process in
            // The process's own name is the installed version (e.g. "2.1.302"), so look at how it was started.
            process.kp_eproc.e_tdev != -1 && isClaude(arguments(of: process.kp_proc.p_pid))
        }.count
    }

    /// Whether a command line runs Claude Code: `claude …`, or `node …/claude …` for an npm install.
    private static func isClaude(_ arguments: [String]) -> Bool {
        arguments.prefix(2).contains { ($0 as NSString).lastPathComponent == "claude" }
    }

    /// The first two arguments `pid` was started with, or none if they can't be read.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // An argument count, the executable's path, padding, then the arguments, each ending in a NUL.
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        return strings.dropFirst().prefix(min(Int(count), 2)).map { String(decoding: $0, as: UTF8.self) }
    }
}
