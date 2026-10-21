import Foundation
import IOKit

/// Reads and changes the system-wide "SleepDisabled" power setting via `pmset`.
///
/// `pmset -a disablesleep 1` is the only reliable way to keep a Mac laptop awake with the lid
/// closed and no external display: IOPMAssertions (as used by `caffeinate`) do not prevent
/// clamshell sleep. Changing it requires root, which `PrivilegedSetup` grants passwordlessly
/// for exactly these commands via a sudoers rule.
enum PowerManager {
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"

    /// The exact commands allowed by the sudoers rule. Keep in sync with `PrivilegedSetup`.
    static let enableCommand = [pmset, "-a", "disablesleep", "0"]
    static let disableCommand = [pmset, "-a", "disablesleep", "1"]
    static let sleepNowCommand = [pmset, "sleepnow"]

    /// Whether system sleep is currently disabled. `pmset -g` lists `SleepDisabled 1` only when set.
    static func isSleepDisabled() -> Bool {
        for line in Shell.run(pmset, ["-g"]).output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "SleepDisabled" {
                return fields.dropFirst().first == "1"
            }
        }
        return false
    }

    /// Sets SleepDisabled without prompting. Returns nil on success or an error message.
    static func setSleepDisabled(_ disabled: Bool) -> String? {
        let result = Shell.run(sudo, ["-n"] + (disabled ? disableCommand : enableCommand))
        if result.succeeded { return nil }
        return result.output.isEmpty ? "pmset failed (status \(result.status))" : result.output
    }

    /// Puts the Mac to sleep immediately.
    static func sleepNow() {
        Shell.run(sudo, ["-n"] + sleepNowCommand)
    }

    /// Whether the laptop lid is closed (false on desktops or if unknown).
    static func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }
}
